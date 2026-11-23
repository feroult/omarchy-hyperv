#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Provisiona a infraestrutura Hyper-V + GPU-P (NVIDIA) no Windows Host bare-metal.
.DESCRIPTION
    Script idempotente que:
      1. Valida que Microsoft-Hyper-V-All está habilitado (mantendo Secure Boot no host e WSL2 intactos).
      2. Cria o Internal Virtual Switch (Switch-Interno-IA), IP estático 192.168.50.1/24 e NetNat 192.168.50.0/24.
      3. Cria/atualiza a VM Gen2 (Linux-Hyprland-IA) na partição NVMe dedicada D:\ com:
         - Secure Boot desativado APENAS na VM;
         - Checkpoints desativados (obrigatório para GPU-P);
         - 16 vCPUs (Ryzen 9 9950X) e Memória Dinâmica (Startup 8GB, Min 4GB, Max 32GB);
         - Pasta da VM em D:\VMs\Linux-Hyprland-IA e VHDX dinâmico de 1500GB (1.5 TB);
         - GPU-P anexada EXCLUSIVAMENTE à NVIDIA dedicada (VEN_10DE), ignorando iGPU AMD (VEN_1002);
         - LowMemoryMappedIoSpace 1GB e HighMemoryMappedIoSpace 64GB.
      4. Anexa a ISO do Omarchy (ou Arch/Ubuntu) e opcionalmente inicia a VM e o vmconnect.
         Opcional: `-AttachInstallSwitch` adiciona temporariamente o `Default Switch` (DHCP)
         para facilitar a instalação online do Omarchy; após o setup, rode `-RemoveInstallSwitch`.

.EXAMPLE
    .\windows\01-create-vm.ps1 -StartVM
.EXAMPLE
    .\windows\01-create-vm.ps1 -AttachInstallSwitch -StartVM
.EXAMPLE
    .\windows\01-create-vm.ps1 -RemoveInstallSwitch -SkipISO -NoVmConnect
#>

