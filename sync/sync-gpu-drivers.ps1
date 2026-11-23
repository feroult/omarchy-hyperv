#Requires -Version 5.1
<#
.SYNOPSIS
    Sincroniza drivers NVIDIA do Windows Host (DriverStore + lxss\lib) para a VM Linux GPU-P.
.DESCRIPTION
    Executar sempre que o driver NVIDIA for atualizado no Windows:
      1. Localiza dinamicamente em C:\Windows\System32\DriverStore\FileRepository a pasta
         mais recente com prefixo `nv*` que contenha `nvlddmkm.sys` (compatível com RTX 40/50,
         ex: `nv_dispi`, `nv_dispig`, etc. — sem hardcode).
      2. Coleta os binários WSL2 (`libcuda.so*`, `libd3d12.so`, `libdxcore.so`, `nvidia-smi`, etc.)
         de `C:\Windows\System32\lxss\lib` e da pasta do driver NVIDIA.
      3. Envia via SCP (chave SSH sem senha) para `/usr/lib/wsl/lib` e `/usr/lib/wsl/drivers` na VM.
      4. Cria symlinks necessários, executa `sudo ldconfig` e valida rodando `nvidia-smi` na VM.

.EXAMPLE
    .\sync\sync-gpu-drivers.ps1
.EXAMPLE
    .\sync\sync-gpu-drivers.ps1 -VMIP 192.168.50.2 -VMUser linuxia
#>

[CmdletBinding()]
param(
    [string]$EnvFile,
    [string]$VMIP,
    [string]$VMUser,
    [int]$SSHPort,
    [string]$SSHKeyPath,
    [switch]$CleanOldDrivers = $true
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

$VMIP       = if ($VMIP)        { $VMIP }        else { Get-ConfigValue $cfg 'VM_IP' '192.168.50.2' }
$VMUser     = if ($VMUser)      { $VMUser }      else { Get-ConfigValue $cfg 'VM_USER' 'linuxia' }
$SSHPort    = if ($SSHPort -gt 0) { $SSHPort }   else { [int](Get-ConfigValue $cfg 'SSH_PORT' 22) }
$SSHKeyPath = Resolve-SshKeyPath $(if ($SSHKeyPath) { $SSHKeyPath } else { Get-ConfigValue $cfg 'SSH_KEY_PATH_WIN' '' })

$DriverStoreRoot = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
$WslProgramLibDir = Join-Path $env:ProgramFiles 'WSL\lib'
$LxssLibDir       = Join-Path $env:SystemRoot 'System32\lxss\lib'

Write-Log "=== Winix :: Sync Drivers NVIDIA GPU-P -> ${VMUser}@${VMIP} ===" 'STEP'

# Verifica binários ssh / scp
foreach ($tool in @('ssh', 'scp')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Comando '$tool' não encontrado no PATH. Habilite o OpenSSH Client no Windows."
    }
}

$sshArgs = Get-SshBaseArgs -KeyPath $SSHKeyPath -Port $SSHPort
$scpArgs = Get-SshBaseArgs -KeyPath $SSHKeyPath -Port $SSHPort -ForScp
$remote  = "${VMUser}@${VMIP}"

# ==============================================================================
# 1. Localização dinâmica da pasta mais recente do driver NVIDIA (nv* + nvlddmkm.sys)
# ==============================================================================
Write-Log "Buscando driver NVIDIA mais recente em '$DriverStoreRoot' (filtro: nv* contendo nvlddmkm.sys)..." 'STEP'

if (-not (Test-Path -LiteralPath $DriverStoreRoot)) {
    throw "Diretório DriverStore não encontrado: $DriverStoreRoot"
}

$nvCandidates = Get-ChildItem -LiteralPath $DriverStoreRoot -Directory -Filter 'nv*' |
    ForEach-Object {
        $sysFile = Join-Path $_.FullName 'nvlddmkm.sys'
        if (Test-Path -LiteralPath $sysFile) {
            [PSCustomObject]@{
                Directory     = $_
                Name          = $_.Name
                FullName      = $_.FullName
                SysLastWrite  = (Get-Item -LiteralPath $sysFile).LastWriteTime
            }
        }
    } | Sort-Object -Property SysLastWrite -Descending

if (-not $nvCandidates -or @($nvCandidates).Count -eq 0) {
    throw "Nenhuma pasta 'nv*' contendo 'nvlddmkm.sys' encontrada em '$DriverStoreRoot'. Verifique se o driver NVIDIA está instalado."
}

$candidatesList = @($nvCandidates)
Write-Log "Drivers NVIDIA encontrados no DriverStore ($($candidatesList.Count)):" 'INFO'
foreach ($c in $candidatesList) {
    Write-Log "  - $($c.Name) (nvlddmkm.sys: $($c.SysLastWrite.ToString('yyyy-MM-dd HH:mm:ss')))" 'INFO'
}

