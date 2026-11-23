#!/usr/bin/env bash
# ==============================================================================
# Winix :: sync-gpu-drivers.sh (Executar a partir do WSL2)
#
# Sincroniza os drivers NVIDIA do host Windows + binários WSL2 (`/usr/lib/wsl/lib`)
# para a VM Linux Hyper-V GPU-P (`192.168.50.2`) via SCP com chave SSH sem senha:
#   1. Localiza dinamicamente em `/mnt/c/Windows/System32/DriverStore/FileRepository`
#      a pasta `nv*` mais recente contendo `nvlddmkm.sys` (sem hardcode `nv_dispi`).
#   2. Coleta `/usr/lib/wsl/lib` (do WSL2 ativo) e/ou `lxss/lib` do Windows.
#   3. Transfere para `/usr/lib/wsl/lib` e `/usr/lib/wsl/drivers` na VM.
#   4. Ajusta symlinks, roda `ldconfig` e valida executando `nvidia-smi` na VM.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuração padrão (sobrescrita por `.env` se existir)
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VM_IP="${VM_IP:-192.168.50.2}"
VM_USER="${VM_USER:-linuxia}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY_PATH_WSL="${SSH_KEY_PATH_WSL:-$HOME/.ssh/id_ed25519}"
DRIVERSTORE_DIR="${DRIVERSTORE_DIR:-/mnt/c/Windows/System32/DriverStore/FileRepository}"
WSL_PROGRAM_LIB_DIR="${WSL_PROGRAM_LIB_DIR:-/mnt/c/Program Files/WSL/lib}"
LXSS_LIB_DIR="${LXSS_LIB_DIR:-/mnt/c/Windows/System32/lxss/lib}"
WSL_LIB_DIR="${WSL_LIB_DIR:-/usr/lib/wsl/lib}"
CLEAN_OLD_DRIVERS="${CLEAN_OLD_DRIVERS:-true}"

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
            VM_IP|VM_USER|SSH_PORT|SSH_KEY_PATH_WSL)
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

# Expande `~` no caminho da chave SSH
SSH_KEY_PATH_WSL="${SSH_KEY_PATH_WSL/#\~/$HOME}"

# ------------------------------------------------------------------------------
# Logging
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

# Argumentos SSH/SCP
SSH_OPTS=(
    -o BatchMode=yes
    -o ConnectTimeout=8
    -o StrictHostKeyChecking=accept-new
    -p "${SSH_PORT}"
)
SCP_OPTS=(
    -o BatchMode=yes
    -o ConnectTimeout=8
    -o StrictHostKeyChecking=accept-new
    -P "${SSH_PORT}"
)

if [[ -f "$SSH_KEY_PATH_WSL" ]]; then
    SSH_OPTS+=(-i "$SSH_KEY_PATH_WSL")
    SCP_OPTS+=(-i "$SSH_KEY_PATH_WSL")
fi

REMOTE="${VM_USER}@${VM_IP}"

log_step "=== Winix :: Sync Drivers NVIDIA GPU-P (WSL2 -> ${REMOTE}) ==="

# ------------------------------------------------------------------------------
# 1. Localiza dinamicamente a pasta mais recente nv* contendo nvlddmkm.sys
# ------------------------------------------------------------------------------
log_step "1/5 :: Buscando pasta nv* mais recente contendo nvlddmkm.sys em ${DRIVERSTORE_DIR}..."

if [[ ! -d "$DRIVERSTORE_DIR" ]]; then
    log_err "DriverStore não encontrado em '${DRIVERSTORE_DIR}'. Execute este script a partir do WSL2 com /mnt/c montado."
    exit 1
fi

LATEST_DRIVER_DIR=""
LATEST_MTIME=0
CANDIDATE_COUNT=0

