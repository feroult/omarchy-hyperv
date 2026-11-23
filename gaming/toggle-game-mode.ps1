#Requires -Version 5.1
<#
.SYNOPSIS
    Alterna rapidamente entre Modo IA (VM Hyprland + Moonlight) e Modo Jogo / Battlefield 6.
.DESCRIPTION
    Modo BF6 (`-Mode Game`):
      1. Envia comando via SSH para a VM (192.168.50.2) descarregar 100% dos modelos ativos
         da VRAM (`ollama stop` em todos os modelos listados em `ollama ps`, além de suporte
         opcional para reiniciar serviços de inferência como vLLM/Ollama).
      2. Fecha (ou minimiza com `-MinimizeOnly`) o `Moonlight.exe` no Windows para colocar
         o Sunshine em repouso imediato e zerar o uso de CPU/GPU na VM.
      3. Opcionalmente suspende a VM via `Save-VM` (`-SuspendVM`) ou desliga graciosamente
         via `Stop-VM` (`-StopVM`) caso queira liberar 100% da RAM e VRAM.

    Modo IA (`-Mode AI`):
      1. Garante que a VM esteja em execução (retomando se salva/desligada) e aguarda SSH/Sunshine.
      2. Reabre o `Moonlight.exe` no Windows (conectando direto ao Hyprland se `MOONLIGHT_AUTO_STREAM=true`).

    Sem especificar `-Mode`, o script usa `Toggle` (se Moonlight estiver aberto ou VM rodando sem
    marcador de modo jogo, entra em Modo BF6; caso contrário, retorna ao Modo IA).

.EXAMPLE
    .\gaming\toggle-game-mode.ps1
.EXAMPLE
    .\gaming\toggle-game-mode.ps1 -Mode Game
.EXAMPLE
    .\gaming\toggle-game-mode.ps1 -Mode Game -SuspendVM
.EXAMPLE
    .\gaming\toggle-game-mode.ps1 -Mode Game -MinimizeOnly
.EXAMPLE
    .\gaming\toggle-game-mode.ps1 -Mode AI
#>

