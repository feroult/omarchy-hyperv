#!/usr/bin/env bash
# ==============================================================================
# Winix :: 02-setup-vm.sh (Ubuntu 24.04 LTS - Pós-instalação dentro da VM)
#
# Configura o sistema convidado Linux para Hyper-V GPU-P (NVIDIA exclusiva):
#   1. Kernel `linux-azure` (+ modules-extra) para suporte nativo a `dxgkrnl` e `vkms`
#   2. Módulo `vkms` no boot (saída DRM virtual `Virtual-1`) + permissões `/dev/dxg`
#   3. Diretórios `/usr/lib/wsl/{lib,drivers}` e `ldconfig` prontos para sync GPU-P
#   4. Hyprland + Kitty + Waybar + Wofi + xdg-desktop-portal-hyprland (3440x1440@144Hz)
#   5. Sunshine (última release Ubuntu 24.04) + `cap_sys_admin+p` + tuning texto 4:4:4
#   6. Auto-login no tty1 via systemd + auto-start automático de Hyprland & Sunshine
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuração padrão (sobrescrita por `.env` na raiz do repositório, se existir)
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DISPLAY_OUTPUT="${DISPLAY_OUTPUT:-Virtual-1}"
DISPLAY_RESOLUTION="${DISPLAY_RESOLUTION:-3440x1440}"
DISPLAY_REFRESH_RATE="${DISPLAY_REFRESH_RATE:-144}"
DISPLAY_SCALE="${DISPLAY_SCALE:-1}"
NAT_SUBNET="${NAT_SUBNET:-192.168.50.0/24}"
SUNSHINE_APP_NAME="${SUNSHINE_APP_NAME:-Hyprland Desktop}"
SUNSHINE_DEB_URL="${SUNSHINE_DEB_URL:-}" # Opcional: fixe uma URL de .deb se desejar

# Carrega `.env` (ignora caminhos Windows com backslashes sem quebrar parsing)
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
            DISPLAY_OUTPUT|DISPLAY_RESOLUTION|DISPLAY_REFRESH_RATE|DISPLAY_SCALE|NAT_SUBNET|SUNSHINE_APP_NAME)
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
# Identificação do usuário desktop alvo e privilégios sudo
# ------------------------------------------------------------------------------
if [[ "${EUID}" -eq 0 ]]; then
    TARGET_USER="${SUDO_USER:-}"
    if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
        log_err "Execute este script como usuário normal (com acesso sudo), não diretamente como root."
        exit 1
    fi
else
    TARGET_USER="${USER}"
    sudo -v
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_UID="$(id -u "$TARGET_USER")"

log_step "=== Winix :: Setup da VM Ubuntu 24.04 (Usuário: ${TARGET_USER} | Display: ${DISPLAY_OUTPUT} ${DISPLAY_RESOLUTION}@${DISPLAY_REFRESH_RATE}Hz) ==="

# Valida distro
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
        log_warn "Sistema detectado: ${PRETTY_NAME:-desconhecido}. Este script foi validado para Ubuntu 24.04 LTS."
    else
        log_ok "SO validado: ${PRETTY_NAME}"
    fi
fi

# ------------------------------------------------------------------------------
# 1. Atualização APT + Kernel linux-azure (suporte nativo a dxgkrnl + vkms)
# ------------------------------------------------------------------------------
log_step "1/7 :: Instalando kernel linux-azure (dxgkrnl nativo) e módulos extras (vkms)..."

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y software-properties-common ca-certificates curl jq git gnupg lsb-release libcap2-bin openssh-server
sudo add-apt-repository -y universe
sudo apt-get update -y

# linux-azure inclui drivers/hv/dxgkrnl (/dev/dxg)
# linux-modules-extra-azure inclui vkms.ko para o monitor virtual DRM (Virtual-1)
sudo apt-get install -y \
    linux-azure \
    linux-modules-extra-azure \
    linux-tools-azure \
    linux-cloud-tools-azure

