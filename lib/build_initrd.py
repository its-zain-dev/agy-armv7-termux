#!/usr/bin/env python3
"""Pure-Python initramfs overlay builder and verifier for agy-armv7-termux.

Injects /init-agy (mode 0100755, uid 0, gid 0) as an SVR4 newc (070701) cpio
entry on top of Alpine's initramfs-virt image. Supports both gzip-compressed
concatenated output and uncompressed cpio output (--no-compress, which avoids
emulated gzip decompression overhead inside QEMU TCG on ARMv7 devices).
"""

import argparse
import gzip
import os
import stat
import sys
import zlib


CPIO_MAGIC = b"070701"


def _pad4(data: bytes) -> bytes:
    rem = len(data) % 4
    if rem:
        return data + (b"\x00" * (4 - rem))
    return data


def make_newc_entry(name: str, mode: int, content: bytes) -> bytes:
    name_bytes = name.encode("utf-8") + b"\x00"
    namesize = len(name_bytes)
    filesize = len(content)
    header = (
        f"070701"
        f"{1:08x}"          # ino
        f"{mode:08x}"       # mode
        f"{0:08x}"          # uid
        f"{0:08x}"          # gid
        f"{1:08x}"          # nlink
        f"{0:08x}"          # mtime
        f"{filesize:08x}"   # filesize
        f"{0:08x}"          # devmajor
        f"{0:08x}"          # devminor
        f"{0:08x}"          # rdevmajor
        f"{0:08x}"          # rdevminor
        f"{namesize:08x}"   # namesize
        f"{0:08x}"          # check
    ).encode("ascii")
    assert len(header) == 110
    head_padded = _pad4(header + name_bytes)
    data_padded = _pad4(content)
    return head_padded + data_padded