[CmdletBinding()]
param(
    [ValidateSet('Toggle', 'Game', 'AI')]
    [string]$Mode = 'Toggle',

    [string]$EnvFile,
    [string]$VMName,
    [string]$VMIP,
    [string]$VMUser,
    [int]$SSHPort,
    [string]$SSHKeyPath,

    [switch]$MinimizeOnly,
    [switch]$ForceRestartServices,
    [switch]$SuspendVM,
    [switch]$StopVM
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ==============================================================================
# Helpers & Configuração Centralizada
# ==============================================================================
$commonScript = Join-Path (Join-Path $PSScriptRoot '..\windows') 'common.ps1'
if (-not (Test-Path -LiteralPath $commonScript)) {
    throw "Arquivo auxiliar não encontrado: $commonScript"
}
. $commonScript

$cfg = Import-WinixEnv -EnvPath $EnvFile

$VMName              = if ($VMName)        { $VMName }        else { Get-ConfigValue $cfg 'VM_NAME' 'Linux-Hyprland-IA' }
$VMIP                = if ($VMIP)          { $VMIP }          else { Get-ConfigValue $cfg 'VM_IP' '192.168.50.2' }
$VMUser              = if ($VMUser)        { $VMUser }        else { Get-ConfigValue $cfg 'VM_USER' 'linuxia' }
$SSHPort             = if ($SSHPort -gt 0) { $SSHPort }       else { [int](Get-ConfigValue $cfg 'SSH_PORT' 22) }
$SSHKeyPath          = Resolve-SshKeyPath $(if ($SSHKeyPath) { $SSHKeyPath } else { Get-ConfigValue $cfg 'SSH_KEY_PATH_WIN' '' })
$MoonlightPath       = Get-ConfigValue $cfg 'MOONLIGHT_EXE_PATH' 'C:\Program Files\Moonlight Game Streaming\Moonlight.exe'
$SunshinePort        = [int](Get-ConfigValue $cfg 'SUNSHINE_PORT' 47990)
$SunshineAppName     = Get-ConfigValue $cfg 'SUNSHINE_APP_NAME' 'Omarchy Hyprland'
$MoonlightAutoStream = (Get-ConfigValue $cfg 'MOONLIGHT_AUTO_STREAM' 'false').ToLowerInvariant() -eq 'true'
$AiServicesRaw       = Get-ConfigValue $cfg 'AI_SYSTEMD_SERVICES' 'ollama'
$ForceRestartCfg     = (Get-ConfigValue $cfg 'AI_FORCE_RESTART_SERVICES' 'false').ToLowerInvariant() -eq 'true'
$ShouldForceRestart  = $ForceRestartServices.IsPresent -or $ForceRestartCfg

$StateFile = Join-Path $env:TEMP "winix-game-mode-${VMName}.state"
$sshArgs   = Get-SshBaseArgs -KeyPath $SSHKeyPath -Port $SSHPort -ConnectTimeout 5
$remote    = "${VMUser}@${VMIP}"

# Win32 helper para minimizar janela do Moonlight quando -MinimizeOnly é usado
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class WinixWindowHelper {
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
}
"@ -ErrorAction SilentlyContinue

function Invoke-UnloadVmVram {
    param(
        [string]$ServicesCsv,
        [bool]$ForceRestart
    )

    if (-not (Get-Command 'ssh' -ErrorAction SilentlyContinue)) {
        Write-Log 'Cliente SSH não encontrado no PATH; pulando descarga remota de VRAM.' 'WARN'
        return
    }

    Write-Log "Conectando via SSH em $remote para descarregar modelos da VRAM..." 'STEP'

    $servicesArg = ($ServicesCsv -replace '[^a-zA-Z0-9,._@-]', '')
    $forceFlag   = if ($ForceRestart) { '1' } else { '0' }

    $remoteScript = @"
set -e
export PATH="/usr/lib/wsl/lib:/usr/local/bin:/usr/bin:/bin:\$PATH"
export LD_LIBRARY_PATH="/usr/lib/wsl/lib\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"

# 1. Descarrega todos os modelos ativos no Ollama
if command -v ollama >/dev/null 2>&1; then
    MODELS=\$(ollama ps 2>/dev/null | awk 'NR>1 && NF>0 {print \$1}')
    if [ -n "\$MODELS" ]; then
        for m in \$MODELS; do
            echo "[VM] Descarregando modelo Ollama: \$m"
            ollama stop "\$m" || true
        done
    else
        echo "[VM] Nenhum modelo Ollama carregado na VRAM."
    fi
fi

# 2. Para processos vLLM / llama-server avulsos ou reinicia serviços systemd configurados
SERVICES="${servicesArg}"
FORCE_RESTART="${forceFlag}"

if [ "\$FORCE_RESTART" = "1" ] && [ -n "\$SERVICES" ]; then
    IFS=',' read -ra SVC_LIST <<< "\$SERVICES"
    for svc in "\${SVC_LIST[@]}"; do
        [ -z "\$svc" ] && continue
        if systemctl is-active --quiet "\$svc" 2>/dev/null; then
            echo "[VM] Reiniciando serviço '\$svc' para zerar alocação CUDA..."
            sudo -n systemctl restart "\$svc" 2>/dev/null || echo "[VM] Aviso: sem permissão sudo sem senha para reiniciar '\$svc'."
        fi
    done
fi

# 3. Relatório rápido de VRAM após limpeza
if [ -x /usr/lib/wsl/lib/nvidia-smi ]; then
    echo "[VM] Estado atual da VRAM:"
    /usr/lib/wsl/lib/nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader || true
fi
"@

    $remoteScriptUnix = ($remoteScript -replace "`r`n", "`n") + "`n"
    $remoteScriptB64  = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($remoteScriptUnix))
    try {
        $res = Invoke-NativeCapture -FilePath 'ssh' -Arguments ($sshArgs + @($remote, "printf '%s' '$remoteScriptB64' | base64 -d | bash"))
        if ($res.ExitCode -eq 0) {
            foreach ($line in $res.Output) {
                if ($line) { Write-Log "  $line" 'INFO' }
            }
            Write-Log 'VRAM na VM descarregada com sucesso.' 'OK'
        }
        else {
            Write-Log "VM inacessível via SSH (pode já estar desligada/suspensa): $($res.Output -join ' ')" 'WARN'
        }
    }
    catch {
        Write-Log "Aviso ao contatar VM via SSH: $($_.Exception.Message)" 'WARN'
    }
}

