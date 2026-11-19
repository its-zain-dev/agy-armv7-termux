#!/usr/bin/env bash
# Installer for agy-armv7-termux (Antigravity CLI ARMv7 Termux micro-VM port).
# Works both from a local git clone and when piped via:
#   curl -fsSL https://raw.githubusercontent.com/its-zain-dev/agy-armv7-termux/main/install.sh | bash

set -euo pipefail

AGY_PORT_REPO="${AGY_PORT_REPO:-its-zain-dev/agy-armv7-termux}"
AGY_PORT_BRANCH="${AGY_PORT_BRANCH:-main}"

SCRIPT_SRC="${BASH_SOURCE[0]:-}"
REPO_DIR=""
if [[ -n "$SCRIPT_SRC" && -f "$SCRIPT_SRC" ]]; then
  REPO_DIR="$(cd "$(dirname "$SCRIPT_SRC")" && pwd)"
fi

# Self-bootstrap from GitHub archive when invoked via curl | bash (no sibling lib/common.sh)
if [[ -z "$REPO_DIR" || ! -f "$REPO_DIR/lib/common.sh" ]]; then
  if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
    if command -v pkg >/dev/null 2>&1; then
      echo "[..] Installing curl and tar via pkg..." >&2
      pkg update -y
      pkg install -y curl tar gzip
    else
      echo "[ERR] curl and tar are required to bootstrap agy-armv7-termux." >&2
      exit 1
    fi
  fi

  BOOTSTRAP_TMP="$(mktemp -d "${TMPDIR:-/tmp}/agy-armv7-bootstrap.XXXXXX")"
  trap 'rm -rf "$BOOTSTRAP_TMP" 2>/dev/null || true' EXIT
  ARCHIVE_URL="https://github.com/${AGY_PORT_REPO}/archive/refs/heads/${AGY_PORT_BRANCH}.tar.gz"
  echo "[..] Downloading ${AGY_PORT_REPO} (${AGY_PORT_BRANCH}) from GitHub..." >&2
  curl -fsSL "$ARCHIVE_URL" | tar -xz -C "$BOOTSTRAP_TMP"
  EXTRACTED_DIR="$(find "$BOOTSTRAP_TMP" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [[ -z "$EXTRACTED_DIR" || ! -f "$EXTRACTED_DIR/install.sh" ]]; then
    echo "[ERR] Failed to unpack agy-armv7-termux archive from $ARCHIVE_URL" >&2
    exit 1
  fi
  chmod +x "$EXTRACTED_DIR/install.sh"
  set +e
  "$EXTRACTED_DIR/install.sh" "$@"
  rc=$?
  set -e
  exit "$rc"
fi

# Parse flags early so --data-dir takes effect before sourcing common.sh
if [[ -n "${PREFIX:-}" && -d "${PREFIX}/bin" && -w "${PREFIX}/bin" ]]; then
  BIN_DIR="${PREFIX}/bin"
else
  BIN_DIR="$HOME/.local/bin"
fi
BIN_NAME="agy"
ARG_DATA_DIR=""
ARG_RAM=""
ARG_CPUS=""
ARG_PORT=""
FORCE_VM=0
NO_START=0
SKIP_PKGS=0
DRY_RUN=0

show_help() {
  cat <<EOF
Usage: $(basename "$0") [options]

Installs the ARMv7 Android Termux port of Google Antigravity CLI (agy)
using a lightweight Alpine Linux aarch64 micro-VM.

Options:
  --bin-dir <dir>     Directory for wrapper executables (default: \$PREFIX/bin in Termux, else ~/.local/bin)
  --bin-name <name>   Name for the CLI wrapper (default: agy)
  --data-dir <dir>    Directory for VM images & state (default: ~/.local/share/agy-armv7)
  --ram <size>        VM RAM size, e.g. 512M, 768M, 1024M (default: auto)
  --cpus <n>          VM vCPU count (default: 2)
  --port <port>       Host localhost SSH forward port (default: 22229)
  --force-vm          Allow VM installation on 64-bit capable or non-Android hosts
  --no-start          Build VM images without booting on install
  --skip-pkgs         Skip Termux pkg install step
  --dry-run           Show resolved plan and exit without making changes
  -h, --help          Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin-dir)   BIN_DIR="$2"; shift 2 ;;
    --bin-name)  BIN_NAME="$2"; shift 2 ;;
    --data-dir)  ARG_DATA_DIR="$2"; shift 2 ;;
    --ram)       ARG_RAM="$2"; shift 2 ;;
    --cpus)      ARG_CPUS="$2"; shift 2 ;;
    --port)      ARG_PORT="$2"; shift 2 ;;
    --force-vm)  FORCE_VM=1; shift ;;
    --no-start)  NO_START=1; shift ;;
    --skip-pkgs) SKIP_PKGS=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   show_help; exit 0 ;;
    *)           echo "Unknown option: $1" >&2; show_help >&2; exit 1 ;;
  esac
