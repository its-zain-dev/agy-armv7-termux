#!/usr/bin/env bash
# Shared constants, logging, locking, config, and parsing helpers for agy-armv7-termux.

AGY_PORT_VERSION="1.0.0"

AGY_MANIFEST_URL="${AGY_MANIFEST_URL:-https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_arm64_musl.json}"
ALPINE_BASE_URL="${ALPINE_BASE_URL:-https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64}"

DATA_DIR="${AGY_VM_DATA_DIR:-$HOME/.local/share/agy-armv7}"
CONF_FILE="$DATA_DIR/config.env"
CACHE_DIR="$DATA_DIR/cache"
VM_DIR="$DATA_DIR/vm"
SSH_DIR="$DATA_DIR/ssh"
RUN_DIR="${AGY_VM_RUN_DIR:-${PREFIX:-/tmp}/tmp/agy-vm}"

PID_FILE="$RUN_DIR/qemu.pid"
MON_SOCK="$RUN_DIR/mon.sock"
VM_LOG="$DATA_DIR/vm.log"
LOCK_DIR="$RUN_DIR/vm.lock"

SSH_KEY="$SSH_DIR/id_ed25519"
SSH_PUB="$SSH_DIR/id_ed25519.pub"

ROOTFS_IMG="$VM_DIR/rootfs.img"
KERNEL_IMG="$VM_DIR/vmlinuz-virt"
INITRD_IMG="$VM_DIR/initramfs-agy.img"
MODLOOP_IMG="$VM_DIR/modloop-virt"

# Colors when interactive
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_CYAN=$'\033[36m'
else
  C_RESET="" C_DIM="" C_BOLD="" C_GREEN="" C_YELLOW="" C_RED="" C_CYAN=""
fi

info() { printf '%s\n' "${C_CYAN}[..]${C_RESET} ${C_DIM}$*${C_RESET}" >&2; }
ok()   { printf '%s\n' "${C_GREEN}[OK]${C_RESET} $*" >&2; }
warn() { printf '%s\n' "${C_YELLOW}[WARN]${C_RESET} $*" >&2; }
err()  { printf '%s\n' "${C_RED}[ERR]${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

# Determine default VM RAM based on host /proc/meminfo MemTotal
default_vm_ram() {
  local mem_kb=0
  if [[ -r /proc/meminfo ]]; then
    mem_kb="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || echo 0)"
  fi
  local mem_mb=$(( ${mem_kb:-0} / 1024 ))
  if (( mem_mb <= 0 )); then
    echo "512M"
  elif (( mem_mb <= 2048 )); then
    echo "512M"
  elif (( mem_mb <= 3072 )); then
    echo "768M"
  else
    echo "1024M"
  fi
}

# Single vCPU on 32-bit ARM hosts avoids single-threaded TCG SMP round-robin overhead
default_vm_cpus() {
  case "${AGY_MOCK_UNAME_M:-$(uname -m)}" in
    arm|armv7*|armv8l) echo "1" ;;
    *)                 echo "2" ;;
  esac
}

