#!/usr/bin/env bash
# Rootless sparse ext4 rootfs builder for agy-armv7-termux.
# Assumes lib/common.sh is already sourced (or sources it if run directly).

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/common.sh"
fi

build_rootfs_image() {
  local alpine_tarball="$1"
  local agy_tarball="$2"
  local ssh_pub_path="$3"
  local rootfs_img="$4"
  local disk_mb="${5:-2048}"
  local alpine_branch="${6:-latest-stable}"
  local guest_dir="$7"

  [[ -f "$alpine_tarball" ]] || die "Alpine minirootfs tarball not found: $alpine_tarball"
  [[ -f "$agy_tarball" ]] || die "Antigravity tarball not found: $agy_tarball"
  [[ -f "$ssh_pub_path" ]] || die "SSH public key not found: $ssh_pub_path"
  command -v mke2fs >/dev/null 2>&1 || die "mke2fs (e2fsprogs) is required to build rootfs."

  local work_parent
  work_parent="$(dirname "$rootfs_img")"
  mkdir -p "$work_parent"

  local staging
  staging="$(mktemp -d "${work_parent}/staging.XXXXXX")"
  local tmp_img="${rootfs_img}.tmp.$$"

  cleanup_rootfs_build() {
    rm -rf "$staging" "$tmp_img" 2>/dev/null || true
  }
  trap cleanup_rootfs_build RETURN

  info "Extracting Alpine minirootfs..."
  tar -xzf "$alpine_tarball" -C "$staging" --no-same-owner --exclude='./dev/*' --exclude='dev/*'

  mkdir -p \
    "$staging/dev" \
    "$staging/proc" \
    "$staging/sys" \
    "$staging/run" \
    "$staging/tmp" \
    "$staging/mnt/hosthome" \
    "$staging/mnt/hoststorage" \
    "$staging/.modloop" \
    "$staging/lib/modules" \
    "$staging/var/lib/agy-state" \
    "$staging/etc/dropbear" \
    "$staging/etc/apk" \
    "$staging/usr/local/bin" \
    "$staging/usr/local/sbin" \
    "$staging/usr/sbin" \
    "$staging/root/.ssh"

  # Defer extracting the ~228 MB agy binary until first boot inside the VM so we
  # avoid duplicating 228 MB in $staging + 228 MB in rootfs.img on low-storage phones.
  mkdir -p "$staging/var/tmp" "$staging/var/lib"
  local agy_tar_abs agy_home_abs
  agy_tar_abs="$(cd "$(dirname "$agy_tarball")" && pwd)/$(basename "$agy_tarball")"
  agy_home_abs="$(cd "${AGY_HOME:-$HOME}" && pwd)"

  if [[ "$agy_tar_abs" == "$agy_home_abs/"* ]]; then
    local rel_tar="${agy_tar_abs#"$agy_home_abs"/}"
    info "Staging deferred in-VM extraction for Antigravity CLI (zero host duplication)..."
    printf '/mnt/hosthome/%s\n' "$rel_tar" > "$staging/var/lib/agy-tarball.path"
  else
    info "Copying compressed Antigravity CLI tarball into rootfs for first-boot extraction..."
    cp "$agy_tar_abs" "$staging/var/tmp/agy.tar.gz"
    printf '/var/tmp/agy.tar.gz\n' > "$staging/var/lib/agy-tarball.path"
  fi

  # Install guest init, exec, state sync, and poweroff scripts
  cp "$guest_dir/agy-init" "$staging/usr/sbin/agy-init"
  chmod 0755 "$staging/usr/sbin/agy-init"
  if [[ -d "$staging/sbin" && ! -L "$staging/sbin" ]]; then
    cp "$guest_dir/agy-init" "$staging/sbin/agy-init"
    chmod 0755 "$staging/sbin/agy-init"
  fi

  cp "$guest_dir/agy-exec" "$staging/usr/local/bin/agy-exec"
  chmod 0755 "$staging/usr/local/bin/agy-exec"

  cp "$guest_dir/agy-sync-state" "$staging/usr/local/sbin/agy-sync-state"
  chmod 0755 "$staging/usr/local/sbin/agy-sync-state"

  cp "$guest_dir/agy-poweroff" "$staging/usr/local/sbin/agy-poweroff"
  chmod 0755 "$staging/usr/local/sbin/agy-poweroff"

  # SSH authorized_keys and unlock root account for pubkey auth (Dropbear rejects root:!:)
  cp "$ssh_pub_path" "$staging/root/.ssh/authorized_keys"
  chmod 0700 "$staging/root" "$staging/root/.ssh"
  chmod 0600 "$staging/root/.ssh/authorized_keys"

  if [[ -f "$staging/etc/shadow" ]]; then
    awk -F: 'BEGIN{OFS=":"} $1=="root" && $2=="!" {$2="*"} {print}' "$staging/etc/shadow" > "$staging/etc/shadow.new"
    mv -f "$staging/etc/shadow.new" "$staging/etc/shadow"
    chmod 0640 "$staging/etc/shadow" || true
  fi

  printf '%s\n' "agy-arm64" > "$staging/etc/hostname"
  cat > "$staging/etc/hosts" <<'EOF'
127.0.0.1 localhost agy-arm64
::1       localhost agy-arm64
EOF
  cat > "$staging/etc/resolv.conf" <<'EOF'
nameserver 10.0.2.3
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
  cat > "$staging/etc/apk/repositories" <<EOF
https://dl-cdn.alpinelinux.org/alpine/${alpine_branch}/main
https://dl-cdn.alpinelinux.org/alpine/${alpine_branch}/community
EOF

  info "Creating sparse ${disk_mb}MB ext4 rootfs image..."
  mke2fs -t ext4 -F -q -L agyroot -O ^orphan_file -d "$staging" "$tmp_img" "${disk_mb}M"
  mv -f "$tmp_img" "$rootfs_img"
  ok "Rootfs image created at $rootfs_img"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 7 ]]; then
    echo "Usage: $0 <alpine_tarball> <agy_tarball> <ssh_pub> <rootfs_img> <disk_mb> <alpine_branch> <guest_dir>" >&2
    exit 1
  fi
  build_rootfs_image "$@"
fi