# Garante que o GRUB dê preferência ao kernel linux-azure no próximo boot
sudo update-grub
AZURE_ENTRY="$(awk -F"'" '/menuentry / && /azure/ && !/recovery/ {print $2; exit}' /boot/grub/grub.cfg || true)"
SUBMENU_TITLE="$(awk -F"'" '/submenu / {print $2; exit}' /boot/grub/grub.cfg || true)"

if [[ -n "$AZURE_ENTRY" ]]; then
    if [[ -n "$SUBMENU_TITLE" ]] && grep -qF "$AZURE_ENTRY" /boot/grub/grub.cfg; then
        # Verifica se a entrada está dentro do submenu Advanced options
        if awk -v entry="$AZURE_ENTRY" '
            /submenu / { in_sub=1 }
            in_sub && index($0, entry) { found=1; exit }
            END { exit !found }
        ' /boot/grub/grub.cfg; then
            GRUB_TARGET="${SUBMENU_TITLE}>${AZURE_ENTRY}"
        else
            GRUB_TARGET="${AZURE_ENTRY}"
        fi
    else
        GRUB_TARGET="${AZURE_ENTRY}"
    fi

    sudo mkdir -p /etc/default/grub.d
    printf 'GRUB_DEFAULT="%s"\n' "$GRUB_TARGET" | sudo tee /etc/default/grub.d/99-winix-azure-kernel.cfg >/dev/null
    sudo update-grub
    log_ok "GRUB configurado para inicializar automaticamente o kernel Azure: ${GRUB_TARGET}"
else
    log_warn "Não foi possível detectar entrada GRUB específica para linux-azure; verifique 'uname -r' após o reboot."
fi

# ------------------------------------------------------------------------------
# 2. Módulo vkms no boot + udev /dev/dxg + estrutura /usr/lib/wsl
# ------------------------------------------------------------------------------
log_step "2/7 :: Configurando módulo vkms, permissões /dev/dxg e diretórios /usr/lib/wsl..."

echo "vkms" | sudo tee /etc/modules-load.d/vkms.conf >/dev/null
log_ok "/etc/modules-load.d/vkms.conf criado."

# Regra udev para /dev/dxg (GPU paravirtualizada)
cat <<'EOF' | sudo tee /etc/udev/rules.d/99-dxg.rules >/dev/null
SUBSYSTEM=="dxg", KERNEL=="dxg", MODE="0666"
EOF
sudo udevadm control --reload-rules || true

# Adiciona usuário aos grupos gráficos/input
for grp in video render input seat; do
    if getent group "$grp" >/dev/null 2>&1; then
        sudo usermod -aG "$grp" "$TARGET_USER"
    fi
done

# Cria diretórios que receberão os binários CUDA/D3D12 via sync-gpu-drivers
sudo mkdir -p /usr/lib/wsl/lib /usr/lib/wsl/drivers
sudo chown -R "${TARGET_USER}:${TARGET_USER}" /usr/lib/wsl

# Configura ldconfig para resolver /usr/lib/wsl/lib
echo "/usr/lib/wsl/lib" | sudo tee /etc/ld.so.conf.d/ld.wsl.conf >/dev/null
sudo ldconfig

# Adiciona /usr/lib/wsl/lib no PATH global (para `nvidia-smi`) e LD_LIBRARY_PATH
cat <<'EOF' | sudo tee /etc/profile.d/winix-wsl-gpu.sh >/dev/null
export PATH="/usr/lib/wsl/lib:${PATH}"
export LD_LIBRARY_PATH="/usr/lib/wsl/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export GALLIUM_DRIVER="d3d12"
export MESA_D3D12_DEFAULT_ADAPTER_NAME="NVIDIA"
EOF
sudo chmod 644 /etc/profile.d/winix-wsl-gpu.sh
log_ok "Estrutura /usr/lib/wsl e ldconfig configurados."

# ------------------------------------------------------------------------------
# 3. Stack Gráfica Mesa D3D12 + Hyprland + Kitty + Waybar + Wofi + Portais
# ------------------------------------------------------------------------------
log_step "3/7 :: Instalando Mesa D3D12, Hyprland, Kitty, Waybar, Wofi e xdg-desktop-portal-hyprland..."

