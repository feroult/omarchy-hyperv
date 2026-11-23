#Requires -Version 5.1
<#
.SYNOPSIS
    Funções utilitárias compartilhadas pelos scripts PowerShell do projeto Winix.
.DESCRIPTION
    Fornece carregamento centralizado de variáveis a partir do arquivo `.env`
    na raiz do repositório, logging padronizado com timestamps e utilitários SSH.
#>

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'HH:mm:ss'
    $color = switch ($Level) {
        'INFO'  { 'Cyan' }
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'STEP'  { 'Magenta' }
    }

    $prefix = "[$timestamp] [$Level]"
    Write-Host "$prefix $Message" -ForegroundColor $color
}

function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Import-WinixEnv {
    <#
    .SYNOPSIS
        Carrega variáveis do arquivo `.env` (ou `.env.example` como fallback) em um Hashtable.
    #>
    [CmdletBinding()]
    param(
        [string]$EnvPath
    )

    $repoRoot = Get-RepoRoot
    if (-not $EnvPath) {
        $candidate = Join-Path $repoRoot '.env'
        if (Test-Path -LiteralPath $candidate) {
            $EnvPath = $candidate
        }
        else {
            $example = Join-Path $repoRoot '.env.example'
            if (Test-Path -LiteralPath $example) {
                $EnvPath = $example
            }
        }
    }

    $config = @{}
    if (-not $EnvPath -or -not (Test-Path -LiteralPath $EnvPath)) {
        return $config
    }

    foreach ($rawLine in Get-Content -LiteralPath $EnvPath -Encoding UTF8) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
            continue
        }

        $eqIndex = $line.IndexOf('=')
        if ($eqIndex -lt 1) {
            continue
        }

        $key = $line.Substring(0, $eqIndex).Trim()
        $value = $line.Substring($eqIndex + 1).Trim()

        # Remove aspas externas opcionais
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        # Expande variáveis de ambiente estilo %USERPROFILE%
        $value = [Environment]::ExpandEnvironmentVariables($value)
        $config[$key] = $value
    }

    return $config
}

function Get-ConfigValue {
    param(
        [hashtable]$Config,
        [string]$Key,
        [object]$Default
    )

    if ($Config -and $Config.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace([string]$Config[$Key])) {
        return $Config[$Key]
    }
    return $Default
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-SshKeyPath {
    param(
        [string]$ConfiguredPath
    )

    if ($ConfiguredPath) {
        $expanded = [Environment]::ExpandEnvironmentVariables($ConfiguredPath)
        if ($expanded.StartsWith('~')) {
            $expanded = Join-Path $env:USERPROFILE $expanded.Substring(1).TrimStart('\', '/')
        }
        return $expanded
    }

    return (Join-Path $env:USERPROFILE '.ssh\id_ed25519')
}

function Get-SshBaseArgs {
    param(
        [string]$KeyPath,
        [int]$Port = 22,
        [int]$ConnectTimeout = 8,
        [switch]$ForScp
    )

    $argsList = @(
        '-o', 'BatchMode=yes',
        '-o', "ConnectTimeout=$ConnectTimeout",
        '-o', 'StrictHostKeyChecking=accept-new'
    )

    if ($ForScp) {
        $argsList += @('-P', "$Port")
    }
    else {
        $argsList += @('-p', "$Port")
    }

    if ($KeyPath -and (Test-Path -LiteralPath $KeyPath)) {
        $argsList += @('-i', $KeyPath)
    }

    return $argsList
}

function Invoke-NativeCapture {
    <#
    .SYNOPSIS
        Executa um comando nativo (ex: ssh/scp) capturando stdout+stderr sem disparar
        NativeCommandError no Windows PowerShell 5.1 quando $ErrorActionPreference = 'Stop'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @(),

        [string]$StdInText
    )

    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $rawOutput = if ($PSBoundParameters.ContainsKey('StdInText')) {
            $StdInText | & $FilePath @Arguments 2>&1
        }
        else {
            & $FilePath @Arguments 2>&1
        }
        $exitCode = $LASTEXITCODE
        $lines = @($rawOutput | ForEach-Object { $_.ToString() })
        return [PSCustomObject]@{
            ExitCode = $exitCode
            Output   = $lines
        }
    }
    finally {
        $ErrorActionPreference = $prevPref
    }
}

