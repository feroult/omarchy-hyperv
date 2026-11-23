#!/usr/bin/env bash
# ==============================================================================
# Winix :: 02-setup-omarchy.sh (Arch Linux / Omarchy - Pós-instalação na VM)
#
# Integra Hyper-V GPU-P (NVIDIA exclusiva) + vkms + Sunshine ao Omarchy com
# IMPACTO MÍNIMO e ISOLAMENTO TOTAL (sem sobrescrever temas, blur, animações,
# Waybar, Walker ou atalhos nativos do Omarchy):
#
#   Arquivos isolados criados pelo Winix (fácil auditoria/remoção):
#     - /etc/modules-load.d/99-winix-gpup.conf        (vkms + dxgkrnl)
#     - /etc/udev/rules.d/99-winix-dxg.rules          (/dev/dxg -> group render 0660)
#     - /etc/ld.so.conf.d/99-winix-wsl.conf           (/usr/lib/wsl/lib)
#     - /etc/profile.d/99-winix-gpup.sh               (env CUDA/D3D12 + auto-detect vkms)
#     - /etc/ssh/sshd_config.d/99-winix-security.conf (hardening seguro de SSH)
#     - /etc/sudoers.d/99-winix-ops                   (NOPASSWD mínimo: ldconfig + ollama)
#     - /etc/systemd/network/10-winix-hyperv.network  (IP estático 192.168.50.2/24)
#     - ~/.config/systemd/user-environment-generators/90-winix-vkms.sh
#     - ~/.config/hypr/winix-gpup.conf                (sourced no final do hyprland.conf)
#     - ~/.config/sunshine/{sunshine.conf,apps.json}
#     - ~/.config/systemd/user/sunshine.service
#
# Uso:
#   ./linux/02-setup-omarchy.sh
#   ./linux/02-setup-omarchy.sh --skip-network
#   ./linux/02-setup-omarchy.sh --disable-ssh-password   # só após copiar sua chave SSH!
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuração padrão (sobrescrita por `.env` na raiz do repositório, se existir)
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VM_NAME="${VM_NAME:-omarchy}"
HOST_IP="${HOST_IP:-192.168.50.1}"
VM_IP="${VM_IP:-192.168.50.2}"
NET_PREFIX_LENGTH="${NET_PREFIX_LENGTH:-24}"
NAT_SUBNET="${NAT_SUBNET:-192.168.50.0/24}"
DNS_SERVERS="${DNS_SERVERS:-1.1.1.1 9.9.9.9}"
DISPLAY_OUTPUT="${DISPLAY_OUTPUT:-Virtual-1}"
DISPLAY_RESOLUTION="${DISPLAY_RESOLUTION:-3440x1440}"
DISPLAY_REFRESH_RATE="${DISPLAY_REFRESH_RATE:-144}"
DISPLAY_SCALE="${DISPLAY_SCALE:-1}"
SUNSHINE_APP_NAME="${SUNSHINE_APP_NAME:-Omarchy}"
OMARCHY_INSTALL_LTS_KERNEL="${OMARCHY_INSTALL_LTS_KERNEL:-true}"

SKIP_NETWORK="false"
DISABLE_SSH_PASSWORD="false"
IFACE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-network)
            SKIP_NETWORK="true"
            shift
            ;;
        --disable-ssh-password)
            DISABLE_SSH_PASSWORD="true"
            shift
            ;;
        --iface)
            IFACE_OVERRIDE="${2:-}"
            shift 2
            ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *)
            echo "Argumento desconhecido: $1" >&2
            exit 1
            ;;
    esac
done

load_env_file() {
    local env_file="$1"
    [[ -f "$env_file" ]] || return 0
    while IFS='=' read -r raw_key raw_val || [[ -n "$raw_key" ]]; do
        local key val
        key="$(echo "$raw_key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$key" || "$key" == \#* ]] && continue
        val="$(echo "${raw_val:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/\r$//')"
        val="${val#\"}" ; val="${val%\"}"
        val="${val#\'}" ; val="${val%\'}"
        case "$key" in
            VM_NAME|HOST_IP|VM_IP|NET_PREFIX_LENGTH|NAT_SUBNET|DNS_SERVERS|DISPLAY_OUTPUT|DISPLAY_RESOLUTION|DISPLAY_REFRESH_RATE|DISPLAY_SCALE|SUNSHINE_APP_NAME|OMARCHY_INSTALL_LTS_KERNEL)
                export "$key=$val"
                ;;
        esac
    done < "$env_file"
}

if [[ -f "${REPO_ROOT}/.env" ]]; then
    load_env_file "${REPO_ROOT}/.env"
elif [[ -f "${REPO_ROOT}/.env.example" ]]; then
    load_env_file "${REPO_ROOT}/.env.example"
fi