sudo apt-get install -y \
    libgl1-mesa-dri \
    mesa-vulkan-drivers \
    mesa-utils \
    libegl1 \
    libgles2 \
    libgbm1 \
    libvulkan1 \
    vulkan-tools \
    drm-info \
    hyprland \
    kitty \
    waybar \
    wofi \
    xdg-desktop-portal \
    xdg-desktop-portal-hyprland \
    xdg-desktop-portal-gtk \
    dbus-user-session \
    pipewire \
    pipewire-pulse \
    wireplumber \
    wl-clipboard \
    dunst \
    grim \
    slurp \
    fonts-jetbrains-mono \
    fonts-font-awesome \
    seatd

sudo systemctl enable --now seatd || true
sudo systemctl enable --now ssh

log_ok "Pacotes Wayland/Hyprland instalados."

# ------------------------------------------------------------------------------
# 4. Configuração do Hyprland, Kitty, Waybar e Launcher vkms
# ------------------------------------------------------------------------------
log_step "4/7 :: Gerando configurações do Hyprland (${DISPLAY_OUTPUT} ${DISPLAY_RESOLUTION}@${DISPLAY_REFRESH_RATE}Hz), Kitty e Waybar..."

sudo -u "$TARGET_USER" mkdir -p \
    "${TARGET_HOME}/.config/hypr" \
    "${TARGET_HOME}/.config/kitty" \
    "${TARGET_HOME}/.config/waybar" \
    "${TARGET_HOME}/.config/wofi" \
    "${TARGET_HOME}/.config/sunshine" \
    "${TARGET_HOME}/.config/systemd/user"

# Script wrapper que detecta o /dev/dri/cardX do vkms e inicia o Hyprland nele
cat <<EOF | sudo tee /usr/local/bin/start-hyprland-vkms.sh >/dev/null
#!/usr/bin/env bash
set -euo pipefail

# Variáveis críticas para Hyper-V GPU-P (NVIDIA via D3D12) + vkms
export WLR_NO_HARDWARE_CURSORS=1
export WLR_RENDERER=gles2
export LD_LIBRARY_PATH="/usr/lib/wsl/lib\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
export PATH="/usr/lib/wsl/lib:\${PATH}"
export GALLIUM_DRIVER=d3d12
export MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA
export XDG_CURRENT_DESKTOP=Hyprland
export XDG_SESSION_TYPE=wayland
export XDG_SESSION_DESKTOP=Hyprland

# Localiza dinamicamente o nó DRM correspondente ao driver vkms (evita conflito com hyperv_drm)
VKMS_CARD=""
for card in /dev/dri/card*; do
    [[ -e "\$card" ]] || continue
    dev_name="\$(basename "\$card")"
    driver_path="/sys/class/drm/\${dev_name}/device/driver"
    if [[ -L "\$driver_path" ]] && [[ "\$(basename "\$(readlink -f "\$driver_path")")" == "vkms" ]]; then
        VKMS_CARD="\$card"
        break
    fi
    if [[ -f "/sys/class/drm/\${dev_name}/device/modalias" ]] && grep -qi "vkms" "/sys/class/drm/\${dev_name}/device/modalias"; then
        VKMS_CARD="\$card"
        break
    fi
done

if [[ -n "\$VKMS_CARD" ]]; then
    export WLR_DRM_DEVICES="\$VKMS_CARD"
    export AQ_DRM_DEVICES="\$VKMS_CARD"
fi

exec Hyprland
EOF
sudo chmod +x /usr/local/bin/start-hyprland-vkms.sh

# Gera ~/.config/hypr/hyprland.conf
cat <<EOF | sudo -u "$TARGET_USER" tee "${TARGET_HOME}/.config/hypr/hyprland.conf" >/dev/null
# ==============================================================================
# Winix :: Hyprland Configuration (Hyper-V GPU-P NVIDIA + vkms + Sunshine)
# Monitor alvo: ${DISPLAY_OUTPUT} ${DISPLAY_RESOLUTION}@${DISPLAY_REFRESH_RATE}Hz
# ==============================================================================

