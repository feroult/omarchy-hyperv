#!/usr/bin/env bash
# ==============================================================================
# Winix :: set-ultrawide.sh
# Aplica resolução 2K Ultrawide (3440x1440) no monitor virtual vkms (Omarchy 4.5 Lua)
# com modeline VESA CVT-RBv2 exato + otimizações NVENC de baixo overhead.
#
# Uso:
#   ./linux/set-ultrawide.sh          # padrão: 60Hz (mais frio e silencioso, ~27% CPU)
#   ./linux/set-ultrawide.sh 120      # 120Hz
#   ./linux/set-ultrawide.sh 144      # 144Hz
#   ./linux/set-ultrawide.sh 165      # 165Hz
# ==============================================================================

set -euo pipefail

HZ="${1:-60}"
case "$HZ" in
    60)  MODELINE="modeline 312.79 3440 3448 3480 3520 1440 1443 1451 1481 +hsync -vsync" ;;
    120) MODELINE="modeline 644.16 3440 3448 3480 3520 1440 1443 1451 1525 +hsync -vsync" ;;
    144) MODELINE="modeline 782.12 3440 3448 3480 3520 1440 1443 1451 1543 +hsync -vsync" ;;
    165) MODELINE="modeline 905.47 3440 3448 3480 3520 1440 1443 1451 1559 +hsync -vsync" ;;
    *)
        echo "Taxa nao suportada: '${HZ}'. Use 60, 120, 144 ou 165." >&2
        exit 1
        ;;
esac

UID_NUM="$(id -u)"
SIG="$(ls -t "/run/user/${UID_NUM}/hypr/" | head -n 1)"
export XDG_RUNTIME_DIR="/run/user/${UID_NUM}"
export HYPRLAND_INSTANCE_SIGNATURE="$SIG"

MON_NAME="$(hyprctl monitors -j 2>/dev/null | jq -r '.[0].name // "Virtual-2"' || echo "Virtual-2")"
echo "[INFO] Monitor ativo detectado: ${MON_NAME} -> aplicando 3440x1440@${HZ}Hz"

cat <<EOF > ~/.config/hypr/monitors.lua
-- Winix :: Monitor Virtual 2K Ultrawide 3440x1440@${HZ}Hz (CVT-RBv2)
hl.monitor({
    output = "${MON_NAME}",
    mode = "${MODELINE}",
    position = "0x0",
    scale = 1
})
hl.env("GDK_SCALE", "1")
hl.env("WLR_NO_HARDWARE_CURSORS", "1")
EOF

hyprctl reload
sleep 1

# Garante modo Stay Awake nativo do Omarchy 4.5 (evita dpmsStatus: 0 no monitor virtual vkms)
if command -v omarchy-toggle-idle >/dev/null 2>&1; then
    omarchy-toggle-idle stay-awake >/dev/null 2>&1 || true
fi
mkdir -p ~/.local/state/omarchy/indicators ~/.config/systemd/user
touch ~/.local/state/omarchy/indicators/stay-awake
ln -sf /dev/null ~/.config/systemd/user/hypridle.service 2>/dev/null || true
pkill hypridle 2>/dev/null || true

# Otimiza Sunshine para NVENC de baixo overhead na LAN <1ms e reinicia
if [[ -f ~/.config/sunshine/sunshine.conf ]]; then
    sed -i \
        -e 's/^fps = .*/fps = [60, 120, 144, 165]/' \
        -e 's/^nvenc_twopass.*/nvenc_twopass = disabled/' \
        -e 's/^nvenc_spatial_aq.*/nvenc_spatial_aq = disabled/' \
        ~/.config/sunshine/sunshine.conf
fi

echo "--- HYPRCTL MONITORS ---"
hyprctl monitors | head -n 15

pkill -9 sunshine 2>/dev/null || true
sleep 1
systemctl --user start sunshine
echo "[OK] Sunshine reiniciado (3440x1440@${HZ}Hz + NVENC low-overhead pronto)!"
