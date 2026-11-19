#!/usr/bin/env bash
# Isolated automated verification suite for agy-armv7-termux.
# Does not modify ~/.local/bin/agy or install system packages.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

TMP_ROOT="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '  [PASS] %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '  [FAIL] %s\n' "$1" >&2
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$label"
  else
    fail "$label (expected '$expected', got '$actual')"
  fi
}

printf '=== Running agy-armv7-termux test suite ===\n'

# 1. Syntax validation
printf '\n[1/8] Syntax validation (bash -n, sh -n, py_compile)\n'
for f in "$REPO_DIR/install.sh" "$REPO_DIR/bin/agy" "$REPO_DIR/bin/agy-vm" \
         "$REPO_DIR/lib/common.sh" "$REPO_DIR/lib/detect.sh" "$REPO_DIR/lib/fetch.sh" \
         "$REPO_DIR/lib/build_rootfs.sh" "$REPO_DIR/guest/agy-exec" "$REPO_DIR/tests/run_tests.sh"; do
  if bash -n "$f"; then
    pass "bash -n $(basename "$f")"
  else
    fail "bash -n $(basename "$f")"
  fi
done

for f in "$REPO_DIR/guest/init-agy" "$REPO_DIR/guest/agy-init" \
         "$REPO_DIR/guest/agy-sync-state" "$REPO_DIR/guest/agy-poweroff"; do
  if sh -n "$f"; then
    pass "sh -n $(basename "$f")"
  else
    fail "sh -n $(basename "$f")"
  fi
done

if python3 -m py_compile "$REPO_DIR/lib/build_initrd.py"; then
  pass "py_compile build_initrd.py"
else
  fail "py_compile build_initrd.py"
fi

# 2. Pure-Python initrd builder & verifier
printf '\n[2/8] build_initrd.py overlay construction & verification\n'
INITRD_TEST_DIR="$TMP_ROOT/initrd"
mkdir -p "$INITRD_TEST_DIR"
python3 - "$INITRD_TEST_DIR/base.gz" <<'PY'
import gzip, sys
# Build a valid synthetic gzipped newc cpio base containing /bin/sh placeholder
def entry(name, mode, data):
    nb = name.encode() + b"\x00"
    hdr = f"070701{1:08x}{mode:08x}{0:08x}{0:08x}{1:08x}{0:08x}{len(data):08x}{0:08x}{0:08x}{0:08x}{0:08x}{len(nb):08x}{0:08x}".encode()
    def p4(b): return b + (b"\x00" * ((4 - len(b) % 4) % 4))
    return p4(hdr + nb) + p4(data)
payload = entry("bin", 0o040755, b"") + entry("bin/sh", 0o100755, b"#!/bin/sh\n") + entry("TRAILER!!!", 0, b"")
with open(sys.argv[1], "wb") as f:
    f.write(gzip.compress(payload, mtime=0))
PY

if python3 "$REPO_DIR/lib/build_initrd.py" \
     --base "$INITRD_TEST_DIR/base.gz" \
     --init "$REPO_DIR/guest/init-agy" \
     --output "$INITRD_TEST_DIR/initramfs-agy.gz" >/dev/null; then
  pass "build_initrd.py build"
else
  fail "build_initrd.py build"
fi

if gzip -t "$INITRD_TEST_DIR/initramfs-agy.gz"; then
  pass "gzip -t on initramfs-agy.gz"
else
  fail "gzip -t on initramfs-agy.gz"
fi

if python3 "$REPO_DIR/lib/build_initrd.py" \
     --verify "$INITRD_TEST_DIR/initramfs-agy.gz" \
     --init "$REPO_DIR/guest/init-agy" | grep -q "format=gzip.*mode=0o100755 uid=0 gid=0"; then
  pass "build_initrd.py --verify gzip mode=0o100755 uid=0 gid=0"
else
  fail "build_initrd.py --verify gzip"
fi

if python3 "$REPO_DIR/lib/build_initrd.py" \
     --base "$INITRD_TEST_DIR/base.gz" \
     --init "$REPO_DIR/guest/init-agy" \
     --no-compress \
     --output "$INITRD_TEST_DIR/initramfs-agy.img" | grep -q "format=cpio.*mode=0o100755 uid=0 gid=0"; then
  pass "build_initrd.py --no-compress cpio build & verify"
