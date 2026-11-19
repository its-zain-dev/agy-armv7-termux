#!/usr/bin/env bash
# Upstream artifact fetcher & verifier for agy-armv7-termux.
# Assumes lib/common.sh is already sourced.

# Verify magic bytes of downloaded artifacts using Python (portable across Termux/Linux).
verify_magic_bytes() {
  local filepath="$1"
  local kind="$2"
  [[ -s "$filepath" ]] || return 1

  python3 - "$filepath" "$kind" <<'PY'
import sys

path, kind = sys.argv[1], sys.argv[2]
with open(path, "rb") as f:
    head = f.read(64)

if len(head) < 4:
    sys.exit(1)

if kind == "gzip":
    sys.exit(0 if head[:2] == b"\x1f\x8b" else 1)
elif kind == "squashfs":
    sys.exit(0 if head[:4] == b"hsqs" else 1)
elif kind == "arm64_kernel":
    # Accepts EFI zboot (MZ..zimg), gzipped Image, or raw ARM64 Image ("ARM\x64" at 0x38)
    is_zboot = (head[:2] == b"MZ" and head[4:8] == b"zimg")
    is_gzip = (head[:2] == b"\x1f\x8b")
    is_raw = (len(head) >= 60 and head[56:60] == b"ARM\x64")
    sys.exit(0 if (is_zboot or is_gzip or is_raw) else 1)
else:
    sys.exit(1)
PY
}

# Compute SHA512 hex digest of a file
file_sha512() {
  local filepath="$1"
  if command -v sha512sum >/dev/null 2>&1; then
    sha512sum "$filepath" | awk '{print $1}'
  else
    python3 -c 'import hashlib,sys; h=hashlib.sha512(); f=open(sys.argv[1],"rb");
for c in iter(lambda: f.read(1048576), b""): h.update(c)
print(h.hexdigest())' "$filepath"
  fi
}

# Download url to dst atomically, optionally verifying sha512 and magic kind
download_file_verified() {
  local url="$1"
  local dst="$2"
  local expected_sha="${3:-}"
  local magic_kind="${4:-}"

  mkdir -p "$(dirname "$dst")"

  if [[ -f "$dst" ]]; then
    if [[ -n "$expected_sha" ]]; then
      local cur_sha
      cur_sha="$(file_sha512 "$dst")"
      if [[ "$cur_sha" == "$expected_sha" ]]; then
        if [[ -z "$magic_kind" ]] || verify_magic_bytes "$dst" "$magic_kind"; then
          return 0
        fi
      fi
    elif [[ -n "$magic_kind" ]] && verify_magic_bytes "$dst" "$magic_kind"; then
      return 0
    fi
  fi

  local part="${dst}.part.$$"
  rm -f "$part"
  if ! curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$part" "$url"; then
    rm -f "$part"
    return 1
  fi

  if [[ -n "$expected_sha" ]]; then
    local got_sha
    got_sha="$(file_sha512 "$part")"
    if [[ "$got_sha" != "$expected_sha" ]]; then
      err "SHA512 mismatch for $url (expected $expected_sha, got $got_sha)"
      rm -f "$part"
      return 1
    fi
  fi

  if [[ -n "$magic_kind" ]] && ! verify_magic_bytes "$part" "$magic_kind"; then
    err "Invalid file format ($magic_kind) downloaded from $url"
    rm -f "$part"
    return 1
  fi

  mv -f "$part" "$dst"
}

fetch_agy_manifest() {
  local json
  json="$(curl -fsSL --retry 3 --retry-delay 2 "$AGY_MANIFEST_URL")" || return 1
  FETCH_AGY_VERSION="$(parse_json_key "$json" "version")"
  FETCH_AGY_URL="$(parse_json_key "$json" "url")"
  FETCH_AGY_SHA512="$(parse_json_key "$json" "sha512")"

  if [[ -z "$FETCH_AGY_VERSION" || -z "$FETCH_AGY_URL" || ${#FETCH_AGY_SHA512} -ne 128 ]]; then
    err "Failed to parse valid manifest from $AGY_MANIFEST_URL"
    return 1
  fi
}

download_agy_tarball() {
  fetch_agy_manifest || return 1
  local target="$CACHE_DIR/cli_linux_arm64_musl-${FETCH_AGY_VERSION}.tar.gz"
  info "Downloading Antigravity CLI v${FETCH_AGY_VERSION} (linux_arm64_musl)..."
  download_file_verified "$FETCH_AGY_URL" "$target" "$FETCH_AGY_SHA512" "gzip" || return 1
  FETCH_AGY_TARBALL="$target"
  ok "Antigravity CLI v${FETCH_AGY_VERSION} verified."
}

fetch_alpine_meta() {
  local yaml parsed kv
  yaml="$(curl -fsSL --retry 3 --retry-delay 2 "$ALPINE_BASE_URL/latest-releases.yaml")" || return 1
  parsed="$(printf '%s\n' "$yaml" | parse_alpine_minirootfs_yaml)" || {
    err "Failed to find alpine-minirootfs in $ALPINE_BASE_URL/latest-releases.yaml"
    return 1
  }

  FETCH_ALPINE_BRANCH=""
  FETCH_ALPINE_VERSION=""
  FETCH_ALPINE_FILE=""
  FETCH_ALPINE_SHA512=""
  FETCH_ALPINE_SIZE=""

  while IFS='=' read -r k v; do
    case "$k" in
      branch)  FETCH_ALPINE_BRANCH="$v" ;;
      version) FETCH_ALPINE_VERSION="$v" ;;
      file)    FETCH_ALPINE_FILE="$v" ;;
      sha512)  FETCH_ALPINE_SHA512="$v" ;;
      size)    FETCH_ALPINE_SIZE="$v" ;;
    esac
  done <<< "$parsed"

  if [[ -z "$FETCH_ALPINE_BRANCH" || -z "$FETCH_ALPINE_FILE" || ${#FETCH_ALPINE_SHA512} -ne 128 ]]; then
    err "Incomplete Alpine minirootfs metadata."
    return 1
  fi
}

download_alpine_assets() {
  fetch_alpine_meta || return 1

  FETCH_ALPINE_ROOTFS="$CACHE_DIR/$FETCH_ALPINE_FILE"
  FETCH_ALPINE_KERNEL="$VM_DIR/vmlinuz-virt"
  FETCH_ALPINE_INITRAMFS="$CACHE_DIR/initramfs-virt-${FETCH_ALPINE_VERSION}"
  FETCH_ALPINE_MODLOOP="$VM_DIR/modloop-virt"

  info "Downloading Alpine Linux ${FETCH_ALPINE_VERSION} (${FETCH_ALPINE_BRANCH}) minirootfs..."
  download_file_verified "$ALPINE_BASE_URL/$FETCH_ALPINE_FILE" "$FETCH_ALPINE_ROOTFS" "$FETCH_ALPINE_SHA512" "gzip" || return 1

  info "Downloading Alpine virt kernel, initramfs, and modloop..."
  download_file_verified "$ALPINE_BASE_URL/netboot/vmlinuz-virt" "$FETCH_ALPINE_KERNEL" "" "arm64_kernel" || return 1
  download_file_verified "$ALPINE_BASE_URL/netboot/initramfs-virt" "$FETCH_ALPINE_INITRAMFS" "" "gzip" || return 1
  download_file_verified "$ALPINE_BASE_URL/netboot/modloop-virt" "$FETCH_ALPINE_MODLOOP" "" "squashfs" || return 1

  ok "Alpine Linux ${FETCH_ALPINE_VERSION} assets ready."
}