shopt -s nullglob
for dir in "${DRIVERSTORE_DIR}"/nv*; do
    [[ -d "$dir" ]] || continue
    sys_file="${dir}/nvlddmkm.sys"
    [[ -f "$sys_file" ]] || continue

    CANDIDATE_COUNT=$((CANDIDATE_COUNT + 1))
    mtime="$(stat -c %Y "$sys_file")"
    human_date="$(date -d "@${mtime}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$mtime")"
    log_info "  - $(basename "$dir") (nvlddmkm.sys: ${human_date})"

    if (( mtime > LATEST_MTIME )); then
        LATEST_MTIME="$mtime"
        LATEST_DRIVER_DIR="$dir"
    fi
done
shopt -u nullglob

if [[ -z "$LATEST_DRIVER_DIR" ]]; then
    log_err "Nenhuma pasta 'nv*' contendo 'nvlddmkm.sys' encontrada em ${DRIVERSTORE_DIR}."
    exit 1
fi

LATEST_DRIVER_NAME="$(basename "$LATEST_DRIVER_DIR")"
log_ok "Driver mais recente selecionado (${CANDIDATE_COUNT} candidato(s)): ${LATEST_DRIVER_NAME}"

# ------------------------------------------------------------------------------
# 2. Testa conectividade SSH sem senha
# ------------------------------------------------------------------------------
log_step "2/5 :: Validando conectividade SSH sem senha com ${REMOTE}..."

if ! ssh "${SSH_OPTS[@]}" "$REMOTE" "echo WINIX_SSH_OK" | grep -q "WINIX_SSH_OK"; then
    log_err "Não foi possível autenticar via SSH sem senha em ${REMOTE}."
    cat >&2 <<EOF

Configure sua chave SSH no WSL2:
  ssh-keygen -t ed25519 -f "${SSH_KEY_PATH_WSL}" -N ""
  ssh-copy-id -i "${SSH_KEY_PATH_WSL}.pub" -p "${SSH_PORT}" "${REMOTE}"

EOF
    exit 1
fi
log_ok "Conexão SSH validada."

# ------------------------------------------------------------------------------
# 3. Staging de /usr/lib/wsl/lib + lxss/lib e limpeza na VM
# ------------------------------------------------------------------------------
log_step "3/5 :: Preparando diretórios na VM e coletando bibliotecas WSL2/CUDA..."