else
  fail "build_initrd.py --no-compress"
fi

# 3. Environment detector matrix
printf '\n[3/8] detect.sh matrix\n'
(
  # shellcheck disable=SC1091
  . "$REPO_DIR/lib/detect.sh"
  r1="$(AGY_MOCK_UNAME_M=armv7l AGY_MOCK_UNAME_O=Android AGY_MOCK_ABILIST64="" AGY_MOCK_HAS_LINKER64=0 AGY_MOCK_TERMUX=1 detect_environment)"
  assert_eq "armv7_vm" "$r1" "detect armv7l pure 32-bit"

  r2="$(AGY_MOCK_UNAME_M=armv8l AGY_MOCK_UNAME_O=Android AGY_MOCK_ABILIST64="" AGY_MOCK_HAS_LINKER64=0 AGY_MOCK_TERMUX=1 detect_environment)"
  assert_eq "armv7_vm" "$r2" "detect armv8l 32-bit userland"

  r3="$(AGY_MOCK_UNAME_M=armv7l AGY_MOCK_UNAME_O=Android AGY_MOCK_ABILIST64="arm64-v8a" AGY_MOCK_HAS_LINKER64=1 AGY_MOCK_TERMUX=1 detect_environment)"
  assert_eq "arm64_termux_mismatch" "$r3" "detect 32-bit Termux on 64-bit Android"

  r4="$(AGY_MOCK_UNAME_M=aarch64 AGY_MOCK_UNAME_O=Android AGY_MOCK_ABILIST64="arm64-v8a" AGY_MOCK_HAS_LINKER64=1 AGY_MOCK_TERMUX=1 detect_environment)"
  assert_eq "native_arm64" "$r4" "detect native aarch64"

  r5="$(qemu_pkg_for_env armv7l)"
  assert_eq "qemu-system-aarch64-9" "$r5" "qemu_pkg_for_env armv7l"

  r6="$(qemu_pkg_for_env aarch64)"
  assert_eq "qemu-system-aarch64-headless" "$r6" "qemu_pkg_for_env aarch64"
)

# 4. agy-exec sentinel-x base64 framing & roundtrip
printf '\n[4/8] agy-exec argument, quoting, newline, Unicode & env roundtrip\n'
EXEC_TEST_DIR="$TMP_ROOT/exec_test"
mkdir -p "$EXEC_TEST_DIR/sub dir"
PYTHON_BIN="$(command -v python3)"
cat > "$EXEC_TEST_DIR/mock_agy" <<EOF
#!$PYTHON_BIN
import json, os, sys
print(json.dumps({
    "cwd": os.getcwd(),
    "args": sys.argv[1:],
    "env1": os.environ.get("AGY_TEST_VAR"),
    "env2": os.environ.get("AGY_TEST_VAR2"),
}, ensure_ascii=False))
sys.exit(42)
EOF
chmod +x "$EXEC_TEST_DIR/mock_agy"

(
  # shellcheck disable=SC1091
  . "$REPO_DIR/lib/common.sh"
  cwd_in="$EXEC_TEST_DIR/sub dir"
  arg1=""
  arg2="-n"
  arg3="--"
  arg4=$'line1\n"quoted" \'$HOME\' `id`\n'
  arg5="مرحبا بالعالم 🚀"
  env1="hello 'world' \$PATH"
  env2=$'multi\nline\n'

  set +e
  out="$(AGY_HOME="$EXEC_TEST_DIR" "$REPO_DIR/guest/agy-exec" \
    --binary "$EXEC_TEST_DIR/mock_agy" \
    --cwd "$(b64_encode_sentinel "$cwd_in")" \
    --env "$(b64_encode_sentinel "AGY_TEST_VAR"):$(b64_encode_sentinel "$env1")" \
    --env "$(b64_encode_sentinel "AGY_TEST_VAR2"):$(b64_encode_sentinel "$env2")" \
    -- \
    "$(b64_encode_sentinel "$arg1")" \
    "$(b64_encode_sentinel "$arg2")" \
    "$(b64_encode_sentinel "$arg3")" \
    "$(b64_encode_sentinel "$arg4")" \
    "$(b64_encode_sentinel "$arg5")")"
  rc=$?
  set -e

  if [[ "$rc" -eq 42 ]]; then
    pass "agy-exec exit code preserved (42)"
  else
    fail "agy-exec exit code preserved (expected 42, got $rc)"
  fi

  if python3 - "$out" "$cwd_in" "$arg4" "$arg5" "$env1" "$env2" <<'PY'
import json, os, sys
d = json.loads(sys.argv[1])
assert os.path.realpath(d["cwd"]) == os.path.realpath(sys.argv[2]), (d["cwd"], sys.argv[2])
assert d["args"] == ["", "-n", "--", sys.argv[3], sys.argv[4]], d["args"]
assert d["env1"] == sys.argv[5], (d["env1"], sys.argv[5])
assert d["env2"] == sys.argv[6], (d["env2"], sys.argv[6])
PY
  then
    pass "agy-exec byte-for-byte cwd/args/env roundtrip"
  else
    fail "agy-exec byte-for-byte cwd/args/env roundtrip"
  fi
)