$latestDriver = $candidatesList[0]
Write-Log "Selecionado driver mais recente: $($latestDriver.Name)" 'OK'

# ==============================================================================
# 2. Validação da conectividade SSH sem senha com a VM
# ==============================================================================
Write-Log "Testando conexão SSH sem senha com $remote..." 'STEP'

$sshTest = Invoke-NativeCapture -FilePath 'ssh' -Arguments ($sshArgs + @($remote, 'echo WINIX_SSH_OK'))
if ($sshTest.ExitCode -ne 0 -or ($sshTest.Output -join "`n") -notmatch 'WINIX_SSH_OK') {
    Write-Log "Falha na autenticação SSH sem senha com $remote." 'ERROR'
    Write-Host ''
    Write-Host '  Configure a chave SSH sem senha primeiro:' -ForegroundColor Yellow
    Write-Host '    1) ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\id_ed25519" -N ""'
    Write-Host "    2) type `"`$env:USERPROFILE\.ssh\id_ed25519.pub`" | ssh -p $SSHPort $remote `"mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys`""
    Write-Host ''
    throw "SSH falhou (exit=$($sshTest.ExitCode)): $($sshTest.Output -join ' ')"
}
Write-Log 'Conexão SSH validada.' 'OK'

# ==============================================================================
# 3. Preparação dos diretórios remotos e staging local dos binários WSL/CUDA
# ==============================================================================
Write-Log 'Preparando /usr/lib/wsl/lib e /usr/lib/wsl/drivers na VM...' 'STEP'

$prepCmd = if ($CleanOldDrivers) {
    'mkdir -p /usr/lib/wsl/lib /usr/lib/wsl/drivers && rm -rf /usr/lib/wsl/drivers/nv* /usr/lib/wsl/lib/*'
}
else {
    'mkdir -p /usr/lib/wsl/lib /usr/lib/wsl/drivers'
}

$prepRes = Invoke-NativeCapture -FilePath 'ssh' -Arguments ($sshArgs + @($remote, $prepCmd))
if ($prepRes.ExitCode -ne 0) {
    throw "Falha ao preparar diretórios remotos em /usr/lib/wsl: $($prepRes.Output -join ' '). Verifique se pertencem ao usuário da VM (execute 02-setup-vm.sh)."
}

# Cria staging temporário reunindo EXATAMENTE as duas fontes oficiais do WSL2:
#   1) C:\Program Files\WSL\lib      -> libdxcore.so, libd3d12.so, libd3d12core.so
#   2) C:\Windows\System32\lxss\lib  -> shims/loaders WSL da NVIDIA (libcuda.so*, libnvidia-ml.so.1, nvidia-smi, etc.)
# OBS: NÃO copiar .so brutos do DriverStore para /usr/lib/wsl/lib — eles ficam exclusivamente em /usr/lib/wsl/drivers/<nv*>.
$stagingDir = Join-Path $env:TEMP ("winix-wsl-lib-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

try {
    $copiedCount = 0

    if (Test-Path -LiteralPath $WslProgramLibDir) {
        Write-Log "Coletando binários D3D12/DXCore de '$WslProgramLibDir'..." 'INFO'
        Get-ChildItem -LiteralPath $WslProgramLibDir -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $stagingDir -Force
            $copiedCount++
        }
    }
    else {
        Write-Log "Aviso: '$WslProgramLibDir' não encontrado (verifique se o WSL2 está atualizado via 'wsl --update')." 'WARN'
    }

    if (Test-Path -LiteralPath $LxssLibDir) {
        Write-Log "Coletando loaders CUDA/NVML de '$LxssLibDir'..." 'INFO'
        Get-ChildItem -LiteralPath $LxssLibDir -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $stagingDir -Force
            $copiedCount++
        }
    }
    else {
        Write-Log "Aviso: '$LxssLibDir' não encontrado (verifique se o driver NVIDIA e o WSL2 estão instalados)." 'WARN'
    }

    if ($copiedCount -eq 0) {
        throw 'Nenhum binário CUDA/D3D12/DXCore foi encontrado em Program Files\WSL\lib ou System32\lxss\lib.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $stagingDir 'libdxcore.so'))) {
        Write-Log 'Aviso crítico: libdxcore.so não encontrado no staging! Sem ele o NVML/D3D12 não inicializa.' 'WARN'
    }
    Write-Log "$copiedCount arquivos preparados para /usr/lib/wsl/lib." 'OK'

    # ==========================================================================
    # 4. Transferência via SCP para /usr/lib/wsl/lib e /usr/lib/wsl/drivers
    # ==========================================================================
    Write-Log 'Enviando bibliotecas para /usr/lib/wsl/lib via SCP...' 'STEP'
    $libFiles = @(Get-ChildItem -LiteralPath $stagingDir -File | ForEach-Object { $_.FullName })
    $scpLib = Invoke-NativeCapture -FilePath 'scp' -Arguments ($scpArgs + $libFiles + @("${remote}:/usr/lib/wsl/lib/"))
    if ($scpLib.ExitCode -ne 0) {
        throw "Falha no SCP para /usr/lib/wsl/lib/: $($scpLib.Output -join ' ')"
    }
    Write-Log 'Bibliotecas enviadas para /usr/lib/wsl/lib.' 'OK'

    Write-Log "Enviando pasta do driver '$($latestDriver.Name)' para /usr/lib/wsl/drivers/ via SCP (pode levar alguns segundos)..." 'STEP'
    $scpDrv = Invoke-NativeCapture -FilePath 'scp' -Arguments ($scpArgs + @('-r', $latestDriver.FullName, "${remote}:/usr/lib/wsl/drivers/"))
    if ($scpDrv.ExitCode -ne 0) {
        throw "Falha no SCP da pasta do driver '$($latestDriver.Name)': $($scpDrv.Output -join ' ')"
    }
    Write-Log "Driver '$($latestDriver.Name)' sincronizado em /usr/lib/wsl/drivers/." 'OK'
}
finally {
    if (Test-Path -LiteralPath $stagingDir) {
        Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# 5. Symlinks padrão CUDA/NVML + ldconfig + Validação com nvidia-smi na VM
# ==============================================================================
Write-Log 'Ajustando symlinks, permissões e rodando ldconfig na VM...' 'STEP'

$postSyncScript = @'
set -euo pipefail
cd /usr/lib/wsl/lib

# Permissões executáveis em bibliotecas e binários utilitários
chmod 755 /usr/lib/wsl/lib/*.so* 2>/dev/null || true
[ -f nvidia-smi ] && chmod 755 nvidia-smi || true
[ -f nvidia-ngx-updater ] && chmod 755 nvidia-ngx-updater || true

# Cria apenas symlinks faltantes (preservando loaders oficiais copiados de lxss\lib)
if [ -f libcuda.so.1.1 ] && [ ! -e libcuda.so.1 ]; then
    ln -sf libcuda.so.1.1 libcuda.so.1
fi
if [ -f libcuda.so.1 ] && [ ! -e libcuda.so ]; then
    ln -sf libcuda.so.1 libcuda.so
fi

for base in libnvidia-ml libnvcuvid libnvidia-encode libnvidia-opticalflow libd3d12 libdxcore; do
    if [ -f "${base}.so.1" ] && [ ! -e "${base}.so" ]; then
        ln -sf "${base}.so.1" "${base}.so"
    fi
done

# Atualiza cache do linker dinâmico (compatível com sudoers mínimo /etc/sudoers.d/99-winix-ops)
if sudo -n ldconfig 2>/dev/null; then
    echo "[VM] ldconfig atualizado com sucesso."
elif sudo -n true 2>/dev/null; then
    echo "/usr/lib/wsl/lib" | sudo tee /etc/ld.so.conf.d/99-winix-wsl.conf >/dev/null
    sudo ldconfig
    echo "[VM] ld.so.conf.d e ldconfig atualizados."
else
    echo "[WARN] sudo sem senha indisponível para ldconfig; bibliotecas ainda serão carregadas via LD_LIBRARY_PATH."
fi
'@

# Codifica em Base64 (LF puro) para evitar inserção de CRLF pelo pipe do PowerShell 5.1
$postSyncScriptUnix = ($postSyncScript -replace "`r`n", "`n") + "`n"
$postSyncB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($postSyncScriptUnix))
$postRes = Invoke-NativeCapture -FilePath 'ssh' -Arguments ($sshArgs + @($remote, "printf '%s' '$postSyncB64' | base64 -d | bash"))
if ($postRes.ExitCode -ne 0) {
    throw "Erro ao ajustar symlinks ou executar ldconfig remotamente: $($postRes.Output -join ' ')"
}
foreach ($line in $postRes.Output) {
    if ($line) { Write-Log "  $line" 'INFO' }
}
Write-Log 'Symlinks e ldconfig concluídos.' 'OK'

Write-Log 'Validando GPU-P executando nvidia-smi na VM...' 'STEP'
$smiRes = Invoke-NativeCapture -FilePath 'ssh' -Arguments ($sshArgs + @($remote, 'LD_LIBRARY_PATH=/usr/lib/wsl/lib /usr/lib/wsl/lib/nvidia-smi'))
if ($smiRes.ExitCode -ne 0) {
    Write-Host ($smiRes.Output -join "`n") -ForegroundColor Red
    throw 'Validação via nvidia-smi falhou na VM. Verifique se /dev/dxg existe e se o módulo dxgkrnl está carregado.'
}

Write-Host ''
Write-Host ($smiRes.Output -join "`n") -ForegroundColor Green
Write-Host ''
Write-Log "=== Sincronização validada com sucesso! Driver ativo: $($latestDriver.Name) ===" 'OK'
