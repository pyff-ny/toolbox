#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
external_disk_monitor_csv.py (v4)
- WD Passport 等原生 USB 盘：SMART 不可用，走“可靠性监控”路线
- 修复点：从 physical disk(如 disk4) 推导 container(如 disk5) 改为解析 `diskutil list disk4`
- Finder 可见卷检测：扫描 /Volumes/* 并用 `diskutil info -plist` 判断是否属于 container(=disk5)
- 日志计数严格：只在包含 disk/container/卷名 token 的行里计数；fs_warn 仅统计真正 error/failed/fsck/corrupt 等，排除 tx_flush

用法（推荐）：
  sudo python3 external_disk_monitor_csv.py --physical disk4 --interval 300
单卷监控：
  sudo python3 external_disk_monitor_csv.py --volume "/Volumes/iMac" --interval 300
调试查看脚本发现了哪些卷：
  sudo python3 external_disk_monitor_csv.py --physical disk4 --once --debug
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import re
import socket
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import plistlib


# -------------------------
# Helpers
# -------------------------

def run(cmd: List[str]) -> Tuple[int, str, str]:
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except FileNotFoundError as e:
        return 127, "", f"FileNotFoundError: {e}"
    except Exception as e:
        return 1, "", f"subprocess error: {e}"
    out = p.stdout.decode("utf-8", errors="replace")
    err = p.stderr.decode("utf-8", errors="replace")
    return p.returncode, out, err


def run_bytes(cmd: List[str]) -> Tuple[int, bytes, bytes]:
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return p.returncode, p.stdout, p.stderr
    except Exception as e:
        return 1, b"", str(e).encode("utf-8", errors="replace")


def iso_ts() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def get_host() -> str:
    rc, out, _ = run(["scutil", "--get", "ComputerName"])
    name = out.strip() if rc == 0 else ""
    return name or socket.gethostname()


def get_os_version() -> str:
    rc, out, _ = run(["sw_vers", "-productVersion"])
    return out.strip() if rc == 0 else ""


def sanitize_name(s: str) -> str:
    return "".join(ch if ch.isalnum() or ch in ("-", "_") else "_" for ch in s)


def diskutil_info_plist(target: str) -> Optional[Dict[str, Any]]:
    rc, outb, _ = run_bytes(["diskutil", "info", "-plist", target])
    if rc != 0 or not outb:
        return None
    try:
        return plistlib.loads(outb)
    except Exception:
        return None


def statvfs_usage(mount_point: str) -> Tuple[Optional[int], Optional[int], Optional[int], Optional[float]]:
    try:
        st = os.statvfs(mount_point)
        total = st.f_frsize * st.f_blocks
        free = st.f_frsize * st.f_bavail
        used = total - free
        used_pct = (used / total * 100.0) if total > 0 else None
        return total, free, used, (round(used_pct, 2) if used_pct is not None else None)
    except Exception:
        return None, None, None, None


def extract_disk_id(s: Any) -> str:
    m = re.search(r"(disk\d+)", str(s))
    return m.group(1) if m else ""


# -------------------------
# Resolve: physical -> APFS container (robust via `diskutil list <physical>`)
# -------------------------

def find_container_from_physical_list(physical_disk: str) -> str:
    """
    Parse `diskutil list disk4` output and extract:
      Apple_APFS Container disk5  -> returns disk5
    """
    rc, out, _ = run(["diskutil", "list", physical_disk])
    if rc != 0:
        return ""
    # Common line: "Apple_APFS Container disk5"
    m = re.search(r"Apple_APFS\s+Container\s+(disk\d+)", out)
    if m:
        return m.group(1)
    # Sometimes formatted as: "Apple_APFS Container disk5" with extra spaces
    m = re.search(r"Container\s+(disk\d+)", out)
    return m.group(1) if m else ""


# -------------------------
# Finder-truth volumes: scan /Volumes and match by container disk
# -------------------------

def scan_volumes_for_container(container_disk: str) -> List[Dict[str, Any]]:
    vols: List[Dict[str, Any]] = []
    if not container_disk or not os.path.isdir("/Volumes"):
        return vols

    for name in os.listdir("/Volumes"):
        if not name or name.startswith("."):
            continue
        mp = f"/Volumes/{name}"
        if not os.path.isdir(mp):
            continue

        info = diskutil_info_plist(mp)
        if not info:
            continue

        dev_id = str(info.get("DeviceIdentifier", ""))         # disk5s2
        part_whole = str(info.get("PartOfWhole", ""))          # disk5 (often)
        pow_disk = extract_disk_id(part_whole)

        # Accept if:
        # - PartOfWhole is container disk5, OR
        # - DeviceIdentifier begins with disk5s
        if pow_disk != container_disk and not dev_id.startswith(container_disk + "s"):
            continue

        mount_point = str(info.get("MountPoint", mp))
        # Must be a Finder volume
        if not mount_point.startswith("/Volumes/"):
            continue

        vols.append({
            "volume_name": str(info.get("VolumeName", name)),
            "volume_disk": dev_id,
            "mount_point": mount_point,
            "fs_type": str(info.get("FilesystemType", "")),
            "volume_uuid": str(info.get("VolumeUUID", "")),
        })

    # Dedup by mount point
    uniq = {}
    for v in vols:
        uniq[v["mount_point"]] = v
    return list(uniq.values())


# -------------------------
# Focused unified log scanning (strict)
# -------------------------

def build_log_predicate(tokens: List[str]) -> str:
    parts = []
    for t in tokens:
        t = str(t).replace('"', '\\"')
        if t:
            parts.append(f'(eventMessage CONTAINS[c] "{t}")')
    parts.append('(process == "diskarbitrationd")')
    return " OR ".join(parts)


def fetch_logs_last_seconds(seconds: int, tokens: List[str], max_lines: int = 5000) -> str:
    window = max(10, min(seconds, 3600))
    predicate = build_log_predicate(tokens)
    rc, out, err = run([
        "log", "show",
        "--style", "syslog",
        "--last", f"{window}s",
        "--predicate", predicate
    ])
    text = out if rc == 0 else (out + "\n" + err)
    lines = text.splitlines()
    if len(lines) > max_lines:
        lines = lines[-max_lines:]
    return "\n".join(lines)


def classify_log_lines(text: str, tokens: List[str]) -> Tuple[Dict[str, int], Dict[str, List[str]]]:
    counts = {
        "log_lines": 0,
        "io_error": 0,
        "mount_unmount_fail": 0,
        "usb_mass_storage": 0,
        "usb_disconnect_reset": 0,
        "filesystem_warn": 0,
    }
    samples = {k: [] for k in counts.keys() if k != "log_lines"}

    if not text.strip():
        return counts, samples

    lines = text.splitlines()
    counts["log_lines"] = len(lines)

    re_io = re.compile(r"(I/O error|media is not present|unable to read|timeout|unresponsive)", re.I)
    re_mount = re.compile(r"(unable to mount|mount.*failed|unmount.*failed|dissented|not mounted)", re.I)

    re_usb_ms = re.compile(r"(USBMSC|MassStorage|IOUSBMassStorage|IOSCSI|USB.*Mass)", re.I)
    re_usb_host = re.compile(r"(IOUSBHost|AppleUSB|device removed|disconnect|terminated|enumerat|reset)", re.I)

    # Only count FS issues when it looks like a real problem (not tx_flush stats)
    re_fs = re.compile(r"(apfs|hfs|exfat)", re.I)
    re_fs_issue = re.compile(r"(error|failed|fsck|corrupt|inconsistent|invalid|checksum|unable)", re.I)
    re_noise = re.compile(r"(tx_flush|volume is not sealed|cannot perform extent manipulation)", re.I)

    def is_relevant(line: str) -> bool:
        low = line.lower()
        return any(t.lower() in low for t in tokens)

    def add_sample(bucket: str, line: str):
        if len(samples[bucket]) < 5:
            samples[bucket].append(line[:220])

    for ln in lines:
        if not is_relevant(ln):
            continue

        if re_io.search(ln):
            counts["io_error"] += 1
            add_sample("io_error", ln)

        if re_mount.search(ln):
            counts["mount_unmount_fail"] += 1
            add_sample("mount_unmount_fail", ln)

        if re_usb_ms.search(ln):
            counts["usb_mass_storage"] += 1
            add_sample("usb_mass_storage", ln)

        if re_usb_host.search(ln) and (re_usb_ms.search(ln) or "iousbhost" in ln.lower() or "usbmsc" in ln.lower()):
            counts["usb_disconnect_reset"] += 1
            add_sample("usb_disconnect_reset", ln)

        if re_fs.search(ln) and re_fs_issue.search(ln) and not re_noise.search(ln):
            counts["filesystem_warn"] += 1
            add_sample("filesystem_warn", ln)


    return counts, samples


# -------------------------
# CSV
# -------------------------

def ensure_csv_header(path: Path, fieldnames: List[str]) -> None:
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8-sig") as f:
        csv.DictWriter(f, fieldnames=fieldnames).writeheader()


def daily_csv_path(out_dir: Path, host: str, target: str) -> Path:
    day = dt.datetime.now().strftime("%Y-%m-%d")
    return out_dir / f"external_disk_{sanitize_name(host)}_{sanitize_name(target)}_{day}.csv"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default=str(Path.home() / "disk_logs"))
    ap.add_argument("--interval", type=int, default=300)
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--physical", default="disk4", help="physical disk like disk4")
    ap.add_argument("--volume", default="", help='single volume mount path like "/Volumes/iMac" (optional)')
    ap.add_argument("--debug", action="store_true", help="print detected volumes")
    args = ap.parse_args()

    host = get_host()
    os_ver = get_os_version()
    out_dir = Path(args.out_dir).expanduser().resolve()

    mode = "volume" if args.volume.strip() else "physical"
    physical = args.physical.strip()
    volume_path = args.volume.strip()

    fieldnames = [
        "timestamp","host","os_version",
        "mode","physical_disk","container_disk",
        "volume_name","volume_disk","mount_point","fs_type","volume_uuid",
        "present","mounted",
        "protocol","internal","removable","ejectable","device_media_name",
        "total_bytes","free_bytes","used_bytes","used_pct",
        "log_lines","io_error","mount_unmount_fail","usb_mass_storage","usb_disconnect_reset","filesystem_warn",
        "log_samples_json",
        "diskutil_physical_json",
        "sample_interval_s",
    ]

    def sample_once() -> None:
        ts = iso_ts()

        physical_info = diskutil_info_plist(physical) if physical else None
        present = "1" if physical_info else "0"

        protocol = str(physical_info.get("Protocol", "")) if physical_info else ""
        internal = str(physical_info.get("Internal", "")) if physical_info else ""
        removable = str(physical_info.get("RemovableMedia", "")) if physical_info else ""
        ejectable = str(physical_info.get("Ejectable", "")) if physical_info else ""
        dev_media = str(physical_info.get("MediaName", "")) if physical_info else ""

        container = ""
        target_vols: List[Dict[str, Any]] = []

        if mode == "volume":
            vinfo = diskutil_info_plist(volume_path)
            if not vinfo:
                target_vols = [{
                    "volume_name": os.path.basename(volume_path.rstrip("/")),
                    "volume_disk": "",
                    "mount_point": volume_path,
                    "fs_type": "",
                    "volume_uuid": "",
                }]
            else:
                # best-effort container from PartOfWhole
                container = extract_disk_id(vinfo.get("PartOfWhole", ""))
                target_vols = [{
                    "volume_name": str(vinfo.get("VolumeName", "")),
                    "volume_disk": str(vinfo.get("DeviceIdentifier", "")),
                    "mount_point": str(vinfo.get("MountPoint", volume_path)),
                    "fs_type": str(vinfo.get("FilesystemType", "")),
                    "volume_uuid": str(vinfo.get("VolumeUUID", "")),
                }]
        else:
            container = find_container_from_physical_list(physical)
            target_vols = scan_volumes_for_container(container)

            if args.debug:
                print(f"[DEBUG] physical={physical} -> container={container}")
                for v in target_vols:
                    print(f"[DEBUG] vol: {v.get('volume_name')} @ {v.get('mount_point')} ({v.get('volume_disk')})")

            if not target_vols:
                # still write a summary row
                target_vols = [{
                    "volume_name": "",
                    "volume_disk": "",
                    "mount_point": "",
                    "fs_type": "",
                    "volume_uuid": "",
                }]

        # tokens for log predicate
        tokens = []
        if physical:
            tokens += [physical, f"{physical}s", f"/dev/{physical}"]
        if container:
            tokens += [container, f"{container}s", f"/dev/{container}"]
        for v in target_vols:
            vn = v.get("volume_name", "")
            mp = v.get("mount_point", "")
            if vn:
                tokens.append(vn)
            if mp:
                tokens.append(os.path.basename(mp.rstrip("/")))

        log_text = fetch_logs_last_seconds(args.interval, tokens)
        counts, samples = classify_log_lines(log_text, tokens)

        csv_target = volume_path if mode == "volume" else physical
        csv_path = daily_csv_path(out_dir, host, csv_target)
        ensure_csv_header(csv_path, fieldnames)

        mounted_count = 0
        with csv_path.open("a", newline="", encoding="utf-8-sig") as f:
            w = csv.DictWriter(f, fieldnames=fieldnames)

            for v in target_vols:
                mount_point = v.get("mount_point", "")
                mounted = "1" if (mount_point and mount_point.startswith("/Volumes/") and os.path.isdir(mount_point)) else "0"
                if mounted == "1":
                    mounted_count += 1

                total_b = free_b = used_b = used_pct = None
                if mounted == "1":
                    total_b, free_b, used_b, used_pct = statvfs_usage(mount_point)

                row = {k: "" for k in fieldnames}
                row.update({
                    "timestamp": ts,
                    "host": host,
                    "os_version": os_ver,
                    "mode": mode,
                    "physical_disk": physical,
                    "container_disk": container,
                    "volume_name": v.get("volume_name",""),
                    "volume_disk": v.get("volume_disk",""),
                    "mount_point": mount_point,
                    "fs_type": v.get("fs_type",""),
                    "volume_uuid": v.get("volume_uuid",""),
                    "present": present,
                    "mounted": mounted,
                    "protocol": protocol,
                    "internal": internal,
                    "removable": removable,
                    "ejectable": ejectable,
                    "device_media_name": dev_media,
                    "total_bytes": total_b if total_b is not None else "",
                    "free_bytes": free_b if free_b is not None else "",
                    "used_bytes": used_b if used_b is not None else "",
                    "used_pct": used_pct if used_pct is not None else "",
                    "log_lines": counts["log_lines"],
                    "io_error": counts["io_error"],
                    "mount_unmount_fail": counts["mount_unmount_fail"],
                    "usb_mass_storage": counts["usb_mass_storage"],
                    "usb_disconnect_reset": counts["usb_disconnect_reset"],
                    "filesystem_warn": counts["filesystem_warn"],
                    "log_samples_json": json.dumps(samples, ensure_ascii=False, separators=(",", ":")),
                    "diskutil_physical_json": json.dumps(physical_info, ensure_ascii=False, separators=(",", ":")) if physical_info else "",
                    "sample_interval_s": args.interval,
                })
                w.writerow(row)

        print(f"Wrote: {csv_path}")
        print(f"mode={mode} physical={physical} container={container} mounted_vols={mounted_count} "
              f"io_error={counts['io_error']} mount_fail={counts['mount_unmount_fail']} "
              f"usb_ms={counts['usb_mass_storage']} usb_reset={counts['usb_disconnect_reset']} fs_warn={counts['filesystem_warn']}")

    if args.once:
        sample_once()
        return

    while True:
        sample_once()
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