# 5. agy-sync-state pull/push (skipping SQLite files)
printf '\n[5/8] agy-sync-state pull/push and SQLite exclusion\n'
HOST_STATE="$TMP_ROOT/host_state"
VM_STATE="$TMP_ROOT/vm_state"
mkdir -p "$HOST_STATE/skills/demo" "$VM_STATE"
printf 'token-abc\n' > "$HOST_STATE/antigravity-oauth-token"
chmod 0644 "$HOST_STATE/antigravity-oauth-token"
printf '{"model":"test"}\n' > "$HOST_STATE/settings.json"
printf '# Skill\n' > "$HOST_STATE/skills/demo/SKILL.md"
printf 'sqlite-bytes' > "$HOST_STATE/conversation_summaries.db"
printf 'wal-bytes' > "$HOST_STATE/conversation_summaries.db-wal"
printf 'shm-bytes' > "$HOST_STATE/conversation_summaries.db-shm"
printf 'bad-db' > "$HOST_STATE/skills/demo/cache.db"

AGY_HOST_STATE_DIR="$HOST_STATE" AGY_VM_STATE_DIR="$VM_STATE" "$REPO_DIR/guest/agy-sync-state" pull

if [[ -f "$VM_STATE/antigravity-oauth-token" && -f "$VM_STATE/settings.json" && -f "$VM_STATE/skills/demo/SKILL.md" ]]; then
  pass "agy-sync-state pull copied auth, settings, skills"
else
  fail "agy-sync-state pull missing expected files"
fi

perm="$(stat -c '%a' "$VM_STATE/antigravity-oauth-token" 2>/dev/null || python3 -c "import os,stat; print(oct(stat.S_IMODE(os.stat('$VM_STATE/antigravity-oauth-token').st_mode))[2:])")"
assert_eq "600" "$perm" "agy-sync-state enforced 0600 on oauth token"

if [[ ! -e "$VM_STATE/conversation_summaries.db" && ! -e "$VM_STATE/conversation_summaries.db-wal" && ! -e "$VM_STATE/conversation_summaries.db-shm" && ! -e "$VM_STATE/skills/demo/cache.db" ]]; then
  pass "agy-sync-state pull excluded SQLite db/wal/shm files"
else
  fail "agy-sync-state pull leaked SQLite files"
fi

sleep 1
printf 'token-updated\n' > "$VM_STATE/antigravity-oauth-token"
printf 'vm-db' > "$VM_STATE/conversation_summaries.db"
AGY_HOST_STATE_DIR="$HOST_STATE" AGY_VM_STATE_DIR="$VM_STATE" "$REPO_DIR/guest/agy-sync-state" push
assert_eq "token-updated" "$(cat "$HOST_STATE/antigravity-oauth-token")" "agy-sync-state push updated token"
assert_eq "sqlite-bytes" "$(cat "$HOST_STATE/conversation_summaries.db")" "agy-sync-state push did not overwrite host SQLite db"