# --- Monitor Virtual (vkms) ---
monitor=${DISPLAY_OUTPUT},${DISPLAY_RESOLUTION}@${DISPLAY_REFRESH_RATE},0x0,${DISPLAY_SCALE}
# Desabilita eventual framebuffer residual do Hyper-V se aparecer
monitor=Unknown-1,disable

# --- Variáveis de Ambiente (GPU-P NVIDIA / D3D12 / Wayland) ---
env = WLR_NO_HARDWARE_CURSORS,1
env = WLR_RENDERER,gles2
env = LD_LIBRARY_PATH,/usr/lib/wsl/lib
env = GALLIUM_DRIVER,d3d12
env = MESA_D3D12_DEFAULT_ADAPTER_NAME,NVIDIA
env = XDG_CURRENT_DESKTOP,Hyprland
env = XDG_SESSION_TYPE,wayland
env = XDG_SESSION_DESKTOP,Hyprland
env = QT_QPA_PLATFORM,wayland
env = GDK_BACKEND,wayland,x11
env = MOZ_ENABLE_WAYLAND,1

# --- Autostart ---
exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP LD_LIBRARY_PATH GALLIUM_DRIVER MESA_D3D12_DEFAULT_ADAPTER_NAME
exec-once = systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP LD_LIBRARY_PATH
exec-once = waybar
exec-once = dunst
exec-once = systemctl --user restart sunshine.service

# --- Input (ajuste layout se usar ABNT2: kb_layout = br) ---
input {
    kb_layout = us
    follow_mouse = 1
    sensitivity = 0
}

# --- Aparência & Layout Ultrawide 3440x1440 ---
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
    col.inactive_border = rgba(595959aa)
    layout = dwindle
}

decoration {
    rounding = 8
    blur {
        enabled = false # Mantém texto ultra-nítido e minimiza overhead no Sunshine
    }
    drop_shadow = false
}

animations {
    enabled = true
    bezier = snappy, 0.05, 0.9, 0.1, 1.05
    animation = windows, 1, 4, snappy
    animation = workspaces, 1, 3, default
    animation = fade, 1, 3, default
}

dwindle {
    pseudotile = true
    preserve_split = true
}

misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
    vfr = true
}

# ==============================================================================
# Atalhos Ergonômicos (Sem conflito com Moonlight: Ctrl+Alt+Shift+Z/Q/S/M)
# Dica: No Moonlight em Borderless Fullscreen com captura de teclado ativa,
# a tecla SUPER (Win) é enviada ao Linux. Use Ctrl+Alt+Shift+Z para liberar
# o foco e voltar imediatamente ao Windows.
# ==============================================================================
\$mainMod = SUPER

# Aplicativos principais
bind = \$mainMod, Return, exec, kitty
bind = \$mainMod, D, exec, wofi --show drun
bind = \$mainMod, Space, exec, wofi --show drun

# Gerenciamento de janelas
bind = \$mainMod, Q, killactive,
bind = \$mainMod, F, fullscreen, 0
bind = \$mainMod, M, fullscreen, 1
bind = \$mainMod, V, togglefloating,
bind = \$mainMod, P, pseudo,
bind = \$mainMod, S, togglesplit,

# Foco estilo Vim + setas
bind = \$mainMod, H, movefocus, l
bind = \$mainMod, L, movefocus, r
bind = \$mainMod, K, movefocus, u
bind = \$mainMod, J, movefocus, d
bind = \$mainMod, left, movefocus, l
bind = \$mainMod, right, movefocus, r
bind = \$mainMod, up, movefocus, u
bind = \$mainMod, down, movefocus, d

# Mover janelas
bind = \$mainMod SHIFT, H, movewindow, l
bind = \$mainMod SHIFT, L, movewindow, r
bind = \$mainMod SHIFT, K, movewindow, u
bind = \$mainMod SHIFT, J, movewindow, d

# Workspaces 1..9
bind = \$mainMod, 1, workspace, 1
bind = \$mainMod, 2, workspace, 2
bind = \$mainMod, 3, workspace, 3
bind = \$mainMod, 4, workspace, 4
bind = \$mainMod, 5, workspace, 5
bind = \$mainMod, 6, workspace, 6
bind = \$mainMod, 7, workspace, 7
bind = \$mainMod, 8, workspace, 8
bind = \$mainMod, 9, workspace, 9