done

if [[ -n "$ARG_DATA_DIR" ]]; then
  export AGY_VM_DATA_DIR="$ARG_DATA_DIR"
fi

# shellcheck disable=SC1091
. "$REPO_DIR/lib/common.sh"
# shellcheck disable=SC1091
. "$REPO_DIR/lib/detect.sh"
# shellcheck disable=SC1091
. "$REPO_DIR/lib/fetch.sh"
# shellcheck disable=SC1091
. "$REPO_DIR/lib/build_rootfs.sh"

load_config
[[ -n "$ARG_RAM" ]]  && VM_RAM="$ARG_RAM"
[[ -n "$ARG_CPUS" ]] && VM_CPUS="$ARG_CPUS"
[[ -n "$ARG_PORT" ]] && VM_SSH_PORT="$ARG_PORT"
[[ -d "$HOME/storage" ]] && AGY_STORAGE=1

env_kind="$(detect_environment)"
host_arch="${AGY_MOCK_UNAME_M:-$(uname -m)}"
qemu_pkg="$(qemu_pkg_for_env "$host_arch" || echo "qemu-system-aarch64")"

case "$env_kind" in
  armv7_vm)
    info "Detected 32-bit ARM Android Termux ($host_arch) — proceeding with micro-VM port."
    ;;
  arm64_termux_mismatch)
    if (( FORCE_VM == 0 )); then
      warn "Your Android device supports 64-bit arm64-v8a, but you are running 32-bit Termux."
      warn "For native speed without emulation, install the arm64-v8a Termux APK and run:"
      warn "  curl -fsSL https://antigravity.google/cli/install.sh | bash"
      die "Or re-run with --force-vm if you intentionally want the VM setup."
    fi
    warn "Forcing VM installation on arm64_termux_mismatch (--force-vm)."
    ;;
  native_arm64)
    if (( FORCE_VM == 0 )); then
      warn "You are running 64-bit aarch64 Termux where Google publishes an official native build."
      warn "Install natively instead via:"
      warn "  curl -fsSL https://antigravity.google/cli/install.sh | bash"
      die "Use --force-vm (and optionally --bin-name agy-vm-cli) only if testing the VM port."
    fi
    warn "Forcing VM installation on native aarch64 (--force-vm)."
    ;;
  unsupported)
    if (( FORCE_VM == 0 )); then
      die "Unsupported host environment ($(uname -s) / $host_arch). Pass --force-vm to override."
    fi
    warn "Forcing VM installation on unsupported host (--force-vm)."
    ;;
esac

if (( DRY_RUN == 1 )); then
  printf 'Dry-run plan (no changes written):\n'
  printf '  Environment:  %s (%s)\n' "$env_kind" "$host_arch"
  printf '  QEMU Package: %s\n' "$qemu_pkg"
  printf '  Data Dir:     %s\n' "$DATA_DIR"
  printf '  Bin Wrapper:  %s/%s and %s/agy-vm\n' "$BIN_DIR" "$BIN_NAME" "$BIN_DIR"
  printf '  VM Config:    RAM=%s CPUs=%s ZRAM=%sM Port=%s Disk=%sM\n' \
    "$VM_RAM" "$VM_CPUS" "$VM_ZRAM_MB" "$VM_SSH_PORT" "$VM_DISK_MB"
  printf '  Auto-start:   %s\n' "$([[ $NO_START -eq 1 ]] && echo no || echo yes)"
  exit 0
fi

# Step 1: Host package prerequisites
if (( SKIP_PKGS == 0 )); then
  if command -v pkg >/dev/null 2>&1; then
    info "Installing required Termux packages..."
    pkg update -y
    case "$host_arch" in
      arm|armv7*|armv8l)
        pkg install -y x11-repo tur-repo
        pkg update -y
        pkg install -y qemu-system-aarch64-9 e2fsprogs openssh curl tar gzip python
        ;;
      aarch64|arm64)
        pkg install -y qemu-system-aarch64-headless e2fsprogs openssh curl tar gzip python
        ;;
      *)
        die "Automatic package installation is only configured for Termux ARM hosts. Use --skip-pkgs."
        ;;
    esac
  else
    warn "'pkg' command not found; skipping package install."
  fi
fi

for req in mke2fs ssh ssh-keygen curl tar gzip python3; do
  command -v "$req" >/dev/null 2>&1 || die "Required command '$req' not found."