function Stop-OrMinimizeMoonlight {
    param([bool]$Minimize)

    $procs = @(Get-Process -Name 'Moonlight' -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) {
        Write-Log 'Moonlight.exe não está em execução.' 'INFO'
        return
    }

    if ($Minimize) {
        Write-Log 'Minimizando Moonlight.exe...' 'STEP'
        foreach ($p in $procs) {
            if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
                [WinixWindowHelper]::ShowWindowAsync($p.MainWindowHandle, 6) | Out-Null # SW_MINIMIZE = 6
            }
        }
        Write-Log 'Moonlight minimizado. (Dica: fechar o cliente garante que o Sunshine zere totalmente o encode.)' 'OK'
    }
    else {
        Write-Log 'Encerrando Moonlight.exe para colocar o Sunshine em repouso...' 'STEP'
        foreach ($p in $procs) {
            $null = $p.CloseMainWindow()
        }
        Start-Sleep -Seconds 2
        $remaining = @(Get-Process -Name 'Moonlight' -ErrorAction SilentlyContinue)
        if ($remaining.Count -gt 0) {
            $remaining | Stop-Process -Force
        }
        Write-Log 'Moonlight.exe encerrado. Sunshine em repouso na VM.' 'OK'
    }
}

function Invoke-HyperVPowerAction {
    param(
        [ValidateSet('Save', 'Stop', 'Start')]
        [string]$Action
    )

    if (-not (Test-IsAdministrator)) {
        Write-Log "Ação Hyper-V '$Action' requer PowerShell como Administrador. Execute novamente elevado." 'WARN'
        return
    }

    Import-Module Hyper-V -ErrorAction Stop
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Log "VM '$VMName' não encontrada no Hyper-V." 'WARN'
        return
    }

    switch ($Action) {
        'Save' {
            if ($vm.State -eq 'Running') {
                Write-Log "Executando Save-VM em '$VMName' para liberar 100% da RAM/VRAM..." 'STEP'
                try {
                    Save-VM -Name $VMName -ErrorAction Stop
                    Write-Log "VM '$VMName' salva com sucesso (RAM/VRAM liberadas)." 'OK'
                }
                catch {
                    Write-Log "Hyper-V não permitiu Save-VM (limitação conhecida de estado salvo com GPU-P): $($_.Exception.Message)" 'WARN'
                    Write-Log "Dica: use '-StopVM' para desligar graciosamente a VM quando precisar liberar 100% da RAM." 'WARN'
                }
            }
            else {
                Write-Log "VM '$VMName' já está no estado '$($vm.State)'." 'INFO'
            }
        }
        'Stop' {
            if ($vm.State -eq 'Running') {
                Write-Log "Desligando graciosamente VM '$VMName' (Stop-VM)..." 'STEP'
                Stop-VM -Name $VMName -ErrorAction Stop
                Write-Log "VM '$VMName' desligada." 'OK'
            }
            else {
                Write-Log "VM '$VMName' já está no estado '$($vm.State)'." 'INFO'
            }
        }
        'Start' {
            if ($vm.State -ne 'Running') {
                Write-Log "Iniciando/retomando VM '$VMName' (estado atual: $($vm.State))..." 'STEP'
                Start-VM -Name $VMName -ErrorAction Stop
                Write-Log "VM '$VMName' iniciada. Aguardando Sunshine/SSH em ${VMIP}..." 'INFO'

                $deadline = (Get-Date).AddSeconds(45)
                $ready = $false
                while ((Get-Date) -lt $deadline) {
                    try {
                        $tcp = New-Object System.Net.Sockets.TcpClient
                        $async = $tcp.BeginConnect($VMIP, $SunshinePort, $null, $null)
                        if ($async.AsyncWaitHandle.WaitOne(1000, $false) -and $tcp.Connected) {
                            $tcp.Close()
                            $ready = $true
                            break
                        }
                        $tcp.Close()
                    }
                    catch { }
                    Start-Sleep -Seconds 2
                }

                if ($ready) {
                    Write-Log "Sunshine online em ${VMIP}:${SunshinePort}!" 'OK'
                }
                else {
                    Write-Log "VM iniciada, mas Sunshine ainda inicializando em ${VMIP}:${SunshinePort}." 'WARN'
                }
            }
            else {
                Write-Log "VM '$VMName' já está em execução." 'OK'
            }
        }
    }
}