if [[ "$CLEAN_OLD_DRIVERS" == "true" ]]; then
    ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p /usr/lib/wsl/lib /usr/lib/wsl/drivers && rm -rf /usr/lib/wsl/drivers/nv* /usr/lib/wsl/lib/*"
else
    ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p /usr/lib/wsl/lib /usr/lib/wsl/drivers"
fi

STAGING_DIR="$(mktemp -d /tmp/winix-wsl-lib.XXXXXX)"
cleanup() { rm -rf "$STAGING_DIR"; }
trap cleanup EXIT

COPIED=0

# 1. Prioriza /usr/lib/wsl/lib do próprio WSL2 (que já agrega Program Files\WSL\lib + lxss\lib)
if [[ -d "$WSL_LIB_DIR" ]]; then
    log_info "Coletando binários de ${WSL_LIB_DIR} (WSL2 ativo)..."
    while IFS= read -r -d '' f; do
        cp -fL "$f" "${STAGING_DIR}/$(basename "$f")"
        COPIED=$((COPIED + 1))
    done < <(find "$WSL_LIB_DIR" -maxdepth 1 \( -type f -o -type l \) -print0)
fi

# 2. Garante D3D12/DXCore de C:\Program Files\WSL\lib caso faltem
if [[ -d "$WSL_PROGRAM_LIB_DIR" ]]; then
    log_info "Verificando D3D12/DXCore em ${WSL_PROGRAM_LIB_DIR}..."
    while IFS= read -r -d '' f; do
        base="$(basename "$f")"
        if [[ ! -f "${STAGING_DIR}/${base}" ]]; then
            cp -fL "$f" "${STAGING_DIR}/${base}"
            COPIED=$((COPIED + 1))
        fi
    done < <(find "$WSL_PROGRAM_LIB_DIR" -maxdepth 1 -type f -print0)
fi

# 3. Complementa com C:\Windows\System32\lxss\lib caso falte algum loader NVIDIA
if [[ -d "$LXSS_LIB_DIR" ]]; then
    log_info "Complementando loaders de ${LXSS_LIB_DIR}..."
    while IFS= read -r -d '' f; do
        base="$(basename "$f")"
        if [[ ! -f "${STAGING_DIR}/${base}" ]]; then
            cp -fL "$f" "${STAGING_DIR}/${base}"
            COPIED=$((COPIED + 1))
        fi
    done < <(find "$LXSS_LIB_DIR" -maxdepth 1 -type f -print0)
fi

if (( COPIED == 0 )); then
    log_err "Nenhuma biblioteca CUDA/D3D12/DXCore encontrada em ${WSL_LIB_DIR}, ${WSL_PROGRAM_LIB_DIR} ou ${LXSS_LIB_DIR}."
    exit 1
fi

log_ok "${COPIED} arquivos coletados para envio."

# ------------------------------------------------------------------------------
# 4. Transferência via SCP para /usr/lib/wsl/lib e /usr/lib/wsl/drivers
# ------------------------------------------------------------------------------
log_step "4/5 :: Enviando /usr/lib/wsl/lib e ${LATEST_DRIVER_NAME} via SCP..."

scp "${SCP_OPTS[@]}" "${STAGING_DIR}/"* "${REMOTE}:/usr/lib/wsl/lib/"
log_ok "Bibliotecas copiadas para /usr/lib/wsl/lib."

scp "${SCP_OPTS[@]}" -r "${LATEST_DRIVER_DIR}" "${REMOTE}:/usr/lib/wsl/drivers/"
log_ok "Pasta ${LATEST_DRIVER_NAME} copiada para /usr/lib/wsl/drivers/."

# ------------------------------------------------------------------------------
# 5. Symlinks, ldconfig e validação com nvidia-smi na VM
# ------------------------------------------------------------------------------
log_step "5/5 :: Ajustando symlinks, executando ldconfig e validando com nvidia-smi na VM..."

ssh "${SSH_OPTS[@]}" "$REMOTE" 'bash -s' <<'REMOTE_EOF'
set -euo pipefail
cd /usr/lib/wsl/lib

chmod 755 /usr/lib/wsl/lib/*.so* 2>/dev/null || true
[ -f nvidia-smi ] && chmod 755 nvidia-smi || true
[ -f nvidia-ngx-updater ] && chmod 755 nvidia-ngx-updater || true

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

if sudo -n ldconfig 2>/dev/null; then
    echo "[VM] ldconfig atualizado com sucesso."
elif sudo -n true 2>/dev/null; then
    echo "/usr/lib/wsl/lib" | sudo tee /etc/ld.so.conf.d/99-winix-wsl.conf >/dev/null
    sudo ldconfig
    echo "[VM] ld.so.conf.d e ldconfig atualizados."
else
    echo "[WARN] sudo sem senha não configurado para ldconfig; bibliotecas ainda serão carregadas via LD_LIBRARY_PATH."
fi
REMOTE_EOF

log_info "Executando nvidia-smi na VM..."
echo ""
if ssh "${SSH_OPTS[@]}" "$REMOTE" "LD_LIBRARY_PATH=/usr/lib/wsl/lib /usr/lib/wsl/lib/nvidia-smi"; then
    echo ""
    log_ok "=== Sincronização concluída e validada! Driver ativo: ${LATEST_DRIVER_NAME} ==="
else
    echo ""
    log_err "Falha ao executar nvidia-smi na VM. Confirme se a VM está no kernel linux-azure e se /dev/dxg existe."
    exit 1
fi
