#Requires -Version 5.1
<#
.SYNOPSIS
    Desconecta automaticamente o Moonlight após X minutos fora de foco no Windows.
.DESCRIPTION
    Watcher ultra-leve (~0% CPU, verifica a cada 15s via Win32 GetForegroundWindow) que:
      - Monitora se o `Moonlight.exe` está aberto.
      - Se você der Alt+Tab para o Windows e ficar `IdleMinutes` (padrão: 30 min) sem
        voltar o foco para o Moonlight, encerra o `Moonlight.exe` graciosamente.
      - Isso coloca o Sunshine em repouso (0% CPU / temperatura volta para ~59°C)
        mantendo a VM Omarchy e todas as suas janelas Linux 100% intactas.
      - Se você voltar para o Moonlight antes do tempo acabar, o cronômetro zera automaticamente.

.EXAMPLE
    # Instalar para rodar silenciosamente em segundo plano a cada login no Windows (recomendado):
    .\windows\moonlight-auto-disconnect.ps1 -InstallStartup

.EXAMPLE
    # Instalar com tempo customizado (ex: 20 minutos):
    .\windows\moonlight-auto-disconnect.ps1 -InstallStartup -IdleMinutes 20

.EXAMPLE
    # Verificar status ou remover inicialização automática:
    .\windows\moonlight-auto-disconnect.ps1 -Status
    .\windows\moonlight-auto-disconnect.ps1 -UninstallStartup
#>

[CmdletBinding()]
param(
    [string]$EnvFile,
    [int]$IdleMinutes = 0,
    [int]$PollSeconds = 15,
    [switch]$AlsoUnloadVram,
    [switch]$InstallStartup,
    [switch]$UninstallStartup,
    [switch]$Status
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ==============================================================================
# Helpers & Configuração Centralizada (suporta execução standalone via %LOCALAPPDATA%)
# ==============================================================================
$commonScript = Join-Path $PSScriptRoot 'common.ps1'
$cfg = @{}
if (Test-Path -LiteralPath $commonScript) {
    . $commonScript
    $cfg = Import-WinixEnv -EnvPath $EnvFile
}
else {
    function Write-Log {
        param([string]$Message, [string]$Level = 'INFO')
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message"
    }
    function Get-ConfigValue {
        param([hashtable]$Config, [string]$Key, [object]$Default)
        return $Default
    }
}

if ($IdleMinutes -le 0) {
    $IdleMinutes = [int](Get-ConfigValue $cfg 'MOONLIGHT_IDLE_DISCONNECT_MIN' 30)
}
if ($PollSeconds -lt 5) {
    $PollSeconds = 5
}

$TaskName       = 'Omarchy-Moonlight-AutoDisconnect'
$LocalInstallDir = Join-Path $env:LOCALAPPDATA 'omarchy-hyperv'
$LocalScriptPath = Join-Path $LocalInstallDir 'moonlight-auto-disconnect.ps1'
$LogFile         = Join-Path $env:TEMP 'omarchy-moonlight-watchdog.log'

function Write-WatchdogLog {
    param([string]$Msg)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] $Msg"
    try {
        if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt 204800)) {
            Set-Content -LiteralPath $LogFile -Value "[$ts] [LOG ROTATED]" -Encoding UTF8
        }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    }
    catch { }
    if ($Host.Name -eq 'ConsoleHost') {
        Write-Host $line -ForegroundColor Cyan
    }
}

# ==============================================================================
# Gerenciamento da Tarefa Agendada (Login do usuário atual — não exige Admin)
# ==============================================================================
if ($Status) {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        Write-Log "Tarefa '$TaskName': $($task.State) | Última execução: $($info.LastRunTime)" 'OK'
    }
    else {
        Write-Log "Tarefa '$TaskName' não instalada." 'WARN'
    }
    if (Test-Path -LiteralPath $LogFile) {
        Write-Host ''
        Write-Host "Últimas linhas do log ($LogFile):" -ForegroundColor White
        Get-Content -LiteralPath $LogFile -Tail 10
    }
    exit 0
}