bind = \$mainMod SHIFT, 1, movetoworkspace, 1
bind = \$mainMod SHIFT, 2, movetoworkspace, 2
bind = \$mainMod SHIFT, 3, movetoworkspace, 3
bind = \$mainMod SHIFT, 4, movetoworkspace, 4
bind = \$mainMod SHIFT, 5, movetoworkspace, 5
bind = \$mainMod SHIFT, 6, movetoworkspace, 6
bind = \$mainMod SHIFT, 7, movetoworkspace, 7
bind = \$mainMod SHIFT, 8, movetoworkspace, 8
bind = \$mainMod SHIFT, 9, movetoworkspace, 9

# Mouse (mover/redimensionar janelas)
bindm = \$mainMod, mouse:272, movewindow
bindm = \$mainMod, mouse:273, resizewindow

# Recarregar Waybar / Sair do Hyprland (atalho explícito com SHIFT para evitar acidente)
bind = \$mainMod SHIFT, R, exec, pkill waybar; waybar &
bind = \$mainMod SHIFT, E, exit,
EOF

# Kitty otimizado para leitura em 3440x1440
cat <<'EOF' | sudo -u "$TARGET_USER" tee "${TARGET_HOME}/.config/kitty/kitty.conf" >/dev/null
font_family      JetBrains Mono
font_size        11.5
background_opacity 0.95
window_padding_width 8
enable_audio_bell no
confirm_os_window_close 0
EOF

# Waybar minimalista para 3440x1440
cat <<'EOF' | sudo -u "$TARGET_USER" tee "${TARGET_HOME}/.config/waybar/config" >/dev/null
{
    "layer": "top",
    "position": "top",
    "height": 30,
    "modules-left": ["hyprland/workspaces", "hyprland/window"],
    "modules-center": ["clock"],
    "modules-right": ["cpu", "memory", "network"],
    "clock": {
        "format": "{:%Y-%m-%d  %H:%M}"
    },
    "cpu": {
        "format": "CPU {usage}%",
        "interval": 2
    },
    "memory": {
        "format": "RAM {used:0.1f}G/{total:0.1f}G",
        "interval": 3
    },
    "network": {
        "format-ethernet": "LAN {ipaddr}",
        "format-disconnected": "Offline"
    }
}
EOF

cat <<'EOF' | sudo -u "$TARGET_USER" tee "${TARGET_HOME}/.config/waybar/style.css" >/dev/null
* {
    font-family: "JetBrains Mono", "Font Awesome 6 Free", sans-serif;
    font-size: 13px;
}
window#waybar {
    background: rgba(18, 20, 26, 0.92);
    color: #e6edf3;
    border-bottom: 1px solid rgba(51, 204, 255, 0.35);
}
#workspaces button {
    padding: 0 8px;
    color: #8b949e;
}
#workspaces button.active {
    color: #33ccff;
    border-bottom: 2px solid #33ccff;
}
#clock, #cpu, #memory, #network {
    padding: 0 12px;
}
EOF

log_ok "Configurações do Hyprland, Kitty e Waybar geradas."

# ------------------------------------------------------------------------------
# 5. Instalação do Sunshine + cap_sys_admin+p + Configuração 4:4:4 / Alto Bitrate
# ------------------------------------------------------------------------------
log_step "5/7 :: Instalando Sunshine (última release Ubuntu 24.04) e aplicando cap_sys_admin+p..."