def extract_cpio_streams(raw: bytes) -> list[bytes]:
    """Extract one or more cpio archives from gzipped and/or uncompressed initramfs bytes."""
    streams = []
    buf = raw
    while buf:
        buf = buf.lstrip(b"\x00")
        if not buf:
            break
        if buf[:2] == b"\x1f\x8b":
            d = zlib.decompressobj(16 + zlib.MAX_WBITS)
            out = d.decompress(buf) + d.flush()
            streams.append(out)
            buf = d.unused_data
        elif buf[:6] == CPIO_MAGIC:
            # Consume uncompressed newc cpio segments until end or gzip stream
            pos = 0
            total = len(buf)
            while pos + 110 <= total:
                while pos < total and buf[pos] == 0:
                    pos += 1
                if pos + 110 > total or buf[pos : pos + 6] != CPIO_MAGIC:
                    break
                filesize = int(buf[pos + 54 : pos + 62], 16)
                namesize = int(buf[pos + 94 : pos + 102], 16)
                name_start = pos + 110
                name_end = name_start + namesize
                name = buf[name_start : name_end - 1].decode("utf-8", errors="replace")
                data_start = ((name_end + 3) // 4) * 4
                data_end = data_start + filesize
                pos = ((data_end + 3) // 4) * 4
                if name == "TRAILER!!!":
                    streams.append(buf[:pos])
                    buf = buf[pos:]
                    break
            else:
                raise ValueError("Unterminated uncompressed cpio stream")
        else:
            raise ValueError(f"Unexpected initramfs stream header: {buf[:6].hex()}")
    return streams


def build_initrd(base_path: str, init_path: str, output_path: str, no_compress: bool = False) -> None:
    with open(base_path, "rb") as f:
        base_bytes = f.read()
    if len(base_bytes) < 6 or (base_bytes[:2] != b"\x1f\x8b" and base_bytes[:6] != CPIO_MAGIC):
        raise ValueError(f"Base initramfs is neither gzip nor newc cpio: {base_path}")

    with open(init_path, "rb") as f:
        init_bytes = f.read()
    if not init_bytes:
        raise ValueError(f"Init script is empty: {init_path}")

    cpio_overlay = (
        make_newc_entry("init-agy", stat.S_IFREG | 0o755, init_bytes)
        + make_newc_entry("TRAILER!!!", 0, b"")
    )

    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    tmp_path = f"{output_path}.tmp.{os.getpid()}"
    with open(tmp_path, "wb") as f:
        if no_compress:
            base_streams = extract_cpio_streams(base_bytes)
            for s in base_streams:
                f.write(_pad4(s))
            f.write(_pad4(cpio_overlay))
        else:
            f.write(base_bytes)
            f.write(gzip.compress(cpio_overlay, compresslevel=6, mtime=0))
    os.replace(tmp_path, output_path)


def parse_newc_entries(cpio_data: bytes) -> list[dict]:
    entries = []
    pos = 0
    total = len(cpio_data)
    while pos + 110 <= total:
        while pos < total and cpio_data[pos] == 0:
            pos += 1
        if pos + 110 > total:
            break
        if cpio_data[pos : pos + 6] != CPIO_MAGIC:
            raise ValueError(f"Invalid cpio magic at offset {pos}: {cpio_data[pos:pos+6]!r}")
        mode = int(cpio_data[pos + 14 : pos + 22], 16)
        uid = int(cpio_data[pos + 22 : pos + 30], 16)
        gid = int(cpio_data[pos + 30 : pos + 38], 16)
        filesize = int(cpio_data[pos + 54 : pos + 62], 16)
        namesize = int(cpio_data[pos + 94 : pos + 102], 16)

        name_start = pos + 110
        name_end = name_start + namesize
        if name_end > total:
            raise ValueError("Truncated cpio entry name")
        name = cpio_data[name_start : name_end - 1].decode("utf-8", errors="replace")

        data_start = ((name_end + 3) // 4) * 4
        data_end = data_start + filesize
        if data_end > total:
            raise ValueError(f"Truncated cpio entry data for {name}")
        content = cpio_data[data_start:data_end]
        pos = ((data_end + 3) // 4) * 4

        if name == "TRAILER!!!":
            continue
        entries.append(
            {
                "name": name,
                "mode": mode,
                "uid": uid,
                "gid": gid,
                "size": filesize,
                "content": content,
            }
        )
    return entries


def verify_initrd(path: str, expected_init_path: str | None = None) -> None:
    with open(path, "rb") as f:
        raw = f.read()

    streams = extract_cpio_streams(raw)
    if not streams:
        raise ValueError("No cpio streams found in initramfs")

    all_entries = []
    for s in streams:
        all_entries.extend(parse_newc_entries(s))

    matches = [e for e in all_entries if e["name"] == "init-agy"]
    if not matches:
        raise ValueError("init-agy not found in initramfs")

    target = matches[-1]
    if not stat.S_ISREG(target["mode"]) or (target["mode"] & 0o7777) != 0o755:
        raise ValueError(f"init-agy has invalid mode: {oct(target['mode'])}")
    if target["uid"] != 0 or target["gid"] != 0:
        raise ValueError(f"init-agy has non-root ownership: {target['uid']}:{target['gid']}")

    if expected_init_path is not None:
        with open(expected_init_path, "rb") as f:
            expected_bytes = f.read()
        if target["content"] != expected_bytes:
            raise ValueError("init-agy content mismatch against source script")

    kind = "gzip" if raw[:2] == b"\x1f\x8b" else "cpio"
    print(
        f"OK: format={kind} streams={len(streams)} entries={len(all_entries)} "
        f"init-agy mode={oct(target['mode'])} uid={target['uid']} gid={target['gid']} size={target['size']}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Build or verify agy-armv7-termux initramfs")
    parser.add_argument("--base", help="Base initramfs-virt path")
    parser.add_argument("--init", help="Path to guest/init-agy")
    parser.add_argument("--output", help="Output initramfs path")
    parser.add_argument(
        "--no-compress",
        action="store_true",
        help="Write uncompressed newc cpio (faster guest kernel boot under QEMU TCG)",
    )
    parser.add_argument("--verify", help="Verify an existing initramfs file")
    args = parser.parse_args()

    if args.verify:
        verify_initrd(args.verify, args.init)
        return 0

    if not args.base or not args.init or not args.output:
        parser.error("--base, --init, and --output are required when not using --verify")

    build_initrd(args.base, args.init, args.output, no_compress=args.no_compress)
    verify_initrd(args.output, args.init)
    return 0


if __name__ == "__main__":
    sys.exit(main())
