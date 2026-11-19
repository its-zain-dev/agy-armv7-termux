# agy-armv7-termux

Full ARMv7 (32-bit `arm` / `armv7l` / `armv8l`) Android **Termux** port of Google's **Antigravity CLI (`agy`)**.

Google officially distributes `agy` only as 64-bit binaries (`android_arm64`, `linux_arm64`, `linux_arm64_musl`, `linux_amd64`, `linux_amd64_musl`). All 32-bit manifests return HTTP `404`. Because `agy` is closed-source, this project runs Google's official statically linked `linux_arm64_musl` binary inside a lightweight, rootless **Alpine Linux `aarch64` micro-VM** powered by `qemu-system-aarch64-9` from the Termux User Repository (`tur-repo`), with transparent `$HOME` sharing and PTY forwarding so `agy` works directly from your Termux prompt.

---

## Why Neither Native Compilation Nor `qemu-user-aarch64` Works on ARMv7

1. **No 32-bit upstream build & closed-source binary:** Google's manifest server returns `404` for `android_arm`, `android_armv7`, `linux_arm`, `linux_armv7`, and `linux_arm_musl`.
2. **32-bit virtual address space exhaustion (`VmPeak ≈ 3.84 GB`):** Even `agy --help` maps ~228 MB of ELF segments and reserves ~3.84 GB (`3,843,264 kB`) of virtual memory for TCMalloc / Go runtime arenas. On a 32-bit ARMv7 host kernel, userspace virtual memory is capped at ~3.0 GB (`TASK_SIZE`), making `qemu-user-aarch64` fail to reserve memory.
3. **Android Seccomp restrictions:** Android's seccomp filter blocks syscalls such as `faccessat2` used by Go/musl runtimes.

Running `linux_arm64_musl` inside a full-system `qemu-system-aarch64` Alpine Linux micro-VM gives `agy` a real 64-bit Linux kernel, 48-bit virtual address space, and zero Android seccomp interference — without root access.

---

## Architecture

```
Termux (ARMv7 Android, unrooted)
├── agy  ──────────────────────────▶ Dropbear SSH (-tt PTY / -T pipe)
│   (encodes cwd, env, args via       │   over 127.0.0.1:22229 (SLIRP)
│    sentinel-x base64 framing)       ▼
└── qemu-system-aarch64-9 (TCG) ──▶ Alpine Linux aarch64 VM (kernel -virt)
    ├── /dev/vda (sparse ext4)        ├── /usr/local/bin/agy (linux_arm64_musl)
    ├── /dev/vdb (modloop-virt)       ├── /usr/local/bin/agy-exec
    ├── virtio-net (SLIRP 10.0.2.x)   ├── zram swap (/dev/zram0)
    ├── virtio-rng-pci (entropy)      ├── 9pfs mount ─▶ Termux $HOME (exact path)
    └── virtfs 9p (hosthome)          └── ext4 bind  ─▶ ~/.gemini/antigravity-cli
                                          (keeps SQLite WAL off 9pfs; syncs auth/settings)
```

Key design details:
- **Rootless image creation:** Builds the sparse ext4 disk image directly in Termux using `mke2fs -d` and builds the `rdinit=/init-agy` initramfs overlay in pure Python (`lib/build_initrd.py`).
- **Exact `$HOME` path fidelity:** Mounts Termux `$HOME` via `9pfs` (`security_model=none`) and bind-mounts it to the identical `$HOME` path inside the VM so file paths, git repos, and tool arguments match 1:1.
- **SQLite WAL safety:** Keeps `conversation_summaries.db` (`-wal` / `-shm`) on native VM ext4 (`/var/lib/agy-state`) while `agy-sync-state` syncs `antigravity-oauth-token`, `settings.json`, `GEMINI.md`, and `skills/` back to Termux `$HOME/.gemini/antigravity-cli`.
- **Byte-safe argument & TTY forwarding:** `bin/agy` frames every argument and environment variable with trailing-sentinel-`x` base64 so quotes, newlines, empty strings, flags (`-n`, `--`), and Unicode/Arabic pass untouched into `guest/agy-exec`.

---

## Requirements

- **Device:** 32-bit ARM (`armv7l`, `armv8l` 32-bit userland, `arm`) running Android Termux (F-Droid / GitHub build recommended).
- **Memory:** At least 2 GB RAM (the VM auto-sizes to `512M` on <=2 GB devices, `768M` on <=3 GB, `1024M` on >=4 GB, backed by 512 MB zram swap inside the guest).
- **Storage:** ~450–600 MB free space for QEMU packages, Alpine netboot assets, `agy` binary, and sparse ext4 rootfs.