[CmdletBinding()]
param(
    [string]$EnvFile,
    [string]$VMName,
    [string]$VMPath,
    [string]$ISOPath,
    [string]$VHDPath,
    [int]$VHDSizeGB,
    [int]$CPUCount,
    [int]$MemoryStartupGB,
    [int]$MemoryMinGB,
    [int]$MemoryMaxGB,
    [switch]$AttachInstallSwitch,
    [switch]$RemoveInstallSwitch,
    [switch]$SkipISO,
    [switch]$NoVmConnect,
    [switch]$StartVM
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ==============================================================================
# Carregamento de helpers e configuração centralizada (.env + defaults)
# ==============================================================================
$commonScript = Join-Path $PSScriptRoot 'common.ps1'
if (-not (Test-Path -LiteralPath $commonScript)) {
    throw "Arquivo auxiliar não encontrado: $commonScript"
}
. $commonScript

$cfg = Import-WinixEnv -EnvPath $EnvFile

# Parâmetros efetivos (prioridade: parâmetro CLI > .env > padrão)
$VMName          = if ($VMName)          { $VMName }          else { Get-ConfigValue $cfg 'VM_NAME' 'Linux-Hyprland-IA' }
$SwitchName      = Get-ConfigValue $cfg 'SWITCH_NAME' 'Switch-Interno-IA'
$NatName         = Get-ConfigValue $cfg 'NAT_NAME' 'NAT-Interno-IA'
$HostIP          = Get-ConfigValue $cfg 'HOST_IP' '192.168.50.1'
$PrefixLength    = [int](Get-ConfigValue $cfg 'NET_PREFIX_LENGTH' 24)
$NatSubnet       = Get-ConfigValue $cfg 'NAT_SUBNET' '192.168.50.0/24'
$VMPath          = if ($VMPath)          { $VMPath }          else { Get-ConfigValue $cfg 'VM_PATH' 'D:\VMs\Linux-Hyprland-IA' }
$VHDPath         = if ($VHDPath)         { $VHDPath }         else { Get-ConfigValue $cfg 'VM_VHD_PATH' (Join-Path $VMPath "$VMName.vhdx") }
$VHDSizeGB       = if ($VHDSizeGB -gt 0) { $VHDSizeGB }       else { [int](Get-ConfigValue $cfg 'VM_VHD_SIZE_GB' 1500) }
$VHDSize         = [uint64]$VHDSizeGB * 1GB
$ISOPath         = if ($ISOPath)         { $ISOPath }         else { Get-ConfigValue $cfg 'VM_ISO_PATH' 'D:\ISOs\omarchy.iso' }
$CPUCount        = if ($CPUCount -gt 0)  { $CPUCount }        else { [int](Get-ConfigValue $cfg 'VM_CPU_COUNT' 16) }
$MemoryStartupGB = if ($MemoryStartupGB -gt 0) { $MemoryStartupGB } else { [int](Get-ConfigValue $cfg 'VM_MEMORY_STARTUP_GB' 8) }
$MemoryMinGB     = if ($MemoryMinGB -gt 0)     { $MemoryMinGB }     else { [int](Get-ConfigValue $cfg 'VM_MEMORY_MIN_GB' 4) }
$MemoryMaxGB     = if ($MemoryMaxGB -gt 0)     { $MemoryMaxGB }     else { [int](Get-ConfigValue $cfg 'VM_MEMORY_MAX_GB' 32) }
$GpuVendorFilter = Get-ConfigValue $cfg 'GPU_VENDOR_FILTER' '*VEN_10DE*'
$GpuDeviceFilter = Get-ConfigValue $cfg 'GPU_DEVICE_FILTER' '*VEN_10DE&DEV_2C05*'
$LowMmioGB       = [int](Get-ConfigValue $cfg 'VM_LOW_MMIO_GB' 1)
$HighMmioGB      = [int](Get-ConfigValue $cfg 'VM_HIGH_MMIO_GB' 64)

Write-Log "=== Winix :: Provisionamento Hyper-V GPU-P ($VMName) ===" 'STEP'

# ==============================================================================
# 1. Validação de Hyper-V no Host (sem tocar em Secure Boot do host ou WSL2)
# ==============================================================================
Write-Log 'Verificando feature Microsoft-Hyper-V-All e serviço vmms...' 'STEP'

$hvFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($hvFeature.State -ne 'Enabled') {
    throw "A feature 'Microsoft-Hyper-V-All' não está habilitada (estado atual: $($hvFeature.State)). Habilite-a antes de executar este script."
}
Write-Log 'Microsoft-Hyper-V-All está ativo.' 'OK'

$vmms = Get-Service -Name 'vmms' -ErrorAction Stop
if ($vmms.Status -ne 'Running') {
    Write-Log 'Iniciando serviço vmms (Hyper-V Virtual Machine Management)...' 'WARN'
    Start-Service -Name 'vmms'
}

# Confirma presença do módulo Hyper-V
Import-Module Hyper-V -ErrorAction Stop

# ==============================================================================
# 2. Internal Virtual Switch + IP Estático no Host + NetNat
# ==============================================================================
Write-Log "Configurando rede interna isolada ($SwitchName -> $HostIP/$PrefixLength, NAT $NatSubnet)..." 'STEP'

$existingSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if (-not $existingSwitch) {
    Write-Log "Criando VMSwitch interno '$SwitchName'..." 'INFO'
    New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
    Start-Sleep -Seconds 2
    Write-Log "VMSwitch '$SwitchName' criado." 'OK'
}
else {
    if ($existingSwitch.SwitchType -ne 'Internal') {
        throw "O VMSwitch '$SwitchName' já existe, mas tem tipo '$($existingSwitch.SwitchType)' (esperado: Internal)."
    }
    Write-Log "VMSwitch '$SwitchName' já existe (idempotente)." 'OK'
}

$adapterAlias = "vEthernet ($SwitchName)"
$netAdapter = Get-NetAdapter -Name $adapterAlias -ErrorAction SilentlyContinue
if (-not $netAdapter) {
    throw "Adaptador de rede '$adapterAlias' não encontrado após criação do switch."
}

$existingIP = Get-NetIPAddress -InterfaceIndex $netAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $HostIP -and $_.PrefixLength -eq $PrefixLength }