if ($UninstallStartup) {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Log "Tarefa '$TaskName' removida." 'OK'
    }
    else {
        Write-Log "Tarefa '$TaskName' não estava instalada." 'INFO'
    }
    if (Test-Path -LiteralPath $LocalScriptPath) {
        Remove-Item -LiteralPath $LocalScriptPath -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

if ($InstallStartup) {
    # Copia para %LOCALAPPDATA% no Windows para não depender de \\wsl.localhost estar montado no logon
    if (-not (Test-Path -LiteralPath $LocalInstallDir)) {
        New-Item -ItemType Directory -Path $LocalInstallDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $PSCommandPath -Destination $LocalScriptPath -Force

    $argString = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$LocalScriptPath`" -IdleMinutes $IdleMinutes -PollSeconds $PollSeconds"
    if ($AlsoUnloadVram) {
        $argString += ' -AlsoUnloadVram'
    }

    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argString
    $trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Description "Encerra o Moonlight automaticamente após $IdleMinutes min fora de foco para zerar CPU/temperatura da VM Omarchy." `
        -Force | Out-Null

    Start-ScheduledTask -TaskName $TaskName
    Write-Log "Watcher instalado e iniciado! Desconexão automática após $IdleMinutes min fora de foco." 'OK'
    Write-Log "Log em: $LogFile" 'INFO'
    exit 0
}

# ==============================================================================
# Instância única (Mutex) + Win32 Foreground Window Check
# ==============================================================================
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\OmarchyMoonlightAutoDisconnect', [ref]$createdNew)
if (-not $createdNew) {
    Write-WatchdogLog 'Outra instância do watcher já está em execução. Encerrando duplicata.'
    exit 0
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class WinixFocusHelper {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
}
"@ -ErrorAction SilentlyContinue

function Test-MoonlightHasFocus {
    param([System.Diagnostics.Process[]]$MoonlightProcs)

    $hwnd = [WinixFocusHelper]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return $false }

    [uint32]$fgPid = 0
    [void][WinixFocusHelper]::GetWindowThreadProcessId($hwnd, [ref]$fgPid)
    foreach ($p in $MoonlightProcs) {
        if ($p.Id -eq $fgPid) { return $true }
    }
    return $false
}

function Close-MoonlightGracefully {
    param([System.Diagnostics.Process[]]$MoonlightProcs)

    foreach ($p in $MoonlightProcs) {
        try { $null = $p.CloseMainWindow() } catch { }
    }
    Start-Sleep -Seconds 2
    $stillRunning = @(Get-Process -Name 'Moonlight' -ErrorAction SilentlyContinue)
    if ($stillRunning.Count -gt 0) {
        $stillRunning | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# Loop principal ultra-leve (~0% CPU)
# ==============================================================================
$idleThreshold = [TimeSpan]::FromMinutes($IdleMinutes)
$unfocusedSince = $null

Write-WatchdogLog "Watcher iniciado (IdleMinutes=$IdleMinutes, PollSeconds=$PollSeconds, AlsoUnloadVram=$AlsoUnloadVram)."

try {
    while ($true) {
        $procs = @(Get-Process -Name 'Moonlight' -ErrorAction SilentlyContinue)

        if ($procs.Count -eq 0) {
            $unfocusedSince = $null
        }
        elseif (Test-MoonlightHasFocus -MoonlightProcs $procs) {
            if ($null -ne $unfocusedSince) {
                Write-WatchdogLog 'Moonlight voltou ao foco; cronômetro resetado.'
                $unfocusedSince = $null
            }
        }
        else {
            if ($null -eq $unfocusedSince) {
                $unfocusedSince = Get-Date
                Write-WatchdogLog "Moonlight saiu de foco; iniciando contagem de $IdleMinutes min."
            }
            else {
                $elapsed = (Get-Date) - $unfocusedSince
                if ($elapsed -ge $idleThreshold) {
                    Write-WatchdogLog "Moonlight ficou $([math]::Round($elapsed.TotalMinutes, 1)) min fora de foco. Encerrando para colocar Sunshine em repouso..."
                    Close-MoonlightGracefully -MoonlightProcs $procs

                    if ($AlsoUnloadVram) {
                        $toggleScript = Join-Path $PSScriptRoot 'toggle-host-mode.ps1'
                        if (Test-Path -LiteralPath $toggleScript) {
                            try { & $toggleScript -Mode Host | Out-Null } catch { }
                        }
                    }

                    $unfocusedSince = $null
                    Write-WatchdogLog 'Moonlight encerrado com sucesso. Sunshine em repouso (0% CPU).'
                }
            }
        }

        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}