# ------------------------------------------------------------------------------
# Logging estruturado
# ------------------------------------------------------------------------------
C_RESET='\033[0m'
C_CYAN='\033[0;36m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_MAGENTA='\033[0;35m'

log_info() { printf "%b[%s] [INFO]%b %s\n"    "$C_CYAN"    "$(date +%H:%M:%S)" "$C_RESET" "$*"; }
log_ok()   { printf "%b[%s] [OK]%b   %s\n"    "$C_GREEN"   "$(date +%H:%M:%S)" "$C_RESET" "$*"; }
log_warn() { printf "%b[%s] [WARN]%b %s\n"    "$C_YELLOW"  "$(date +%H:%M:%S)" "$C_RESET" "$*"; }
log_err()  { printf "%b[%s] [ERROR]%b %s\n"   "$C_RED"     "$(date +%H:%M:%S)" "$C_RESET" "$*" >&2; }
log_step() { printf "\n%b[%s] [STEP]%b %s\n"  "$C_MAGENTA" "$(date +%H:%M:%S)" "$C_RESET" "$*"; }

trap 'log_err "Falha na linha $LINENO (comando: $BASH_COMMAND). Verifique o log acima."' ERR

# ------------------------------------------------------------------------------
# Validação de ambiente (usuário normal + Arch/Omarchy)
# ------------------------------------------------------------------------------
if [[ "${EUID}" -eq 0 ]]; then
    log_err "Execute como seu usuário normal do Omarchy (NÃO como root). O script usa sudo apenas onde necessário e makepkg/yay exige usuário não-root."
    exit 1
fi

if ! command -v pacman >/dev/null 2>&1; then
    log_err "pacman não encontrado. Este script é destinado ao Arch Linux / Omarchy (para Ubuntu, use linux/02-setup-vm.sh)."
    exit 1
fi

TARGET_USER="${USER}"
TARGET_HOME="${HOME}"
sudo -v

log_step "=== Winix :: Integração Isolada Hyper-V GPU-P para Omarchy/Arch ==="
log_info "Usuário: ${TARGET_USER} | IP Interno: ${VM_IP}/${NET_PREFIX_LENGTH} | Display: ${DISPLAY_OUTPUT} (${DISPLAY_RESOLUTION}@${DISPLAY_REFRESH_RATE}Hz)"

# ------------------------------------------------------------------------------
# 1. Pacotes Base, Headers de Kernel, Mesa D3D12, OpenSSH e UFW
# ------------------------------------------------------------------------------
log_step "1/8 :: Instalando dependências base, headers de kernel, Mesa D3D12, SSH e UFW..."

# Respeita o hook de upgrade do Omarchy (não dispara 'pacman -Syu' direto por baixo do 'omarchy update')
if command -v omarchy >/dev/null 2>&1; then
    log_info "Omarchy detectado: respeitando gerenciador de updates nativo ('omarchy update'). Instalando apenas dependências Winix..."
else
    sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syu --noconfirm
fi

BASE_PKGS=(
    base-devel
    dkms
    git
    curl
    jq
    openssh
    ufw
    libcap
    mesa
    mesa-utils
    vulkan-icd-loader
    vulkan-tools
    libdrm
    hyperv
)

# Garante headers para o kernel ativo (evita falha no DKMS)
ACTIVE_KERNEL="$(uname -r)"
if [[ "$ACTIVE_KERNEL" == *"-lts"* ]]; then
    BASE_PKGS+=(linux-lts-headers)
elif [[ "$ACTIVE_KERNEL" == *"-zen"* ]]; then
    BASE_PKGS+=(linux-zen-headers)
else
    BASE_PKGS+=(linux-headers)
fi

# Instala linux-lts + linux-lts-headers como fallback estável para dxgkrnl-dkms
if [[ "$OMARCHY_INSTALL_LTS_KERNEL" == "true" ]]; then
    BASE_PKGS+=(linux-lts linux-lts-headers)
fi

sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -S --needed --noconfirm "${BASE_PKGS[@]}"

# Habilita daemons de integração do Hyper-V (kvp/vss/fcopy)
for svc in hv_kvp_daemon.service hv_fcopy_daemon.service hv_vss_daemon.service; do
    if systemctl list-unit-files "$svc" >/dev/null 2>&1; then
        sudo systemctl enable --now "$svc" || true
    fi
done

log_ok "Pacotes base, headers e daemons Hyper-V instalados."

# ------------------------------------------------------------------------------
# 2. AUR Helper (yay) + Compilação Oficial dxgkrnl via DKMS (Microsoft WSL2-Linux-Kernel)
# ------------------------------------------------------------------------------
log_step "2/8 :: Compilando módulo dxgkrnl via DKMS direto do Microsoft WSL2-Linux-Kernel..."

AUR_HELPER=""
if command -v yay >/dev/null 2>&1; then
    AUR_HELPER="yay"
elif command -v paru >/dev/null 2>&1; then
    AUR_HELPER="paru"
else
    log_info "Instalando yay-bin (AUR helper)..."
    TMP_YAY="$(mktemp -d /tmp/winix-yay.XXXXXX)"
    git clone https://aur.archlinux.org/yay-bin.git "$TMP_YAY"
    (cd "$TMP_YAY" && makepkg -si --noconfirm)
    rm -rf "$TMP_YAY"
    AUR_HELPER="yay"
fi

# Identifica o kernel LTS instalado com headers (ex: 6.18.57-2-lts — compatível 1:1 com linux-msft-wsl-6.18.y)
TARGET_KVER=""
for build_dir in /usr/lib/modules/*-lts/build; do
    if [[ -d "$build_dir" ]]; then
        TARGET_KVER="$(basename "$(dirname "$build_dir")")"
    fi
done
if [[ -z "$TARGET_KVER" ]]; then
    for build_dir in /usr/lib/modules/*/build; do
        if [[ -d "$build_dir" ]]; then
            TARGET_KVER="$(basename "$(dirname "$build_dir")")"
            break
        fi
    done
fi

if [[ -z "$TARGET_KVER" ]]; then
    log_err "Nenhum diretório /usr/lib/modules/*/build encontrado. Verifique se linux-lts-headers foi instalado."
    exit 1
fi

log_info "Kernel alvo para DKMS dxgkrnl: ${TARGET_KVER}"

if dkms status 2>/dev/null | grep -qE "^dxgkrnl/.*${TARGET_KVER}.*installed"; then
    log_ok "Módulo dxgkrnl já compilado e instalado via DKMS para ${TARGET_KVER}."
else
    KSERIES="$(echo "$TARGET_KVER" | awk -F'.' '{print $1 "." $2}')"
    WSL_REPO="https://github.com/microsoft/WSL2-Linux-Kernel.git"
    WSL_BRANCH="linux-msft-wsl-${KSERIES}.y"

    if ! git ls-remote --exit-code --heads "$WSL_REPO" "$WSL_BRANCH" >/dev/null 2>&1; then
        log_warn "Branch '${WSL_BRANCH}' não encontrado no repo Microsoft; usando 'linux-msft-wsl-6.18.y'."
        WSL_BRANCH="linux-msft-wsl-6.18.y"
    fi

    TMP_WSL="$(mktemp -d /tmp/winix-dxgkrnl.XXXXXX)"
    log_info "Baixando apenas drivers/hv/dxgkrnl da branch oficial '${WSL_BRANCH}' (sparse-checkout)..."
    git clone --depth=1 --filter=blob:none --sparse -b "$WSL_BRANCH" "$WSL_REPO" "$TMP_WSL"
    (
        cd "$TMP_WSL"
        git sparse-checkout set --no-cone drivers/hv/dxgkrnl include/uapi/misc/d3dkmthk.h include/linux/hyperv.h
    )

    DXG_REV="$(git -C "$TMP_WSL" rev-parse --short HEAD)"
    DXG_VERSION="${KSERIES}.${DXG_REV}"
    SRC_DIR="/usr/src/dxgkrnl-${DXG_VERSION}"

    # Limpa eventuais versões antigas do mesmo hash para manter idempotência
    sudo dkms remove -m dxgkrnl -v "$DXG_VERSION" --all >/dev/null 2>&1 || true
    sudo rm -rf "$SRC_DIR"
    sudo mkdir -p "${SRC_DIR}/inc/uapi/misc" "${SRC_DIR}/inc/misc" "${SRC_DIR}/inc/linux"

    sudo cp -r "${TMP_WSL}/drivers/hv/dxgkrnl/"* "${SRC_DIR}/"
    sudo cp "${TMP_WSL}/include/uapi/misc/d3dkmthk.h" "${SRC_DIR}/inc/uapi/misc/"
    sudo cp "${TMP_WSL}/include/uapi/misc/d3dkmthk.h" "${SRC_DIR}/inc/misc/"
    sudo cp "${TMP_WSL}/include/linux/hyperv.h" "${SRC_DIR}/inc/linux/hyperv_dxgkrnl.h"
    rm -rf "$TMP_WSL"

    # Ajusta includes e Makefile para compilação out-of-tree via DKMS
    sudo sed -i 's#linux/hyperv\.h#linux/hyperv_dxgkrnl.h#g' "${SRC_DIR}"/*.c "${SRC_DIR}"/*.h
    sudo sed -i 's/\$(CONFIG_DXGKRNL)/m/g' "${SRC_DIR}/Makefile"
    if ! grep -qF 'inc/uapi' "${SRC_DIR}/Makefile"; then
        printf '\nccflags-y += -I$(src)/inc -I$(src)/inc/uapi\n' | sudo tee -a "${SRC_DIR}/Makefile" >/dev/null
    fi

    cat <<EOF | sudo tee "${SRC_DIR}/dkms.conf" >/dev/null
PACKAGE_NAME="dxgkrnl"
PACKAGE_VERSION="${DXG_VERSION}"
BUILT_MODULE_NAME="dxgkrnl"
DEST_MODULE_LOCATION="/kernel/drivers/hv/dxgkrnl/"
AUTOINSTALL="yes"
EOF

    log_info "Registrando e compilando dxgkrnl/${DXG_VERSION} para kernel ${TARGET_KVER}..."
    sudo dkms add -m dxgkrnl -v "$DXG_VERSION"
    sudo dkms build -m dxgkrnl -v "$DXG_VERSION" -k "$TARGET_KVER"
    sudo dkms install -m dxgkrnl -v "$DXG_VERSION" -k "$TARGET_KVER"

    log_ok "dxgkrnl/${DXG_VERSION} compilado e instalado com sucesso para ${TARGET_KVER}!"
fi

# Configura Limine (bootloader do Omarchy) para dar boot automático na entrada //linux-lts
if [[ -f /boot/limine.conf ]]; then
    LTS_INDEX="$(sudo awk '
        /^[[:space:]]*\// {
            idx++
            if ($0 ~ /\/\/linux-lts([[:space:]]|$)/) { print idx; exit }
        }
    ' /boot/limine.conf || true)"
    if [[ -n "$LTS_INDEX" ]]; then
        sudo sed -i "s/^default_entry:.*/default_entry: ${LTS_INDEX}/" /boot/limine.conf
        log_ok "Limine (/boot/limine.conf) atualizado: default_entry = ${LTS_INDEX} (//linux-lts)."
    fi
fi

# Carrega vkms e dxgkrnl automaticamente no boot (arquivo isolado)
cat <<'EOF' | sudo tee /etc/modules-load.d/99-winix-gpup.conf >/dev/null
# Winix :: Hyper-V GPU-P (NVIDIA) + Monitor Virtual DRM (Virtual-1)
dxgkrnl
vkms
EOF

# Tenta carregar módulos já na sessão atual (sem falhar caso precise reboot para o kernel linux-lts)
sudo modprobe dxgkrnl 2>/dev/null || log_warn "dxgkrnl será carregado ao iniciar no kernel ${TARGET_KVER} (selecione Linux LTS no Limine)."
sudo modprobe vkms    2>/dev/null || log_warn "vkms será carregado após o reboot."

log_ok "Módulos dxgkrnl e vkms registrados em /etc/modules-load.d/99-winix-gpup.conf."

# ------------------------------------------------------------------------------
# 3. Permissões Seguras (/dev/dxg), /usr/lib/wsl e Ambiente Global Isolado
# ------------------------------------------------------------------------------
log_step "3/8 :: Configurando /dev/dxg (least-privilege), /usr/lib/wsl e ldconfig..."

# Least-privilege: acesso restrito ao grupo 'render' (0660) em vez de 0666 global
cat <<'EOF' | sudo tee /etc/udev/rules.d/99-winix-dxg.rules >/dev/null
SUBSYSTEM=="dxg", KERNEL=="dxg", GROUP="render", MODE="0660"
EOF
sudo udevadm control --reload-rules || true
sudo udevadm trigger --subsystem-match=dxg || true

for grp in render video input seat; do
    if getent group "$grp" >/dev/null 2>&1; then
        sudo usermod -aG "$grp" "$TARGET_USER"
    fi
done

# Estrutura para receber os binários CUDA/D3D12 sincronizados do host Windows/WSL2
sudo mkdir -p /usr/lib/wsl/lib /usr/lib/wsl/drivers
sudo chown -R "${TARGET_USER}:${TARGET_USER}" /usr/lib/wsl
sudo chmod 755 /usr/lib/wsl /usr/lib/wsl/lib /usr/lib/wsl/drivers

echo "/usr/lib/wsl/lib" | sudo tee /etc/ld.so.conf.d/99-winix-wsl.conf >/dev/null
sudo ldconfig

# Perfil global isolado (CUDA/NVML via /usr/lib/wsl/lib + detecção de DRM vkms)
# OBS: NÃO exportar GALLIUM_DRIVER=d3d12 globalmente — o backend DRM/GBM do Hyprland (Aquamarine)
# precisa do Mesa nativo no vkms para alocar buffers de scanout; CUDA/Ollama usam /dev/dxg direto!
cat <<'EOF' | sudo tee /etc/profile.d/99-winix-gpup.sh >/dev/null
# Winix :: PATH/LD_LIBRARY_PATH para CUDA/NVML (/dev/dxg) e detecção de DRM vkms (Linux 6.18 faux_driver)
export PATH="/usr/lib/wsl/lib:${PATH}"
export LD_LIBRARY_PATH="/usr/lib/wsl/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

if [ -z "${AQ_DRM_DEVICES:-}" ]; then
    for _card in /dev/dri/card*; do
        [ -e "$_card" ] || continue
        _dev="$(basename "$_card")"
        _drv="/sys/class/drm/${_dev}/device/driver"
        if { [ -L "$_drv" ] && echo "$(basename "$(readlink -f "$_drv")")" | grep -qE '^(vkms|faux_driver)$'; } || \
           { [ -f "/sys/class/drm/${_dev}/device/uevent" ] && grep -qi "vkms" "/sys/class/drm/${_dev}/device/uevent"; } || \
           ls "/sys/class/drm/${_dev}-Writeback-"* >/dev/null 2>&1; then
            export AQ_DRM_DEVICES="$_card"
            export WLR_DRM_DEVICES="$_card"
            break
        fi
    done
    unset _card _dev _drv
fi
EOF
sudo chmod 644 /etc/profile.d/99-winix-gpup.sh

# Systemd environment.d + UWSM env-hyprland (carregados ANTES do Aquamarine inicializar DRM/GBM!)
# Sem AQ_DRM_DEVICES travado no card do vkms, o Aquamarine abre card0+card1 como multigpu e falha o GBM (bo null).
VKMS_CARD_DETECTED="/dev/dri/card0"
for card in /dev/dri/card*; do
    [ -e "$card" ] || continue
    dev="$(basename "$card")"
    drv="/sys/class/drm/${dev}/device/driver"
    if { [ -L "$drv" ] && echo "$(basename "$(readlink -f "$drv")")" | grep -qE '^(vkms|faux_driver)$'; } || \
       { [ -f "/sys/class/drm/${dev}/device/uevent" ] && grep -qi "vkms" "/sys/class/drm/${dev}/device/uevent"; } || \
       ls "/sys/class/drm/${dev}-Writeback-"* >/dev/null 2>&1; then
        VKMS_CARD_DETECTED="$card"
        break
    fi
done

mkdir -p "${TARGET_HOME}/.config/environment.d" "${TARGET_HOME}/.config/uwsm"
cat <<EOF > "${TARGET_HOME}/.config/environment.d/90-winix-vkms.conf"
LD_LIBRARY_PATH=/usr/lib/wsl/lib
AQ_DRM_DEVICES=${VKMS_CARD_DETECTED}
WLR_DRM_DEVICES=${VKMS_CARD_DETECTED}
AQ_NO_MODIFIERS=1
WLR_RENDERER_ALLOW_SOFTWARE=1
LIBGL_ALWAYS_SOFTWARE=1
GALLIUM_DRIVER=llvmpipe
EOF

# Garante exportação também via UWSM (usado nativamente pelo Omarchy para subir o Hyprland)
UWSM_ENV="${TARGET_HOME}/.config/uwsm/env-hyprland"
touch "$UWSM_ENV"
if ! grep -qF "WINIX_VKMS_ENV" "$UWSM_ENV"; then
    cat <<EOF >> "$UWSM_ENV"

# >>> WINIX_VKMS_ENV >>>
export LD_LIBRARY_PATH="/usr/lib/wsl/lib\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
export AQ_DRM_DEVICES="${VKMS_CARD_DETECTED}"
export WLR_DRM_DEVICES="${VKMS_CARD_DETECTED}"
export AQ_NO_MODIFIERS=1
export WLR_RENDERER_ALLOW_SOFTWARE=1
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
# <<< WINIX_VKMS_ENV <<<
EOF
fi

log_ok "Permissões /dev/dxg, /usr/lib/wsl e gerador de ambiente vkms configurados."

# ------------------------------------------------------------------------------
# 4. Integração Isolada no Hyprland do Omarchy (PRESERVA 100% do visual/temas!)
# ------------------------------------------------------------------------------
log_step "4/8 :: Criando drop-in isolado ~/.config/hypr/winix-gpup.conf (sem alterar temas/blur/atalhos do Omarchy)..."

mkdir -p "${TARGET_HOME}/.config/hypr"

cat <<EOF > "${TARGET_HOME}/.config/hypr/winix-gpup.conf"
# ==============================================================================
# Winix :: Drop-in Isolado para Hyper-V GPU-P (NVIDIA) + vkms + Sunshine
#
# Este arquivo NÃO altera temas, blur, animações, Waybar ou atalhos do Omarchy.
# Para desativar, basta remover a linha 'source = ~/.config/hypr/winix-gpup.conf'
# do final do ~/.config/hypr/hyprland.conf.
# ==============================================================================

# Monitor virtual 2K Ultrawide (vkms) — desabilita eventual framebuffer hyperv_drm
monitor = Virtual-2, ${DISPLAY_RESOLUTION}@${DISPLAY_REFRESH_RATE}, 0x0, ${DISPLAY_SCALE}
monitor = ${DISPLAY_OUTPUT}, disable
monitor = Unknown-1, disable

# Variáveis de GPU Paravirtualizada NVIDIA para CUDA/NVML (/dev/dxg)
# (Sem GALLIUM_DRIVER=d3d12 no compositor para não quebrar alocação GBM/scanout do Aquamarine no vkms)
env = LD_LIBRARY_PATH,/usr/lib/wsl/lib
env = WLR_NO_HARDWARE_CURSORS,1

# Necessário para cursor visível no vkms + Sunshine KMS capture
cursor {
    no_hardware_cursors = true
}

# Propaga ambiente para a sessão systemd e inicia o Sunshine
exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP LD_LIBRARY_PATH
exec-once = systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP LD_LIBRARY_PATH
exec-once = systemctl --user restart sunshine.service
EOF

HYPR_LUA="${TARGET_HOME}/.config/hypr/hyprland.lua"
HYPR_CONF="${TARGET_HOME}/.config/hypr/hyprland.conf"
SOURCE_LINE="source = ~/.config/hypr/winix-gpup.conf # WINIX_GPUP_OVERRIDE"

if [[ -f "$HYPR_LUA" ]]; then
    # Omarchy 4.5+ usa configuração Lua (~/.config/hypr/monitors.lua)
    # Para 3440x1440@144 no vkms, usa o modeline VESA CVT-RBv2 exato (evita fallback para 1024x768)
    MON_MODE="${DISPLAY_RESOLUTION}@${DISPLAY_REFRESH_RATE}"
    if [[ "$DISPLAY_RESOLUTION" == "3440x1440" && "$DISPLAY_REFRESH_RATE" == "165" ]]; then
        MON_MODE="modeline 905.47 3440 3448 3480 3520 1440 1443 1451 1559 +hsync -vsync"
    elif [[ "$DISPLAY_RESOLUTION" == "3440x1440" && "$DISPLAY_REFRESH_RATE" == "144" ]]; then
        MON_MODE="modeline 782.12 3440 3448 3480 3520 1440 1443 1451 1543 +hsync -vsync"
    elif [[ "$DISPLAY_RESOLUTION" == "3440x1440" && "$DISPLAY_REFRESH_RATE" == "120" ]]; then
        MON_MODE="modeline 644.16 3440 3448 3480 3520 1440 1443 1451 1525 +hsync -vsync"
    fi
    cat <<EOF > "${TARGET_HOME}/.config/hypr/monitors.lua"
-- Winix :: Monitor Virtual 2K Ultrawide (vkms -> Sunshine -> Moonlight)
hl.monitor({
    output = "Virtual-2",
    mode = "${MON_MODE}",
    position = "0x0",
    scale = ${DISPLAY_SCALE}
})
hl.env("GDK_SCALE", "${DISPLAY_SCALE}")
hl.env("WLR_NO_HARDWARE_CURSORS", "1")
EOF
    log_ok "Omarchy Lua detectado: ~/.config/hypr/monitors.lua configurado para Virtual-2 (${MON_MODE}, scale ${DISPLAY_SCALE})."
elif [[ -f "$HYPR_CONF" ]]; then
    if ! grep -qF "WINIX_GPUP_OVERRIDE" "$HYPR_CONF"; then
        printf '\n# Winix GPU-P / Monitor Virtual (drop-in isolado)\n%s\n' "$SOURCE_LINE" >> "$HYPR_CONF"
        log_ok "Drop-in winix-gpup.conf referenciado no final de ${HYPR_CONF} (Omarchy preservado intacto)."
    else
        log_ok "Referência WINIX_GPUP_OVERRIDE já presente em ${HYPR_CONF} (idempotente)."
    fi
else
    log_warn "Nem hyprland.lua nem hyprland.conf encontrados ainda. Rode o instalador do Omarchy e re-execute este script."
fi

# ------------------------------------------------------------------------------
# 5. Sunshine + cap_sys_admin+p + Configuração 3440x1440@144Hz / 4:4:4
# ------------------------------------------------------------------------------
log_step "5/8 :: Instalando Sunshine e configurando captura KMS em alta fidelidade..."

if ! command -v sunshine >/dev/null 2>&1; then
    if pacman -Si sunshine >/dev/null 2>&1; then
        sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -S --needed --noconfirm sunshine
    else
        "$AUR_HELPER" -S --needed --noconfirm sunshine-bin || "$AUR_HELPER" -S --needed --noconfirm sunshine
    fi
else
    log_ok "Sunshine já instalado ($(command -v sunshine))."
fi

SUNSHINE_BIN="$(readlink -f "$(command -v sunshine)")"
sudo setcap cap_sys_admin+p "$SUNSHINE_BIN"
log_ok "cap_sys_admin+p aplicado em ${SUNSHINE_BIN}"
getcap "$SUNSHINE_BIN" || true

mkdir -p "${TARGET_HOME}/.config/sunshine" "${TARGET_HOME}/.config/systemd/user"

cat <<EOF > "${TARGET_HOME}/.config/sunshine/sunshine.conf"
# ==============================================================================
# Winix :: Sunshine Configuration (Omarchy 3440x1440@144Hz / 4:4:4 / LAN <1ms)
# ==============================================================================
sunshine_name = ${VM_NAME}
origin_web_ui_allowed = lan
csrf_allowed_origins = https://${VM_IP}:47990
upnp = disabled

# Captura KMS direta sobre vkms (com GALLIUM_DRIVER=llvmpipe isolado no sunshine.service para suportar EGL_EXT_image_dma_buf_import)
capture = kms

# Auto-detecção de encoder: usa NVENC de hardware da RTX (H.264 / HEVC 4:4:4 / AV1) via /usr/lib/wsl/lib
# após sync-gpu-drivers, com fallback automático para software (libx264 AVX-512) caso ainda não sincronizado.
encoder =

# Auto-negociação de HEVC/AV1 (0 = anuncia se o encoder suportar; evita falha no probe de startup)
hevc_mode = 0
av1_mode = 0
qp = 20
min_threads = 2
minimum_fps_target = 5
sw_preset = ultrafast
sw_tune = zerolatency
nvenc_preset = 1
nvenc_spatial_aq = enabled
nvenc_twopass = quarter_res

# Virtual Switch interno (192.168.50.0/24, < 1ms, sem perda de pacotes)
fec_percentage = 1
lan_encryption_mode = 0

resolutions = [
    ${DISPLAY_RESOLUTION},
    2560x1440,
    1920x1080
]
fps = [60, 120, 144, 165]
EOF

cat <<EOF > "${TARGET_HOME}/.config/sunshine/apps.json"
{
    "env": {
        "PATH": "/usr/lib/wsl/lib:/usr/local/sbin:/usr/local/bin:/usr/bin",
        "LD_LIBRARY_PATH": "/usr/lib/wsl/lib"
    },
    "apps": [
        {
            "name": "${SUNSHINE_APP_NAME}",
            "output": "",
            "detached": [],
            "image-path": "desktop.png"
        }
    ]
}
EOF

cat <<EOF > "${TARGET_HOME}/.config/systemd/user/sunshine.service"
[Unit]
Description=Sunshine Stream Host (Winix / Omarchy)
After=graphical-session.target

[Service]
Type=simple
# Sunshine usa llvmpipe para o contexto EGL interno (suporta EGL_EXT_image_dma_buf_import com vkms),
# enquanto LD_LIBRARY_PATH=/usr/lib/wsl/lib habilita NVENC de hardware (H.264 / HEVC 4:4:4 / AV1) na RTX via /dev/dxg.
Environment="GALLIUM_DRIVER=llvmpipe"
Environment="LIBGL_ALWAYS_SOFTWARE=1"
Environment="LD_LIBRARY_PATH=/usr/lib/wsl/lib"
ExecStart=${SUNSHINE_BIN}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF

sudo loginctl enable-linger "$TARGET_USER" || true
mkdir -p "${TARGET_HOME}/.config/systemd/user/default.target.wants"
ln -sf \
    "${TARGET_HOME}/.config/systemd/user/sunshine.service" \
    "${TARGET_HOME}/.config/systemd/user/default.target.wants/sunshine.service"

# Evita que o serviço de idle nativo do Omarchy 4.5 (QML) ou hypridle desligue o monitor virtual vkms (dpms off)
# O monitor físico já é gerenciado pelo Windows Host bare-metal.
if command -v omarchy-toggle-idle >/dev/null 2>&1; then
    omarchy-toggle-idle stay-awake >/dev/null 2>&1 || true
fi
mkdir -p "${TARGET_HOME}/.local/state/omarchy/indicators" "${TARGET_HOME}/.config/hypr" "${TARGET_HOME}/.config/systemd/user"
touch "${TARGET_HOME}/.local/state/omarchy/indicators/stay-awake"
if [[ -f "${TARGET_HOME}/.config/hypr/hypridle.conf" ]]; then
    sed -i 's/^\([[:space:]]*on-timeout[[:space:]]*=[[:space:]]*.*dpms off.*\)/# [winix] \1/' "${TARGET_HOME}/.config/hypr/hypridle.conf"
fi
ln -sf /dev/null "${TARGET_HOME}/.config/systemd/user/hypridle.service" 2>/dev/null || true

log_ok "Sunshine configurado e habilitado como serviço de usuário."

# ------------------------------------------------------------------------------
# 6. Rede Estática Persistente (192.168.50.2/24 no Switch-Interno-IA)
# ------------------------------------------------------------------------------
if [[ "$SKIP_NETWORK" == "false" ]]; then
    log_step "6/8 :: Configurando rede estática persistente (${VM_IP}/${NET_PREFIX_LENGTH} -> GW ${HOST_IP})..."

    TARGET_IFACE="$IFACE_OVERRIDE"
    if [[ -z "$TARGET_IFACE" ]]; then
        # Detecta primeira interface Ethernet Hyper-V (driver hv_netvsc) ou eth*/en*
        for iface_path in /sys/class/net/*; do
            iface="$(basename "$iface_path")"
            [[ "$iface" == "lo" ]] && continue
            if [[ -L "${iface_path}/device/driver" ]] && [[ "$(basename "$(readlink -f "${iface_path}/device/driver")")" == "hv_netvsc" ]]; then
                TARGET_IFACE="$iface"
                break
            fi
        done
    fi

    if [[ -z "$TARGET_IFACE" ]]; then
        TARGET_IFACE="$(ip -o link show | awk -F': ' '$2 ~ /^(eth|en)/ {print $2; exit}' || true)"
    fi

    if [[ -z "$TARGET_IFACE" ]]; then
        log_warn "Nenhuma interface Ethernet detectada para configurar IP estático; pule com --skip-network ou informe --iface."
    elif systemctl is-active --quiet NetworkManager 2>/dev/null; then
        CON_NAME="winix-internal"
        DNS_COMMA="${DNS_SERVERS// /,}"
        if nmcli -t -f NAME con show | grep -qx "$CON_NAME"; then
            sudo nmcli con mod "$CON_NAME" ifname "$TARGET_IFACE" ipv4.method manual \
                ipv4.addresses "${VM_IP}/${NET_PREFIX_LENGTH}" ipv4.gateway "$HOST_IP" ipv4.dns "$DNS_COMMA" \
                connection.autoconnect yes
        else
            sudo nmcli con add type ethernet con-name "$CON_NAME" ifname "$TARGET_IFACE" \
                ipv4.method manual ipv4.addresses "${VM_IP}/${NET_PREFIX_LENGTH}" \
                ipv4.gateway "$HOST_IP" ipv4.dns "$DNS_COMMA" connection.autoconnect yes
        fi
        log_ok "Perfil NetworkManager '${CON_NAME}' configurado para ${TARGET_IFACE} (${VM_IP}/${NET_PREFIX_LENGTH})."
    else
        # Padrão do Omarchy: systemd-networkd + systemd-resolved
        sudo mkdir -p /etc/systemd/network
        {
            echo "# Winix :: Rede Interna Dedicada Hyper-V (< 1ms)"
            echo "[Match]"
            echo "Name=${TARGET_IFACE}"
            echo ""
            echo "[Network]"
            echo "Address=${VM_IP}/${NET_PREFIX_LENGTH}"
            echo "Gateway=${HOST_IP}"
            for dns in $DNS_SERVERS; do
                echo "DNS=${dns}"
            done
            echo "IPv6AcceptRA=no"
        } | sudo tee /etc/systemd/network/10-winix-hyperv.network >/dev/null

        sudo systemctl enable systemd-networkd systemd-resolved >/dev/null 2>&1 || true
        log_ok "/etc/systemd/network/10-winix-hyperv.network criado para ${TARGET_IFACE} (${VM_IP}/${NET_PREFIX_LENGTH})."
        log_info "A nova configuração de rede será ativada integralmente no próximo reboot (evitando queda da sua sessão SSH atual)."
    fi
else
    log_step "6/8 :: Configuração de rede pulada (--skip-network)."
fi

# ------------------------------------------------------------------------------
# 7. Hardening Seguro (SSH + UFW restrito a 192.168.50.0/24 + Sudoers mínimo)
# ------------------------------------------------------------------------------
log_step "7/8 :: Aplicando hardening seguro (SSH drop-in, UFW restrito à sub-rede interna, sudoers mínimo)..."

# 7.1 SSH Hardening (drop-in isolado)
sudo mkdir -p /etc/ssh/sshd_config.d
{
    echo "# Winix :: Hardening Seguro de SSH"
    echo "PermitRootLogin no"
    echo "PubkeyAuthentication yes"
    echo "MaxAuthTries 4"
    echo "X11Forwarding no"
    echo "AllowAgentForwarding no"
    echo "ClientAliveInterval 300"
    echo "ClientAliveCountMax 2"
    if [[ "$DISABLE_SSH_PASSWORD" == "true" ]]; then
        if [[ -s "${TARGET_HOME}/.ssh/authorized_keys" ]]; then
            echo "PasswordAuthentication no"
            echo "KbdInteractiveAuthentication no"
        else
            log_warn "--disable-ssh-password ignorado: ${TARGET_HOME}/.ssh/authorized_keys está vazio (evitando lockout)."
        fi
    fi
} | sudo tee /etc/ssh/sshd_config.d/99-winix-security.conf >/dev/null

sudo sshd -t
sudo systemctl enable --now sshd
log_ok "OpenSSH habilitado com drop-in /etc/ssh/sshd_config.d/99-winix-security.conf."

# 7.2 Firewall UFW (Default Deny Incoming + libera APENAS 192.168.50.0/24 para SSH & Sunshine)
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from "$NAT_SUBNET" to any port 22 proto tcp comment 'Winix SSH (Internal Switch)'
sudo ufw allow from "$NAT_SUBNET" to any port 47984,47989,47990,48010 proto tcp comment 'Winix Sunshine TCP'
sudo ufw allow from "$NAT_SUBNET" to any port 47998:48000 proto udp comment 'Winix Sunshine UDP'
sudo ufw allow from "$NAT_SUBNET" to any port 48002,48010 proto udp comment 'Winix Sunshine UDP'
sudo ufw --force enable
sudo systemctl enable --now ufw
log_ok "UFW ativo: bloqueio padrão de entrada, liberando SSH e Sunshine somente para ${NAT_SUBNET}."

# 7.3 Sudoers mínimo (least-privilege) para automação sem senha de sync-gpu-drivers e toggle-game-mode
TMP_SUDOERS="$(mktemp /tmp/winix-sudoers.XXXXXX)"
cat <<EOF > "$TMP_SUDOERS"
# Winix :: Permissões mínimas para sync-gpu-drivers e toggle-game-mode (sem NOPASSWD global)
${TARGET_USER} ALL=(root) NOPASSWD: /usr/bin/ldconfig
${TARGET_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl restart ollama
${TARGET_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl stop ollama
${TARGET_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl start ollama
EOF
chmod 440 "$TMP_SUDOERS"
if sudo visudo -cf "$TMP_SUDOERS" >/dev/null 2>&1; then
    sudo install -m 440 -o root -g root "$TMP_SUDOERS" /etc/sudoers.d/99-winix-ops
    log_ok "Sudoers mínimo validado e instalado em /etc/sudoers.d/99-winix-ops."
else
    log_warn "Falha na validação do visudo; pulando /etc/sudoers.d/99-winix-ops."
fi
rm -f "$TMP_SUDOERS"

# ------------------------------------------------------------------------------
# 8. Resumo Final
# ------------------------------------------------------------------------------
log_step "8/8 :: Integração Winix + Omarchy concluída com sucesso!"

cat <<EOF

Checklist pós-reboot:
  1. Desligue a VM para remover o switch temporário de instalação:
       sudo poweroff
  2. No Windows PowerShell (Admin), remova o switch temporário e ligue a VM:
       .\windows\01-create-vm.ps1 -RemoveInstallSwitch -SkipISO -StartVM
  3. IMPORTANTE no menu do Limine ao ligar a VM: selecione o kernel **Linux LTS (${TARGET_KVER})**,
     que já está com o driver GPU-P (dxgkrnl) compilado e pronto!
  4. Valide na VM:
       uname -r && ls -la /dev/dxg && lsmod | grep -E 'dxgkrnl|vkms'
  5. Copie sua chave SSH (se ainda não fez) e sincronize os drivers NVIDIA pelo Windows:
       .\sync\sync-gpu-drivers.ps1
  6. (Opcional — Segurança máxima) Após validar SSH por chave, desative login por senha:
       ./linux/02-setup-omarchy.sh --skip-network --disable-ssh-password
  7. Pareie o Sunshine no navegador do Windows:
       https://${VM_IP}:47990

EOF