if (-not $existingIP) {
    # Remove IPs IPv4 antigos no adaptador interno para evitar conflitos
    $staleIPs = Get-NetIPAddress -InterfaceIndex $netAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' }
    foreach ($ip in $staleIPs) {
        Write-Log "Removendo IP anterior $($ip.IPAddress)/$($ip.PrefixLength) de '$adapterAlias'..." 'WARN'
        Remove-NetIPAddress -InputObject $ip -Confirm:$false
    }

    Write-Log "Atribuindo IP estático $HostIP/$PrefixLength ao adaptador '$adapterAlias'..." 'INFO'
    New-NetIPAddress -InterfaceIndex $netAdapter.ifIndex -IPAddress $HostIP -PrefixLength $PrefixLength | Out-Null
    Write-Log "IP $HostIP/$PrefixLength configurado." 'OK'
}
else {
    Write-Log "IP $HostIP/$PrefixLength já configurado em '$adapterAlias'." 'OK'
}

# Define perfil da rede interna como Private para evitar bloqueio de Sunshine/SSH pelo Firewall
try {
    $profile = Get-NetConnectionProfile -InterfaceIndex $netAdapter.ifIndex -ErrorAction SilentlyContinue
    if ($profile -and $profile.NetworkCategory -ne 'Private') {
        Set-NetConnectionProfile -InterfaceIndex $netAdapter.ifIndex -NetworkCategory Private
        Write-Log "Perfil de rede de '$adapterAlias' definido como Private." 'OK'
    }
}
catch {
    Write-Log "Não foi possível alterar o perfil de rede para Private (sem impacto crítico): $($_.Exception.Message)" 'WARN'
}

# Configura NetNat (Windows WinNAT permite apenas um objeto NetNat por prefixo / em geral um por host)
$existingNatByPrefix = Get-NetNat -ErrorAction SilentlyContinue |
    Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $NatSubnet }

if ($existingNatByPrefix) {
    Write-Log "NetNat '$($existingNatByPrefix.Name)' já cobre $NatSubnet." 'OK'
}
else {
    $existingNatByName = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
    if ($existingNatByName) {
        Write-Log "Recriando NetNat '$NatName' para apontar para $NatSubnet..." 'WARN'
        Remove-NetNat -Name $NatName -Confirm:$false
    }

    $otherNats = @(Get-NetNat -ErrorAction SilentlyContinue)
    if ($otherNats.Count -gt 0) {
        Write-Log "Atenção: já existe outro NetNat no host ($($otherNats.Name -join ', ')). O Windows pode limitar a criação de múltiplos NetNats simultâneos." 'WARN'
    }

    try {
        New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $NatSubnet | Out-Null
        Write-Log "NetNat '$NatName' ($NatSubnet) criado com sucesso." 'OK'
    }
    catch {
        throw "Falha ao criar NetNat '$NatName' ($NatSubnet): $($_.Exception.Message). Verifique 'Get-NetNat' para conflitos."
    }
}

# ==============================================================================
# 3. Criação / Configuração da VM Gen2
# ==============================================================================
Write-Log "Provisionando VM Gen2 '$VMName'..." 'STEP'