done
qemu_bin_for_host >/dev/null || die "qemu-system-aarch64 not found."

# Step 2: Prepare directories & fetch upstream artifacts
mkdir -p "$DATA_DIR" "$CACHE_DIR" "$VM_DIR" "$SSH_DIR" "$BIN_DIR"
chmod 0700 "$SSH_DIR"

download_agy_tarball
download_alpine_assets

# Step 3: Build custom initramfs with /init-agy
info "Building initramfs with rdinit=/init-agy..."
python3 "$REPO_DIR/lib/build_initrd.py" \
  --base "$FETCH_ALPINE_INITRAMFS" \
  --init "$REPO_DIR/guest/init-agy" \
  --output "$INITRD_IMG"

# Step 4: Generate SSH keypair for rootless localhost PTY/exec bridge
if [[ ! -f "$SSH_KEY" || ! -f "$SSH_PUB" ]]; then
  info "Generating Ed25519 SSH keypair..."
  rm -f "$SSH_KEY" "$SSH_PUB"
  ssh-keygen -t ed25519 -N "" -C "agy-armv7-termux" -f "$SSH_KEY" >/dev/null
fi
chmod 0600 "$SSH_KEY"
chmod 0644 "$SSH_PUB"

# Step 5: Build sparse ext4 rootfs image
build_rootfs_image \
  "$FETCH_ALPINE_ROOTFS" \
  "$FETCH_AGY_TARBALL" \
  "$SSH_PUB" \
  "$ROOTFS_IMG" \
  "$VM_DISK_MB" \
  "$FETCH_ALPINE_BRANCH" \
  "$REPO_DIR/guest"

# Step 6: Install runtime scripts & thin wrappers
mkdir -p "$DATA_DIR/bin" "$DATA_DIR/lib" "$DATA_DIR/guest"
cp "$REPO_DIR/bin/agy" "$DATA_DIR/bin/agy"
cp "$REPO_DIR/bin/agy-vm" "$DATA_DIR/bin/agy-vm"
cp "$REPO_DIR/lib/"*.sh "$REPO_DIR/lib/"*.py "$DATA_DIR/lib/"
cp "$REPO_DIR/guest/"* "$DATA_DIR/guest/"
chmod 0755 "$DATA_DIR/bin/agy" "$DATA_DIR/bin/agy-vm" "$DATA_DIR/lib/build_initrd.py" "$DATA_DIR/lib/build_rootfs.sh" "$DATA_DIR/guest/"*

install_wrapper() {
  local target_name="$1"
  local exec_target="$2"
  local dst="$BIN_DIR/$target_name"
  if [[ -f "$dst" ]] && ! grep -q "AGY_VM_DATA_DIR" "$dst" 2>/dev/null; then
    warn "Existing non-VM file at $dst; backing up to ${dst}.bak"
    mv -f "$dst" "${dst}.bak"
  fi
  cat > "$dst" <<EOF
#!/usr/bin/env bash
export AGY_VM_DATA_DIR="\${AGY_VM_DATA_DIR:-$DATA_DIR}"
export AGY_VM_LIB_DIR="\${AGY_VM_LIB_DIR:-$DATA_DIR/lib}"
export AGY_VM_BIN="\${AGY_VM_BIN:-$DATA_DIR/bin/agy-vm}"
exec "$exec_target" "\$@"
EOF
  chmod 0755 "$dst"
}

install_wrapper "$BIN_NAME" "$DATA_DIR/bin/agy"
install_wrapper "agy-vm" "$DATA_DIR/bin/agy-vm"

AGY_VERSION="$FETCH_AGY_VERSION"
ALPINE_BRANCH="$FETCH_ALPINE_BRANCH"
save_config

ok "Installed wrappers: $BIN_DIR/$BIN_NAME and $BIN_DIR/agy-vm"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    warn "$BIN_DIR is not in your PATH. Add it to ~/.bashrc:"
    printf '  export PATH="%s:$PATH"\n' "$BIN_DIR" >&2
    ;;
esac

if (( NO_START == 0 )); then
  info "Booting micro-VM for first-time setup (downloads Dropbear + TLS certs)..."
  "$BIN_DIR/agy-vm" start --wait
  ok "Verified inside VM: $("$BIN_DIR/$BIN_NAME" --version 2>/dev/null || echo "ready")"
else
  info "Skipped VM start (--no-start). Start later with: agy-vm start --wait"
fi

printf '\n%s\n' "Installation complete! Run '$BIN_NAME' to start Antigravity CLI, or 'agy-vm status' to inspect the VM."