install_sunshine() {
    local deb_url="$SUNSHINE_DEB_URL"
    if [[ -z "$deb_url" ]]; then
        log_info "Consultando GitHub Releases API (LizardByte/Sunshine)..."
        deb_url="$(curl -fsSL "https://api.github.com/repos/LizardByte/Sunshine/releases/latest" \
            | jq -r '.assets[] | select(.name | test("ubuntu-24\\.04-amd64\\.deb$")) | .browser_download_url' \
            | head -n 1 || true)"
    fi

    if [[ -z "$deb_url" || "$deb_url" == "null" ]]; then
        log_warn "Não foi possível obter automaticamente a URL do .deb 24.04 via API. Tentando fallback..."
        deb_url="https://github.com/LizardByte/Sunshine/releases/latest/download/sunshine-ubuntu-24.04-amd64.deb"
    fi

    local tmp_deb="/tmp/sunshine-ubuntu-24.04-amd64.deb"
    log_info "Baixando Sunshine: ${deb_url}"
    curl -fL "$deb_url" -o "$tmp_deb"
    sudo apt-get install -y "$tmp_deb"
    rm -f "$tmp_deb"
}

if ! command -v sunshine >/dev/null 2>&1; then
    install_sunshine
else
    log_ok "Sunshine já está instalado ($(command -v sunshine))."
fi

SUNSHINE_BIN="$(readlink -f "$(command -v sunshine)")"
sudo setcap cap_sys_admin+p "$SUNSHINE_BIN"
log_ok "Capability cap_sys_admin+p aplicada em: ${SUNSHINE_BIN}"
getcap "$SUNSHINE_BIN" || true

# Configuração do Sunshine otimizada para nitidez máxima de texto em 3440x1440@144Hz
# sobre rede local virtual (< 1ms): HEVC/AV1 habilitados, chroma 4:4:4, baixo FEC, QP baixo.
cat <<EOF | sudo -u "$TARGET_USER" tee "${TARGET_HOME}/.config/sunshine/sunshine.conf" >/dev/null
# ==============================================================================
# Winix :: Sunshine Configuration (3440x1440@144Hz / Nitidez de Texto / LAN <1ms)
# ==============================================================================
sunshine_name = Linux-Hyprland-IA
origin_web_ui_allowed = lan
csrf_allowed_origins = https://${VM_IP:-192.168.50.2}:47990
upnp = disabled

# Captura KMS direta sobre o monitor virtual vkms (requer cap_sys_admin+p)
capture = kms

# Encoder: deixe vazio para detecção automática (nvenc -> vaapi -> software).
# Em Hyper-V GPU-P Linux, se NVENC não estiver exposto via /dev/dxg, o Sunshine
# usa automaticamente VAAPI/Software com os 16 vCPUs do Ryzen 9 9950X.
encoder =

# Auto-negociação de HEVC/AV1 (0 = anuncia se o encoder suportar; evita falha no probe de startup)
hevc_mode = 0
av1_mode = 0

# Qualidade e nitidez de texto (chroma 4:4:4 quando requisitado pelo Moonlight)
qp = 18
min_threads = 4
sw_preset = ultrafast
sw_tune = zerolatency
nvenc_preset = 1
nvenc_spatial_aq = enabled
nvenc_twopass = quarter_res

# Otimizações para Virtual Switch dedicado (192.168.50.0/24, < 1ms, sem perda de pacotes)
fec_percentage = 1
lan_encryption_mode = 0

# Resoluções e taxas anunciadas ao Moonlight
resolutions = [
    ${DISPLAY_RESOLUTION},
    2560x1440,
    1920x1080
]
fps = [60, 120, ${DISPLAY_REFRESH_RATE}]
EOF