# 6. Live upstream manifest & Alpine YAML parser smoke tests
printf '\n[6/8] Live upstream manifest & Alpine YAML parsers\n'
(
  # shellcheck disable=SC1091
  . "$REPO_DIR/lib/common.sh"
  # shellcheck disable=SC1091
  . "$REPO_DIR/lib/fetch.sh"

  fetch_agy_manifest
  if [[ -n "$FETCH_AGY_VERSION" && "$FETCH_AGY_URL" == https://*linux_arm64_musl.tar.gz && ${#FETCH_AGY_SHA512} -eq 128 ]]; then
    pass "fetch_agy_manifest (v$FETCH_AGY_VERSION)"
  else
    fail "fetch_agy_manifest parsed invalid data"
  fi

  fetch_alpine_meta
  if [[ "$FETCH_ALPINE_BRANCH" == v* && "$FETCH_ALPINE_FILE" == alpine-minirootfs-*-aarch64.tar.gz && ${#FETCH_ALPINE_SHA512} -eq 128 ]]; then
    pass "fetch_alpine_meta ($FETCH_ALPINE_BRANCH / $FETCH_ALPINE_VERSION)"
  else
    fail "fetch_alpine_meta parsed invalid data"
  fi
)

# 7. CLI smoke tests in isolated AGY_VM_DATA_DIR
printf '\n[7/8] install.sh --dry-run and agy-vm CLI smoke tests\n'
ISO_DATA="$TMP_ROOT/iso_data"
ISO_RUN="$TMP_ROOT/iso_run"

dry_out="$(AGY_VM_DATA_DIR="$ISO_DATA" AGY_VM_RUN_DIR="$ISO_RUN" \
     "$REPO_DIR/install.sh" --dry-run --force-vm --bin-dir "$TMP_ROOT/bin" --bin-name agy-test)"
if [[ "$dry_out" == *"Dry-run plan"* ]]; then
  pass "install.sh --dry-run --force-vm"
else
  fail "install.sh --dry-run --force-vm"
fi

help_out="$(AGY_VM_DATA_DIR="$ISO_DATA" AGY_VM_RUN_DIR="$ISO_RUN" "$REPO_DIR/bin/agy-vm" --help)"
if [[ "$help_out" == *"doctor"* ]]; then
  pass "agy-vm --help"
else
  fail "agy-vm --help"
fi

AGY_VM_DATA_DIR="$ISO_DATA" AGY_VM_RUN_DIR="$ISO_RUN" "$REPO_DIR/bin/agy-vm" config set ram 768M >/dev/null
AGY_VM_DATA_DIR="$ISO_DATA" AGY_VM_RUN_DIR="$ISO_RUN" "$REPO_DIR/bin/agy-vm" config set cpus 3 >/dev/null
cfg_out="$(AGY_VM_DATA_DIR="$ISO_DATA" AGY_VM_RUN_DIR="$ISO_RUN" "$REPO_DIR/bin/agy-vm" config show)"
if [[ "$cfg_out" == *"VM_RAM=768M"* && "$cfg_out" == *"VM_CPUS=3"* ]]; then
  pass "agy-vm config set/show"
else
  fail "agy-vm config set/show"
fi

status_out="$(AGY_VM_DATA_DIR="$ISO_DATA" AGY_VM_RUN_DIR="$ISO_RUN" "$REPO_DIR/bin/agy-vm" status)"
if [[ "$status_out" == *"VM Status:   stopped"* ]]; then
  pass "agy-vm status (stopped)"
else
  fail "agy-vm status (stopped)"
fi

doctor_out="$(AGY_VM_DATA_DIR="$ISO_DATA" AGY_VM_RUN_DIR="$ISO_RUN" "$REPO_DIR/bin/agy-vm" doctor)"
if [[ "$doctor_out" == *"Detected Profile:"* ]]; then
  pass "agy-vm doctor"
else
  fail "agy-vm doctor"
fi

# 8. Native ~/.local/bin/agy safety check
printf '\n[8/8] Host native agy safety check\n'
if command -v agy >/dev/null 2>&1; then
  native_ver="$(agy --version 2>/dev/null | tail -n 1 || true)"
  if [[ "$native_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    pass "native agy --version untouched ($native_ver)"
  else
    fail "native agy --version invalid ('$native_ver')"
  fi
else
  pass "no host agy to disturb"
fi

printf '\n=== Summary: %d passed, %d failed ===\n' "$PASS_COUNT" "$FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then
  exit 1
fi
