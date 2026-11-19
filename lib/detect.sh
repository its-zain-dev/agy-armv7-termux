#!/usr/bin/env bash
# Architecture and environment classification for agy-armv7-termux.

# Outputs one of:
#   armv7_vm              - 32-bit ARM Android Termux without 64-bit userspace (primary target)
#   arm64_termux_mismatch - 32-bit ARM Termux running on a 64-bit capable Android OS
#   native_arm64          - 64-bit aarch64 Android Termux
#   unsupported           - Any other OS/architecture
detect_environment() {
  local uname_m="${AGY_MOCK_UNAME_M:-$(uname -m)}"
  local uname_o="${AGY_MOCK_UNAME_O:-$(uname -o 2>/dev/null || uname -s)}"

  local abilist64
  if [[ -n "${AGY_MOCK_ABILIST64+x}" ]]; then
    abilist64="$AGY_MOCK_ABILIST64"
  elif command -v getprop >/dev/null 2>&1; then
    abilist64="$(getprop ro.product.cpu.abilist64 2>/dev/null || true)"
  else
    abilist64=""
  fi

  local has_linker64="0"
  if [[ -n "${AGY_MOCK_HAS_LINKER64+x}" ]]; then
    has_linker64="$AGY_MOCK_HAS_LINKER64"
  elif [[ -e /system/bin/linker64 ]]; then
    has_linker64="1"
  fi

  local is_termux="0"
  if [[ -n "${AGY_MOCK_TERMUX+x}" ]]; then
    is_termux="$AGY_MOCK_TERMUX"
  elif [[ -n "${TERMUX_VERSION:-}" || "${PREFIX:-}" == *com.termux* ]]; then
    is_termux="1"
  fi

  if [[ "$uname_o" != "Android" && "$is_termux" != "1" ]]; then
    echo "unsupported"
    return 0
  fi

  case "$uname_m" in
    aarch64|arm64)
      echo "native_arm64"
      ;;
    arm|armv7*|armv8l)
      if [[ "$abilist64" == *arm64-v8a* && "$has_linker64" == "1" ]]; then
        echo "arm64_termux_mismatch"
      else
        echo "armv7_vm"
      fi
      ;;
    *)
      echo "unsupported"
      ;;
  esac
}

# Returns the QEMU package name to install in Termux for the host architecture.
qemu_pkg_for_env() {
  local arch="${1:-${AGY_MOCK_UNAME_M:-$(uname -m)}}"
  case "$arch" in
    arm|armv7*|armv8l)
      echo "qemu-system-aarch64-9"
      ;;
    aarch64|arm64)
      echo "qemu-system-aarch64-headless"
      ;;
    *)
      echo ""
      return 1
      ;;
  esac
}

# Finds the qemu-system-aarch64 executable on host.
qemu_bin_for_host() {
  if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    command -v qemu-system-aarch64
    return 0
  fi
  if command -v qemu-system-aarch64-9 >/dev/null 2>&1; then
    command -v qemu-system-aarch64-9
    return 0
  fi
  local p="${PREFIX:-/data/data/com.termux/files/usr}"
  if [[ -x "$p/bin/qemu-system-aarch64" ]]; then
    echo "$p/bin/qemu-system-aarch64"
    return 0
  fi
  return 1
}