cat <<EOF | sudo -u "$TARGET_USER" tee "${TARGET_HOME}/.config/sunshine/apps.json" >/dev/null
{
    "env": {
        "PATH": "/usr/lib/wsl/lib:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
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

# Systemd user service do Sunshine
cat <<EOF | sudo -u "$TARGET_USER" tee "${TARGET_HOME}/.config/systemd/user/sunshine.service" >/dev/null
[Unit]
Description=Sunshine Self-Hosted Game/Desktop Stream Host (Winix)
After=graphical-session.target

[Service]
Type=simple
Environment="GALLIUM_DRIVER=llvmpipe"
Environment="LIBGL_ALWAYS_SOFTWARE=1"
ExecStart=${SUNSHINE_BIN}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF

log_ok "Sunshine configurado (conf + apps.json + systemd user service)."

# ------------------------------------------------------------------------------
# 6. Auto-login no tty1 (systemd) + Auto-start Hyprland & Sunshine no boot
# ------------------------------------------------------------------------------
log_step "6/7 :: Configurando auto-login no tty1 e auto-start automático do Hyprland + Sunshine..."

sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
cat <<EOF | sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${TARGET_USER} --noclear %I \$TERM
EOF

sudo systemctl daemon-reload
sudo loginctl enable-linger "$TARGET_USER" || true

# Habilita o serviço user do Sunshine (funciona mesmo sem sessão D-Bus ativa usando symlink)
sudo -u "$TARGET_USER" mkdir -p "${TARGET_HOME}/.config/systemd/user/default.target.wants"
sudo -u "$TARGET_USER" ln -sf \
    "${TARGET_HOME}/.config/systemd/user/sunshine.service" \
    "${TARGET_HOME}/.config/systemd/user/default.target.wants/sunshine.service"

# Hook idempotente no ~/.bash_profile para iniciar o Hyprland automaticamente no tty1
BASH_PROFILE="${TARGET_HOME}/.bash_profile"
if [[ ! -f "$BASH_PROFILE" ]]; then
    sudo -u "$TARGET_USER" touch "$BASH_PROFILE"
fi

if ! grep -qF "WINIX_HYPRLAND_AUTOSTART" "$BASH_PROFILE"; then
    cat <<'EOF' | sudo -u "$TARGET_USER" tee -a "$BASH_PROFILE" >/dev/null

# >>> WINIX_HYPRLAND_AUTOSTART >>>
# Carrega .profile/.bashrc padrão
if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi

# Inicia Hyprland (+ Sunshine via exec-once) automaticamente no tty1
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty 2>/dev/null)" = "/dev/tty1" ]; then
    exec /usr/local/bin/start-hyprland-vkms.sh
fi
# <<< WINIX_HYPRLAND_AUTOSTART <<<
EOF
    log_ok "Auto-start do Hyprland adicionado em ${BASH_PROFILE}."
else
    log_ok "Auto-start do Hyprland já presente em ${BASH_PROFILE} (idempotente)."
fi

# ------------------------------------------------------------------------------
# 7. Firewall (UFW) se ativo
# ------------------------------------------------------------------------------
log_step "7/7 :: Verificando regras de firewall (UFW) para SSH e Sunshine na sub-rede ${NAT_SUBNET}..."

if command -v ufw >/dev/null 2>&1 && sudo ufw status | grep -qi "Status: active"; then
    sudo ufw allow from "$NAT_SUBNET" to any port 22 proto tcp comment 'Winix SSH'
    sudo ufw allow from "$NAT_SUBNET" to any port 47984,47989,47990,48010 proto tcp comment 'Winix Sunshine TCP'
    sudo ufw allow from "$NAT_SUBNET" to any port 47998:48000 proto udp comment 'Winix Sunshine UDP'
    sudo ufw allow from "$NAT_SUBNET" to any port 48002,48010 proto udp comment 'Winix Sunshine UDP'
    log_ok "Regras UFW aplicadas para ${NAT_SUBNET}."
else
    log_info "UFW inativo ou não instalado — nenhuma regra adicional necessária."
fi

# ------------------------------------------------------------------------------
# Resumo Final
# ------------------------------------------------------------------------------
log_step "=== Setup concluído com sucesso! ==="
cat <<EOF

Próximos passos obrigatórios:
  1. Reinicie a VM para subir com o kernel 'linux-azure' (dxgkrnl + vkms):
       sudo reboot
  2. Após o reboot, verifique via SSH:
       uname -r            # deve conter '-azure'
       ls -la /dev/dxg     # dispositivo GPU-P ativo
       lsmod | grep vkms   # monitor virtual ativo
  3. No Windows (ou WSL2), execute o script de sincronização de drivers NVIDIA:
       .\\sync\\sync-gpu-drivers.ps1   (ou ./sync/sync-gpu-drivers.sh)
  4. Acesse a Web UI do Sunshine no navegador do Windows para parear o Moonlight:
       https://192.168.50.2:47990

EOF
