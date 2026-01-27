#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
ssd_monitor_csv.py (macOS SSD SMART -> CSV, robust JSON extraction)

Install:
  brew install smartmontools

Run:
  sudo python3 ssd_monitor_csv.py --once
  sudo python3 ssd_monitor_csv.py --interval 60
"""

from __future__ import annotations
import re
import argparse
import csv
import datetime as dt
import json
import socket
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, Optional, Tuple


def run(cmd: list[str]) -> Tuple[int, str, str]:
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except FileNotFoundError as e:
        return 127, "", f"FileNotFoundError: {e}"
    except Exception as e:
        return 1, "", f"subprocess error: {e}"
    out = p.stdout.decode("utf-8", errors="replace")
    err = p.stderr.decode("utf-8", errors="replace")
    return p.returncode, out, err


def iso_ts() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def get_host() -> str:
    rc, out, _ = run(["scutil", "--get", "ComputerName"])
    name = out.strip() if rc == 0 else ""
    return name or socket.gethostname()


def get_os_version() -> str:
    rc, out, _ = run(["sw_vers", "-productVersion"])
    return out.strip() if rc == 0 else ""


#def get_system_whole_disk() -> str:
    """
    Prefer APFS Physical Store (disk0s2 -> disk0)
    """
    rc, out, _ = run(["diskutil", "info", "/"])
    if rc != 0:
        return "UNKNOWN"

    physical_slice = ""
    part_whole = ""

    for line in out.splitlines():
        s = line.strip()
        if s.startswith("APFS Physical Store:") or s.startswith("Physical Store:"):
            physical_slice = s.split(":", 1)[1].strip()
        elif s.startswith("Part of Whole:"):
            part_whole = s.split(":", 1)[1].strip()

    if physical_slice:
        if physical_slice.startswith("disk") and "s" in physical_slice:
            return physical_slice.split("s", 1)[0]
        return "UNKNOWN"
    disk = disk.strip()#强制清洗 防脏字符
    return part_whole or "UNKNOWN"
def get_system_whole_disk() -> str:
    """
    Return physical whole disk backing '/' (e.g., disk0).
    Fix: do NOT split on 's' because 'disk' contains 's'.
    Use regex to extract 'disk<digits>' safely.
    """
    rc, out, _ = run(["diskutil", "info", "/"])
    if rc != 0:
        return "UNKNOWN"

    physical_slice = ""
    part_whole = ""

    for line in out.splitlines():
        s = line.strip()
        if s.startswith("APFS Physical Store:") or s.startswith("Physical Store:"):
            physical_slice = s.split(":", 1)[1].strip()
        elif s.startswith("Part of Whole:"):
            part_whole = s.split(":", 1)[1].strip()

    # Prefer Physical Store (e.g., "disk0s2" -> "disk0")
    if physical_slice:
        m = re.search(r"(disk\d+)", physical_slice)
        if m:
            return m.group(1)

    # Fallback: Part of Whole (e.g., "disk3" -> "disk3")
    if part_whole:
        m = re.search(r"(disk\d+)", part_whole)
        if m:
            return m.group(1)

    return "UNKNOWN"


def parse_diskutil_info(whole_disk: str) -> Dict[str, str]:
    info: Dict[str, str] = {
        "disk": whole_disk,
        "device_node": f"/dev/{whole_disk}" if whole_disk != "UNKNOWN" else "",
        "protocol": "",
        "model": "",
        "serial": "",
        "firmware": "",
        "smart_status": "",
        "internal": "",
    }
    if whole_disk == "UNKNOWN":
        return info

    rc, out, _ = run(["diskutil", "info", whole_disk])
    if rc != 0:
        return info

    def grab(key: str) -> str:
        for line in out.splitlines():
            if line.strip().startswith(key):
                return line.split(":", 1)[1].strip()
        return ""

    info["protocol"] = grab("Protocol")
    info["model"] = grab("Device / Media Name") or grab("Media Name")
    info["firmware"] = grab("Firmware Version")
    info["smart_status"] = grab("SMART Status")
    info["internal"] = grab("Internal")
    # macOS often doesn't show true serial; keep stable field name anyway
    info["serial"] = grab("Disk / Partition UUID")
    return info


def smartctl_json_nvme(whole_disk: str) -> Tuple[Optional[Dict[str, Any]], str, str, str]:
    """
    Returns (json, rc, err, used_devnode)
    Accept rc!=0 as long as JSON exists.
    """
    if whole_disk == "UNKNOWN":
        return None, "", "", ""

    #devs = [f"/dev/r{whole_disk}", f"/dev/{whole_disk}"]
    rdisk = "/dev/r" + whole_disk if whole_disk.startswith("disk") else ""
    devs = [rdisk, f"/dev/{whole_disk}"] if rdisk else [f"/dev/{whole_disk}"]
    last_rc, last_err, last_dev = "", "", ""

    for dev in devs:
        for cmd in (
            ["smartctl", "-a", "-j", "-d", "nvme", dev],
            ["smartctl", "-a", "-j", dev],
        ):
            rc, out, err = run(cmd)
            last_rc, last_err, last_dev = str(rc), err.strip(), dev
            txt = out.lstrip()
            if txt.startswith("{"):
                try:
                    return json.loads(txt), str(rc), err.strip(), dev
                except Exception:
                    continue

    return None, last_rc, last_err, last_dev


def smart_int(v: Any) -> Optional[int]:
    if v is None:
        return None
    if isinstance(v, bool):
        return int(v)
    if isinstance(v, (int, float)):
        return int(v)
    if isinstance(v, dict):
        for k in ("current", "value"):
            if k in v and isinstance(v[k], (int, float)):
                return int(v[k])
    if isinstance(v, str):
        s = v.strip().replace("%", "")
        if s.isdigit():
            return int(s)
    return None


def normalize_temp_c(temp: Optional[int]) -> Optional[int]:
    """
    Some tools may report Kelvin-ish values (e.g., 306). Convert if it looks like Kelvin.
    """
    if temp is None:
        return None
    if 200 <= temp <= 500:
        return temp - 273
    return temp


def data_units_to_tb(units: Optional[int]) -> Optional[float]:
    if units is None:
        return None
    return round(units * 512000 / 1e12, 3)


def find_nvme_log_anywhere(j: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """
    Robust: try known keys first, then recursively search for a dict that
    looks like NVMe SMART (has temperature + percentage_used or data_units_written).
    """
    # Known common key names
    for k in (
        "nvme_smart_health_information_log",
        "nvme_smart_health_information",
        "nvme_smart_health_log",
    ):
        v = j.get(k)
        if isinstance(v, dict):
            return v

    # Recursive search
    stack = [j]
    while stack:
        cur = stack.pop()
        if isinstance(cur, dict):
            keys = set(cur.keys())
            if ("temperature" in keys) and (("percentage_used" in keys) or ("data_units_written" in keys) or ("available_spare" in keys)):
                return cur
            for vv in cur.values():
                if isinstance(vv, (dict, list)):
                    stack.append(vv)
        elif isinstance(cur, list):
            for vv in cur:
                if isinstance(vv, (dict, list)):
                    stack.append(vv)
    return None


def extract_metrics(j: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    metrics: Dict[str, Any] = {
        "nvme_log_found": "",
        "smart_passed": "",
        "temp_c": "",
        "percent_used": "",
        "available_spare": "",
        "available_spare_threshold": "",
        "data_units_read": "",
        "data_units_written": "",
        "data_read_tb": "",
        "data_written_tb": "",
        "power_on_hours": "",
        "power_cycles": "",
        "unsafe_shutdowns": "",
        "media_errors": "",
        "num_err_log_entries": "",
        "warning_temp_time": "",
        "critical_comp_time": "",
        "smart_json": json.dumps(j, ensure_ascii=False, separators=(",", ":")) if j else "",
    }
    if not j:
        return metrics

    # overall status if present
    passed = j.get("smart_status", {}).get("passed") if isinstance(j.get("smart_status"), dict) else None
    if isinstance(passed, bool):
        metrics["smart_passed"] = "1" if passed else "0"

    log = find_nvme_log_anywhere(j)
    if not isinstance(log, dict):
        metrics["nvme_log_found"] = "0"
        return metrics
    metrics["nvme_log_found"] = "1"

    temp = normalize_temp_c(smart_int(log.get("temperature")))
    pct = smart_int(log.get("percentage_used"))
    sp = smart_int(log.get("available_spare"))
    spth = smart_int(log.get("available_spare_threshold"))

    dur = smart_int(log.get("data_units_read"))
    duw = smart_int(log.get("data_units_written"))

    poh = smart_int(log.get("power_on_hours"))
    pcy = smart_int(log.get("power_cycles"))
    us = smart_int(log.get("unsafe_shutdowns"))
    me = smart_int(log.get("media_errors"))
    ne = smart_int(log.get("num_err_log_entries"))
    wtt = smart_int(log.get("warning_temp_time"))
    cct = smart_int(log.get("critical_comp_time"))

    if temp is not None: metrics["temp_c"] = temp
    if pct is not None: metrics["percent_used"] = pct
    if sp is not None: metrics["available_spare"] = sp
    if spth is not None: metrics["available_spare_threshold"] = spth

    if dur is not None: metrics["data_units_read"] = dur
    if duw is not None: metrics["data_units_written"] = duw

    dr_tb = data_units_to_tb(dur)
    dw_tb = data_units_to_tb(duw)
    if dr_tb is not None: metrics["data_read_tb"] = dr_tb
    if dw_tb is not None: metrics["data_written_tb"] = dw_tb

    if poh is not None: metrics["power_on_hours"] = poh
    if pcy is not None: metrics["power_cycles"] = pcy
    if us is not None: metrics["unsafe_shutdowns"] = us
    if me is not None: metrics["media_errors"] = me
    if ne is not None: metrics["num_err_log_entries"] = ne
    if wtt is not None: metrics["warning_temp_time"] = wtt
    if cct is not None: metrics["critical_comp_time"] = cct

    return metrics


def ensure_csv_header(path: Path, fieldnames: list[str]) -> None:
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8-sig") as f:
        csv.DictWriter(f, fieldnames=fieldnames).writeheader()


def daily_csv_path(out_dir: Path, host: str, disk: str) -> Path:
    day = dt.datetime.now().strftime("%Y-%m-%d")
    safe_host = "".join(ch if ch.isalnum() or ch in ("-", "_") else "_" for ch in host)
    return out_dir / f"ssd_smart_{safe_host}_{disk}_{day}.csv"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default=str(Path.home() / "ssd_logs"))
    ap.add_argument("--interval", type=int, default=60)
    ap.add_argument("--once", action="store_true")
    args = ap.parse_args()

    out_dir = Path(args.out_dir).expanduser().resolve()
    host = get_host()
    os_ver = get_os_version()

    fieldnames = [
        "timestamp","host","os_version",
        "disk","device_node","internal","protocol","model","serial","firmware","smart_status",
        "smartctl_rc","smartctl_err","smartctl_devnode",
        "nvme_log_found","smart_passed","temp_c","percent_used","available_spare","available_spare_threshold",
        "data_units_read","data_units_written","data_read_tb","data_written_tb",
        "power_on_hours","power_cycles","unsafe_shutdowns","media_errors","num_err_log_entries",
        "warning_temp_time","critical_comp_time",
        "sample_interval_s","smart_json",
    ]

    def sample_once() -> None:
        disk = get_system_whole_disk().strip()
        du = parse_diskutil_info(disk)
        j, s_rc, s_err, s_dev = smartctl_json_nvme(disk)
        m = extract_metrics(j)

        m["smartctl_rc"] = s_rc
        m["smartctl_err"] = s_err
        m["smartctl_devnode"] = s_dev

        row: Dict[str, Any] = {k: "" for k in fieldnames}
        row.update({
            "timestamp": iso_ts(),
            "host": host,
            "os_version": os_ver,
            "sample_interval_s": args.interval,
        })
        row.update(du)
        row.update(m)

        csv_path = daily_csv_path(out_dir, host, disk)
        ensure_csv_header(csv_path, fieldnames)
        with csv_path.open("a", newline="", encoding="utf-8-sig") as f:
            csv.DictWriter(f, fieldnames=fieldnames).writerow(row)

        print(f"Wrote: {csv_path}")
        print(f"disk={disk}, nvme_log_found={row.get('nvme_log_found')}, temp_c={row.get('temp_c')}, percent_used={row.get('percent_used')}, written_tb={row.get('data_written_tb')}")
        if row.get("nvme_log_found") != "1":
            print("WARN: JSON exists but NVMe log not found. Check smart_json or smartctl output structure.")
        if row.get("smart_json","") == "":
            print("WARN: smartctl JSON is empty. Check sudo, smartctl path, /dev/rdisk access.")

    if args.once:
        sample_once()
        return

    while True:
        sample_once()
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