# ==============================================================================
# Resolução do Modo (Toggle automático vs explícito)
# ==============================================================================
$effectiveMode = $Mode
if ($effectiveMode -eq 'Toggle') {
    $moonlightRunning = @(Get-Process -Name 'Moonlight' -ErrorAction SilentlyContinue).Count -gt 0
    if ($moonlightRunning -or -not (Test-Path -LiteralPath $StateFile)) {
        $effectiveMode = 'Game'
    }
    else {
        $effectiveMode = 'AI'
    }
    Write-Log "Modo Toggle detectou transição para: $effectiveMode" 'INFO'
}

# ==============================================================================
# Execução
# ==============================================================================
if ($effectiveMode -eq 'Game') {
    Write-Log '=== Ativando MODO BF6 / GAMING (Liberando VRAM e pausando streaming) ===' 'STEP'

    Invoke-UnloadVmVram -ServicesCsv $AiServicesRaw -ForceRestart $ShouldForceRestart
    Stop-OrMinimizeMoonlight -Minimize $MinimizeOnly.IsPresent

    if ($SuspendVM) {
        Invoke-HyperVPowerAction -Action 'Save'
    }
    elseif ($StopVM) {
        Invoke-HyperVPowerAction -Action 'Stop'
    }

    Set-Content -LiteralPath $StateFile -Value (Get-Date -Format 'o') -Encoding UTF8
    Write-Log '=== MODO BF6 ATIVO! VRAM livre e streaming em repouso. Bom jogo! ===' 'OK'
}
else {
    Write-Log '=== Retornando ao MODO IA (VM Hyprland + Moonlight) ===' 'STEP'

    if (Test-IsAdministrator) {
        Invoke-HyperVPowerAction -Action 'Start'
    }
    else {
        Write-Log 'Executando sem elevação Admin — assumindo que a VM já está ligada (se suspensa, rode como Admin).' 'INFO'
    }

    if (Test-Path -LiteralPath $MoonlightPath) {
        $existingMoonlight = @(Get-Process -Name 'Moonlight' -ErrorAction SilentlyContinue)
        if ($existingMoonlight.Count -eq 0) {
            if ($MoonlightAutoStream) {
                Write-Log "Abrindo Moonlight conectando diretamente em '$SunshineAppName' ($VMIP)..." 'INFO'
                Start-Process -FilePath $MoonlightPath -ArgumentList @('stream', $VMIP, $SunshineAppName)
            }
            else {
                Write-Log "Abrindo Moonlight ($MoonlightPath)..." 'INFO'
                Start-Process -FilePath $MoonlightPath
            }
            Write-Log 'Moonlight iniciado.' 'OK'
        }
        else {
            Write-Log 'Moonlight já está aberto.' 'OK'
        }
    }
    else {
        Write-Log "Moonlight.exe não encontrado em '$MoonlightPath'. Ajuste MOONLIGHT_EXE_PATH no .env." 'WARN'
    }

    if (Test-Path -LiteralPath $StateFile) {
        Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    }
    Write-Log '=== MODO IA ATIVO! ===' 'OK'
}