# Set defaults and load config file safely if present
load_config() {
  VM_RAM="${VM_RAM:-}"
  VM_CPUS="${VM_CPUS:-}"
  VM_ZRAM_MB="${VM_ZRAM_MB:-}"
  VM_SSH_PORT="${VM_SSH_PORT:-}"
  VM_DISK_MB="${VM_DISK_MB:-}"
  AGY_HOME="${AGY_HOME:-}"
  AGY_STORAGE="${AGY_STORAGE:-}"
  ALPINE_BRANCH="${ALPINE_BRANCH:-}"
  AGY_VERSION="${AGY_VERSION:-}"
  BIN_NAME="${BIN_NAME:-}"

  if [[ -f "$CONF_FILE" ]]; then
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      if [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        # Strip surrounding single or double quotes if present
        if [[ "$val" =~ ^\"(.*)\"$ ]]; then
          val="${BASH_REMATCH[1]}"
        elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
          val="${BASH_REMATCH[1]}"
        fi
        case "$key" in
          VM_RAM|VM_CPUS|VM_ZRAM_MB|VM_SSH_PORT|VM_DISK_MB|AGY_HOME|AGY_STORAGE|ALPINE_BRANCH|AGY_VERSION|BIN_NAME)
            if [[ -z "${!key:-}" ]]; then
              printf -v "$key" '%s' "$val"
            fi
            ;;
        esac
      fi
    done < "$CONF_FILE"
  fi

  : "${VM_RAM:=$(default_vm_ram)}"
  : "${VM_CPUS:=$(default_vm_cpus)}"
  : "${VM_ZRAM_MB:=512}"
  : "${VM_SSH_PORT:=22229}"
  : "${VM_DISK_MB:=2048}"
  : "${AGY_HOME:=$HOME}"
  : "${AGY_STORAGE:=0}"
  : "${BIN_NAME:=agy}"
}

save_config() {
  mkdir -p "$DATA_DIR"
  local tmp_conf
  tmp_conf="$DATA_DIR/config.env.tmp.$$"
  cat > "$tmp_conf" <<EOF
# agy-armv7-termux VM configuration
VM_RAM="$VM_RAM"
VM_CPUS="$VM_CPUS"
VM_ZRAM_MB="$VM_ZRAM_MB"
VM_SSH_PORT="$VM_SSH_PORT"
VM_DISK_MB="$VM_DISK_MB"
AGY_HOME="$AGY_HOME"
AGY_STORAGE="$AGY_STORAGE"
ALPINE_BRANCH="${ALPINE_BRANCH:-}"
AGY_VERSION="${AGY_VERSION:-}"
BIN_NAME="${BIN_NAME:-agy}"
EOF
  mv -f "$tmp_conf" "$CONF_FILE"
}

# Atomic mkdir-based lock with stale PID recovery
acquire_lock() {
  local lockdir="${1:-$LOCK_DIR}"
  local timeout="${2:-30}"
  local waited=0
  local parent
  parent="$(dirname "$lockdir")"
  mkdir -p "$parent"

  while ! mkdir "$lockdir" 2>/dev/null; do
    local owner_pid=""
    if [[ -f "$lockdir/pid" ]]; then
      owner_pid="$(cat "$lockdir/pid" 2>/dev/null || true)"
    fi
    if [[ -n "$owner_pid" ]] && kill -0 "$owner_pid" 2>/dev/null; then
      if (( waited >= timeout * 5 )); then
        return 1
      fi
      sleep 0.2
      waited=$((waited + 1))
    else
      # Give a brief moment in case owner just ran mkdir before writing pid
      sleep 0.1
      owner_pid="$(cat "$lockdir/pid" 2>/dev/null || true)"
      if [[ -z "$owner_pid" ]] || ! kill -0 "$owner_pid" 2>/dev/null; then
        rm -rf "$lockdir" 2>/dev/null || true
      fi
    fi
  done

  printf '%s\n' "$$" > "$lockdir/pid"
  return 0
}

release_lock() {
  local lockdir="${1:-$LOCK_DIR}"
  if [[ -d "$lockdir" ]]; then
    local owner_pid=""
    if [[ -f "$lockdir/pid" ]]; then
      owner_pid="$(cat "$lockdir/pid" 2>/dev/null || true)"
    fi
    if [[ -z "$owner_pid" || "$owner_pid" == "$$" ]]; then
      rm -rf "$lockdir" 2>/dev/null || true
    fi
  fi
}

# Extract a string value for a JSON key (single or multiline JSON)
parse_json_key() {
  local payload="$1"
  local key="$2"
  printf '%s\n' "$payload" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

# Parse Alpine latest-releases.yaml for the alpine-minirootfs block.
# Outputs lines:
#   branch=...
#   version=...
#   file=...
#   sha512=...
#   size=...
parse_alpine_minirootfs_yaml() {
  awk '
    function flush_block() {
      if (flavor == "alpine-minirootfs" && file != "" && sha512 != "") {
        printf "branch=%s\nversion=%s\nfile=%s\nsha512=%s\nsize=%s\n", branch, version, file, sha512, size
        found = 1
      }
      branch = ""; version = ""; flavor = ""; file = ""; sha512 = ""; size = ""
    }
    /^[[:space:]]*-[[:space:]]*$/ {
      if (!found) flush_block()
      next
    }
    /^[[:space:]]+branch:[[:space:]]*/ {
      v = $0; sub(/^[[:space:]]+branch:[[:space:]]*/, "", v); gsub(/^["'\'']|["'\'']$/, "", v); branch = v
    }
    /^[[:space:]]+version:[[:space:]]*/ {
      v = $0; sub(/^[[:space:]]+version:[[:space:]]*/, "", v); gsub(/^["'\'']|["'\'']$/, "", v); version = v
    }
    /^[[:space:]]+flavor:[[:space:]]*/ {
      v = $0; sub(/^[[:space:]]+flavor:[[:space:]]*/, "", v); gsub(/^["'\'']|["'\'']$/, "", v); flavor = v
    }
    /^[[:space:]]+file:[[:space:]]*/ {
      v = $0; sub(/^[[:space:]]+file:[[:space:]]*/, "", v); gsub(/^["'\'']|["'\'']$/, "", v); file = v
    }
    /^[[:space:]]+sha512:[[:space:]]*/ {
      v = $0; sub(/^[[:space:]]+sha512:[[:space:]]*/, "", v); gsub(/^["'\'']|["'\'']$/, "", v); sha512 = v
    }
    /^[[:space:]]+size:[[:space:]]*/ {
      v = $0; sub(/^[[:space:]]+size:[[:space:]]*/, "", v); gsub(/^["'\'']|["'\'']$/, "", v); size = v
    }
    END {
      if (!found) flush_block()
      if (!found) exit 1
    }
  '
}

# Sentinel-'x' base64 encoder: preserves empty strings, trailing newlines, NUL-free binary/UTF-8 text
b64_encode_sentinel() {
  printf '%sx' "$1" | base64 | tr -d '\r\n'
}