> **Note:** If your phone has a 64-bit CPU (`arm64-v8a`) and is only running a 32-bit Termux APK (`arm64_termux_mismatch`), `install.sh` will detect that and advise installing the 64-bit `arm64-v8a` Termux APK so you can use Google's native `android_arm64` build directly at full speed (pass `--force-vm` to override).

---

## Installation

```bash
git clone https://github.com/its-zain-dev/agy-armv7-termux.git
cd agy-armv7-termux
./install.sh
```

What `install.sh` does:
1. Detects your Termux architecture (`lib/detect.sh`).
2. Installs `x11-repo`, `tur-repo`, `qemu-system-aarch64-9`, `e2fsprogs`, `openssh`, `curl`, `tar`, `gzip`, and `python`.
3. Downloads and SHA512-verifies Google's `linux_arm64_musl` release and Alpine Linux `aarch64` assets.
4. Generates an Ed25519 SSH keypair, builds `initramfs-agy.gz` and sparse `rootfs.img`, and installs `agy` and `agy-vm` wrappers into `~/.local/bin`.
5. Boots the VM (`agy-vm start --wait`), provisions Dropbear SSH and TLS CA certificates on first boot, and verifies `agy --version`.

Useful installer flags:
```bash
./install.sh --dry-run                 # Preview detected profile and plan without changing anything
./install.sh --ram 768M --cpus 2       # Customize VM resources
./install.sh --bin-dir ~/.local/bin    # Customize wrapper target directory
./install.sh --no-start                # Prepare images without booting immediately
./install.sh --force-vm --bin-name agy-vm-cli   # Test alongside native agy on aarch64
```

---

## Usage

Once installed, use `agy` just like the native CLI:

```bash
agy --version
agy --help
agy                        # Interactive TUI (with PTY resize support)
agy -p "Explain main.py"   # Non-interactive / piped print mode
```

If the VM is stopped when you run `agy`, it automatically starts in the background and waits until SSH is ready.

### VM Management (`agy-vm`)

| Command | Description |
| --- | --- |
| `agy-vm start [--wait]` | Start the micro-VM in the background (optionally wait until SSH ready) |
| `agy-vm stop [--force]` | Sync auth state and cleanly power off the VM |
| `agy-vm restart` | Stop and restart the VM (required after `config set`) |
| `agy-vm status` | Show VM PID, SSH status, RAM/vCPU/zram config, disk usage, and `agy` version |
| `agy-vm shell` | Open an interactive `bash` shell inside the Alpine VM at `$PWD` |
| `agy-vm logs [-f]` | View or follow the VM serial console log |
| `agy-vm update` | Download, SHA512-verify, and hot-update `agy` inside the VM |
| `agy-vm sync-auth [pull\|push]` | Manually sync OAuth token and settings between Termux `$HOME` and VM |
| `agy-vm config [show \| set K V]` | Inspect or update `ram`, `cpus`, `zram`, `port` |
| `agy-vm doctor` | Run full diagnostics on architecture, QEMU, host tools, space, and VM state |
| `agy-vm uninstall [--purge]` | Stop VM and remove installed wrappers/VM files (`--purge` deletes cache/config) |

---

## Authentication

Because `agy` runs headless inside the VM over localhost SSH:
- **OAuth login:** Run `agy`. When prompted with an authorization URL, copy the URL into your Android browser, authorize, and paste the callback code/URL back into `agy`.
- **Existing token:** If `~/.gemini/antigravity-cli/antigravity-oauth-token` already exists in your Termux `$HOME`, `agy-init` automatically imports it on boot (`agy-sync-state pull`) and `agy-poweroff` syncs updates back (`agy-sync-state push`).
- **API key:** Export `GEMINI_API_KEY` or `GOOGLE_API_KEY` in Termux; `bin/agy` forwards them into the VM automatically.

---

## Performance Tuning

For devices with 3–4 GB+ RAM:
```bash
agy-vm config set ram 1024M
agy-vm config set cpus 4
agy-vm restart
```

For tighter 2 GB RAM devices:
```bash
agy-vm config set ram 512M
agy-vm config set zram 768
agy-vm restart
```

---

## Troubleshooting

- **Check everything with `doctor`:**
  ```bash
  agy-vm doctor
  ```
- **Inspect boot or first-run `apk` provisioning errors:**
  ```bash
  agy-vm logs
  ```
- **First boot takes longer than usual:** On the very first boot only, the VM downloads `dropbear`, `bash`, `ca-certificates`, `curl`, `git`, `ripgrep`, `coreutils`, and `tzdata` via `apk` inside QEMU TCG emulation (typically 30–90 seconds depending on CPU speed and network). Subsequent boots take a few seconds.
- **Working directory outside `$HOME`:** Termux's `$HOME` is shared with the VM via 9pfs (`AGY_STORAGE=1` also shares `~/storage` if present). Directories outside `$HOME` fall back to `$HOME`.