$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) {
    if (-not (Test-Path -LiteralPath $VMPath)) {
        New-Item -ItemType Directory -Path $VMPath -Force | Out-Null
        Write-Log "Diretório da VM criado: $VMPath" 'INFO'
    }

    $vhdDir = Split-Path -Path $VHDPath -Parent
    if (-not (Test-Path -LiteralPath $vhdDir)) {
        New-Item -ItemType Directory -Path $vhdDir -Force | Out-Null
        Write-Log "Diretório do VHDX criado: $vhdDir" 'INFO'
    }

    # Verifica unidade e espaço livre no destino do VHDX (ex: partição NVMe D:\ Linux-IA-VM)
    $driveRoot = [System.IO.Path]::GetPathRoot($VHDPath)
    if (-not (Test-Path -LiteralPath $driveRoot)) {
        throw "Unidade de armazenamento '$driveRoot' não encontrada. Verifique se a partição NVMe D:\ está montada."
    }
    $driveLetter = $driveRoot.Substring(0, 1)
    $volume = Get-Volume -DriveLetter $driveLetter -ErrorAction SilentlyContinue
    if ($volume) {
        $freeGB = [math]::Round($volume.SizeRemaining / 1GB, 1)
        $volLabel = if ($volume.FileSystemLabel) { " ($($volume.FileSystemLabel))" } else { '' }
        Write-Log "Espaço livre em ${driveLetter}:${volLabel}: ${freeGB} GB (VHDX dinâmico máximo: ${VHDSizeGB} GB)." 'INFO'
        if ($freeGB -lt 50) {
            Write-Log "Aviso: menos de 50 GB livres em ${driveLetter}:. Monitore o crescimento do VHDX." 'WARN'
        }
    }

    if (Test-Path -LiteralPath $VHDPath) {
        Write-Log "Reutilizando VHDX existente em '$VHDPath'..." 'WARN'
        $vm = New-VM `
            -Name $VMName `
            -Path $VMPath `
            -Generation 2 `
            -MemoryStartupBytes ([uint64]$MemoryStartupGB * 1GB) `
            -VHDPath $VHDPath `
            -SwitchName $SwitchName
    }
    else {
        Write-Log "Criando VHDX dinâmico (${VHDSizeGB} GB) em '$VHDPath' e VM '$VMName' em '$VMPath'..." 'INFO'
        $vm = New-VM `
            -Name $VMName `
            -Path $VMPath `
            -Generation 2 `
            -MemoryStartupBytes ([uint64]$MemoryStartupGB * 1GB) `
            -NewVHDPath $VHDPath `
            -NewVHDSizeBytes $VHDSize `
            -SwitchName $SwitchName
    }
    Write-Log "VM '$VMName' criada em '$VMPath'." 'OK'
}
else {
    Write-Log "VM '$VMName' já existe (estado: $($vm.State)). Validando configurações..." 'OK'
    if ($vm.State -ne 'Off') {
        throw "A VM '$VMName' está no estado '$($vm.State)'. Desligue a VM antes de re-executar o provisionamento de hardware/GPU-P."
    }

    # Garante que a NIC principal esteja conectada ao switch interno
    $nic = Get-VMNetworkAdapter -VMName $VMName | Select-Object -First 1
    if ($nic -and $nic.SwitchName -ne $SwitchName) {
        Connect-VMNetworkAdapter -VMNetworkAdapter $nic -SwitchName $SwitchName
        Write-Log "NIC principal da VM conectada ao switch '$SwitchName'." 'OK'
    }
}

# Switch temporário opcional (Default Switch com DHCP) para facilitar a instalação online da ISO do Omarchy
$installNicName = 'Winix-Install-DHCP'
if ($RemoveInstallSwitch) {
    $tempNics = @(Get-VMNetworkAdapter -VMName $VMName -Name $installNicName -ErrorAction SilentlyContinue)
    if ($tempNics.Count -gt 0) {
        $tempNics | Remove-VMNetworkAdapter
        Write-Log "NIC temporária '$installNicName' (Default Switch) removida. Apenas '$SwitchName' ativo." 'OK'
    }
    else {
        Write-Log "Nenhuma NIC temporária '$installNicName' encontrada (já removida)." 'INFO'
    }
}
elseif ($AttachInstallSwitch) {
    $defaultSwitch = Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue
    if ($defaultSwitch) {
        $existingTemp = @(Get-VMNetworkAdapter -VMName $VMName -Name $installNicName -ErrorAction SilentlyContinue)
        if ($existingTemp.Count -eq 0) {
            Add-VMNetworkAdapter -VMName $VMName -Name $installNicName -SwitchName 'Default Switch'
            Write-Log "NIC temporária '$installNicName' (Default Switch / DHCP) anexada para instalação do Omarchy." 'OK'
        }
        else {
            Write-Log "NIC temporária '$installNicName' já está anexada." 'OK'
        }
    }
    else {
        Write-Log "VMSwitch 'Default Switch' não encontrado; configure IP estático manualmente na ISO." 'WARN'
    }
}

Write-Log "Aplicando CPU ($CPUCount vCPUs), Memória Dinâmica (${MemoryMinGB}-${MemoryMaxGB}GB, Startup ${MemoryStartupGB}GB), Firmware e MMIO..." 'INFO'

Set-VMProcessor -VMName $VMName -Count $CPUCount

Set-VMMemory `
    -VMName $VMName `
    -DynamicMemoryEnabled $true `
    -StartupBytes ([uint64]$MemoryStartupGB * 1GB) `
    -MinimumBytes ([uint64]$MemoryMinGB * 1GB) `
    -MaximumBytes ([uint64]$MemoryMaxGB * 1GB)

# Desativa Secure Boot APENAS na VM (o host Windows bare-metal permanece com Secure Boot ON)
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off

# Checkpoints DESATIVADOS + GuestControlledCacheTypes + MMIO 1GB/64GB (requisitos críticos GPU-P)
# AutomaticStopAction ShutDown (Hyper-V GPU-P não suporta estado salvo no desligamento automático)
Set-VM `
    -Name $VMName `
    -CheckpointType Disabled `
    -AutomaticStopAction ShutDown `
    -GuestControlledCacheTypes $true `
    -LowMemoryMappedIoSpace ([uint64]$LowMmioGB * 1GB) `
    -HighMemoryMappedIoSpace ([uint64]$HighMmioGB * 1GB)

Write-Log "Configurações de CPU, RAM, Secure Boot (VM=Off), Checkpoints (Disabled) e MMIO (${LowMmioGB}GB/${HighMmioGB}GB) aplicadas." 'OK'

# ==============================================================================
# 4. Seleção Exclusiva da GPU NVIDIA (VEN_10DE) e Anexo GPU-P
# ==============================================================================
Write-Log 'Detectando GPUs particionáveis no host (ignorando AMD VEN_1002)...' 'STEP'

$allPartitionableGpus = @(Get-VMHostPartitionableGpu)
if ($allPartitionableGpus.Count -eq 0) {
    throw 'Nenhuma GPU particionável detectada via Get-VMHostPartitionableGpu.'
}

foreach ($gpu in $allPartitionableGpus) {
    if ($gpu.Name -like '*VEN_1002*') {
        Write-Log "  [IGNORADA - AMD iGPU] $($gpu.Name)" 'WARN'
    }
    elseif ($gpu.Name -like '*VEN_10DE*') {
        Write-Log "  [CANDIDATA - NVIDIA]  $($gpu.Name)" 'OK'
    }
    else {
        Write-Log "  [OUTRA GPU]           $($gpu.Name)" 'INFO'
    }
}

# Prioriza filtro específico (ex: VEN_10DE&DEV_2C05) e trava exclusivamente em NVIDIA (*VEN_10DE*), rejeitando AMD (*VEN_1002*)
$nvidiaGpus = @($allPartitionableGpus | Where-Object { $_.Name -like $GpuDeviceFilter -and $_.Name -like '*VEN_10DE*' -and $_.Name -notlike '*VEN_1002*' })
if ($nvidiaGpus.Count -eq 0) {
    $nvidiaGpus = @($allPartitionableGpus | Where-Object { $_.Name -like $GpuVendorFilter -and $_.Name -like '*VEN_10DE*' -and $_.Name -notlike '*VEN_1002*' })
}

if ($nvidiaGpus.Count -eq 0) {
    throw "Nenhuma GPU NVIDIA (*VEN_10DE*) foi encontrada para GPU-P. Abortando para evitar anexo incorreto da iGPU AMD (VEN_1002)."
}

$selectedGpu = $nvidiaGpus[0]
if ($selectedGpu.Name -notlike '*VEN_10DE*' -or $selectedGpu.Name -like '*VEN_1002*') {
    throw "Validação de segurança falhou: GPU selecionada '$($selectedGpu.Name)' não é uma NVIDIA exclusiva."
}
if ($nvidiaGpus.Count -gt 1) {
    Write-Log "Múltiplas GPUs NVIDIA encontradas; selecionando a primeira: $($selectedGpu.Name)" 'WARN'
}

Write-Log "GPU selecionada para GPU-P: $($selectedGpu.Name)" 'OK'

$existingGpuAdapters = @(Get-VMGpuPartitionAdapter -VMName $VMName -ErrorAction SilentlyContinue)
$needsGpuAttach = $true

if ($existingGpuAdapters.Count -gt 0) {
    $matchesSelected = $existingGpuAdapters.Count -eq 1 -and ($existingGpuAdapters[0].InstancePath -eq $selectedGpu.Name)
    if ($matchesSelected) {
        Write-Log 'Adaptador GPU-P NVIDIA já está anexado corretamente na VM (idempotente).' 'OK'
        $needsGpuAttach = $false
    }
    else {
        Write-Log 'Removendo adaptador(es) GPU-P anteriores para garantir vínculo exclusivo com a NVIDIA...' 'WARN'
        Remove-VMGpuPartitionAdapter -VMName $VMName
    }
}

if ($needsGpuAttach) {
    Add-VMGpuPartitionAdapter -VMName $VMName -InstancePath $selectedGpu.Name
    Write-Log 'Adaptador GPU-P anexado via -InstancePath.' 'OK'
}

# Ajusta limites da partição usando valores reportados pelo próprio host/driver (compatível com RTX 40/50)
try {
    $setParams = @{ VMName = $VMName }
    if ($selectedGpu.MinPartitionVRAM -gt 0 -and $selectedGpu.MaxPartitionVRAM -gt 0) {
        $setParams.MinPartitionVRAM     = $selectedGpu.MinPartitionVRAM
        $setParams.MaxPartitionVRAM     = $selectedGpu.MaxPartitionVRAM
        $setParams.OptimalPartitionVRAM = $selectedGpu.OptimalPartitionVRAM
    }
    if ($selectedGpu.MinPartitionEncode -gt 0 -and $selectedGpu.MaxPartitionEncode -gt 0) {
        $setParams.MinPartitionEncode     = $selectedGpu.MinPartitionEncode
        $setParams.MaxPartitionEncode     = $selectedGpu.MaxPartitionEncode
        $setParams.OptimalPartitionEncode = $selectedGpu.OptimalPartitionEncode
    }
    if ($selectedGpu.MinPartitionDecode -gt 0 -and $selectedGpu.MaxPartitionDecode -gt 0) {
        $setParams.MinPartitionDecode     = $selectedGpu.MinPartitionDecode
        $setParams.MaxPartitionDecode     = $selectedGpu.MaxPartitionDecode
        $setParams.OptimalPartitionDecode = $selectedGpu.OptimalPartitionDecode
    }
    if ($selectedGpu.MinPartitionCompute -gt 0 -and $selectedGpu.MaxPartitionCompute -gt 0) {
        $setParams.MinPartitionCompute     = $selectedGpu.MinPartitionCompute
        $setParams.MaxPartitionCompute     = $selectedGpu.MaxPartitionCompute
        $setParams.OptimalPartitionCompute = $selectedGpu.OptimalPartitionCompute
    }

    if ($setParams.Count -gt 1) {
        Set-VMGpuPartitionAdapter @setParams
        Write-Log 'Limites de partição GPU-P alinhados aos parâmetros ideais do driver NVIDIA.' 'OK'
    }
}
catch {
    Write-Log "Mantendo limites padrão da partição GPU-P (driver gerencia dinamicamente): $($_.Exception.Message)" 'WARN'
}

# ==============================================================================
# 5. ISO de Instalação & Ordem de Boot (com auto-detecção para omarchy*.iso)
# ==============================================================================
if (-not $SkipISO) {
    Write-Log "Verificando ISO de instalação: $ISOPath" 'STEP'
    if (-not (Test-Path -LiteralPath $ISOPath)) {
        $isoDir = Split-Path -Path $ISOPath -Parent
        if ($isoDir -and (Test-Path -LiteralPath $isoDir)) {
            $detectedIso = Get-ChildItem -LiteralPath $isoDir -Filter 'omarchy*.iso' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($detectedIso) {
                $ISOPath = $detectedIso.FullName
                Write-Log "ISO Omarchy detectada automaticamente: $ISOPath" 'OK'
            }
        }
    }

    if (Test-Path -LiteralPath $ISOPath) {
        $dvdDrive = Get-VMDvdDrive -VMName $VMName -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $dvdDrive) {
            $dvdDrive = Add-VMDvdDrive -VMName $VMName -Path $ISOPath -Passthru
        }
        else {
            Set-VMDvdDrive -VMDvdDrive $dvdDrive -Path $ISOPath
        }

        # Coloca o DVD primeiro na ordem de boot para a instalação inicial
        $hardDrive = Get-VMHardDiskDrive -VMName $VMName | Select-Object -First 1
        if ($hardDrive) {
            Set-VMFirmware -VMName $VMName -BootOrder @($dvdDrive, $hardDrive)
        }
        else {
            Set-VMFirmware -VMName $VMName -FirstBootDevice $dvdDrive
        }
        Write-Log "ISO anexada e configurada como primeiro dispositivo de boot." 'OK'
    }
    else {
        Write-Log "ISO não encontrada em '$ISOPath'. Coloque a ISO do Omarchy em D:\ISOs\ ou informe -ISOPath." 'WARN'
    }
}

# ==============================================================================
# 6. Resumo Final e Abertura do vmconnect
# ==============================================================================
Write-Log '=== Provisionamento concluído com sucesso! ===' 'OK'
Write-Host ''
Write-Host '  Resumo da VM:' -ForegroundColor White
Write-Host "    Nome:            $VMName"
Write-Host "    Pasta da VM:     $VMPath"
Write-Host "    vCPUs:           $CPUCount"
Write-Host "    RAM Dinâmica:    Startup ${MemoryStartupGB}GB | Min ${MemoryMinGB}GB | Max ${MemoryMaxGB}GB"
Write-Host "    VHDX:            $VHDPath (${VHDSizeGB}GB dinâmico)"
Write-Host "    Switch / NAT:    $SwitchName ($HostIP/$PrefixLength -> $NatSubnet)"
Write-Host "    GPU-P:           $($selectedGpu.Name)"
Write-Host "    MMIO:            Low ${LowMmioGB}GB / High ${HighMmioGB}GB"
Write-Host "    Secure Boot VM:  Off (Host bare-metal preservado)"
Write-Host ''
Write-Host '  Próximos passos (Omarchy / Arch Linux):' -ForegroundColor Yellow
Write-Host "    1. Instale o Omarchy pela ISO (se usou -AttachInstallSwitch, o DHCP já vem pronto)."
Write-Host "    2. No primeiro boot do Omarchy, rode: ./linux/02-setup-omarchy.sh"
Write-Host "       (Ele configura IP estático $(Get-ConfigValue $cfg 'VM_IP' '192.168.50.2'), dxgkrnl-dkms, vkms, Sunshine e UFW sem alterar o visual do Omarchy.)"
Write-Host "    3. Após reiniciar, sincronize os drivers NVIDIA pelo Windows: .\sync\sync-gpu-drivers.ps1"
Write-Host ''

if ($StartVM) {
    Write-Log "Iniciando VM '$VMName'..." 'INFO'
    Start-VM -Name $VMName
}

if (-not $NoVmConnect) {
    $vmconnect = Join-Path $env:SystemRoot 'System32\vmconnect.exe'
    if (Test-Path -LiteralPath $vmconnect) {
        Write-Log "Abrindo vmconnect para '$VMName'..." 'INFO'
        Start-Process -FilePath $vmconnect -ArgumentList @('localhost', $VMName)
    }
    else {
        Write-Log "vmconnect.exe não encontrado em $vmconnect." 'WARN'
    }
}
