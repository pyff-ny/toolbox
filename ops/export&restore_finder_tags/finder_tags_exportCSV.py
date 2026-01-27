#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
finder_tags_export_csv.py

Export macOS Finder tags (UserTags) to a CSV file by recursively scanning a directory.

Usage:
  python3 finder_tags_export_csv.py "/path/to/root" "/path/to/output.csv" --include-dirs

CSV columns:
  path, relative_path, name, is_dir, size_bytes, mtime_iso, tags, tag_colors

Notes:
- Finder tags are stored in extended attribute:
    com.apple.metadata:_kMDItemUserTags
- Values are a (binary) plist containing an array of strings:
    "TagName\n<colorIndex>" (colorIndex may be absent)
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import os
import plistlib
import subprocess
import sys
from pathlib import Path
from typing import List, Tuple, Optional


XATTR_KEY = "com.apple.metadata:_kMDItemUserTags"


def _read_xattr_bytes(path: Path, key: str) -> Optional[bytes]:
    """
    Try reading xattr via os.getxattr; fallback to `xattr -p`.
    Return None if not present.
    """
    # 1) os.getxattr
    try:
        getxattr = getattr(os, "getxattr", None)
        if callable(getxattr):
            return getxattr(str(path), key)
    except OSError:
        return None
    except Exception:
        # continue to fallback
        pass

    # 2) fallback: xattr -p
    try:
        # xattr -p prints raw bytes; but subprocess captures as bytes.
        # On some systems it may error if xattr not present.
        proc = subprocess.run(
            ["xattr", "-p", key, str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if proc.returncode != 0:
            return None
        return proc.stdout
    except FileNotFoundError:
        # xattr tool not found (unlikely on macOS)
        return None
    except Exception:
        return None


def parse_finder_tags(xattr_bytes: Optional[bytes]) -> Tuple[List[str], List[str]]:
    """
    Parse Finder tags from xattr bytes.
    Returns (tags, tag_colors)

    tags: ["Work", "Exam", ...]
    tag_colors: ["Work:3", "Exam:0", ...] (color index if present)
    """
    if not xattr_bytes:
        return [], []

    try:
        # xattr value is a plist (often binary plist)
        data = plistlib.loads(xattr_bytes)
    except Exception:
        # Some `xattr -p` outputs may include trailing newlines; try stripping.
        try:
            data = plistlib.loads(xattr_bytes.strip())
        except Exception:
            return [], []

    if not isinstance(data, list):
        return [], []

    tags: List[str] = []
    tag_colors: List[str] = []

    for item in data:
        if not isinstance(item, str) or not item:
            continue
        # Common format: "TagName\n3"
        parts = item.split("\n")
        tag = parts[0].strip()
        color = parts[1].strip() if len(parts) > 1 else ""
        if tag:
            tags.append(tag)
            if color:
                tag_colors.append(f"{tag}:{color}")
            else:
                tag_colors.append(f"{tag}:")
    return tags, tag_colors


def safe_stat(p: Path):
    try:
        return p.stat()
    except Exception:
        return None


def iso_mtime(st) -> str:
    try:
        return dt.datetime.fromtimestamp(st.st_mtime).isoformat(timespec="seconds")
    except Exception:
        return ""


def iter_paths(root: Path, include_dirs: bool, follow_symlinks: bool):
    """
    Yield files (and optionally dirs) under root.
    """
    # Use os.walk for speed and permission resilience
    for dirpath, dirnames, filenames in os.walk(root, followlinks=follow_symlinks):
        dp = Path(dirpath)

        if include_dirs:
            yield dp

        for fn in filenames:
            yield dp / fn


def main():
    parser = argparse.ArgumentParser(description="Export macOS Finder tags to CSV.")
    parser.add_argument("root", help="Root directory to scan")
    parser.add_argument("output_csv", help="Output CSV file path")
    parser.add_argument("--include-dirs", action="store_true", help="Include directories as rows")
    parser.add_argument("--follow-symlinks", action="store_true", help="Follow symlinks (default: no)")
    parser.add_argument("--relative", action="store_true", help="Write relative_path relative to root (recommended)")
    args = parser.parse_args()

    root = Path(args.root).expanduser().resolve()
    out_csv = Path(args.output_csv).expanduser().resolve()

    if not root.exists() or not root.is_dir():
        print(f"ERROR: root is not a directory: {root}", file=sys.stderr)
        sys.exit(1)

    out_csv.parent.mkdir(parents=True, exist_ok=True)

    with out_csv.open("w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "path",
                "relative_path",
                "name",
                "is_dir",
                "size_bytes",
                "mtime_iso",
                "tags",
                "tag_colors",
            ],
        )
        writer.writeheader()

        count = 0
        tagged = 0

        for p in iter_paths(root, include_dirs=args.include_dirs, follow_symlinks=args.follow_symlinks):
            st = safe_stat(p)
            if st is None:
                continue

            xbytes = _read_xattr_bytes(p, XATTR_KEY)
            tags, tag_colors = parse_finder_tags(xbytes)

            if tags:
                tagged += 1

            rel = ""
            if args.relative:
                try:
                    rel = str(p.relative_to(root))
                except Exception:
                    rel = ""

            writer.writerow(
                {
                    "path": str(p),
                    "relative_path": rel,
                    "name": p.name,
                    "is_dir": str(p.is_dir()),
                    "size_bytes": str(st.st_size),
                    "mtime_iso": iso_mtime(st),
                    "tags": ";".join(tags),
                    "tag_colors": ";".join(tag_colors),
                }
            )

            count += 1
            if count % 2000 == 0:
                print(f"Scanned {count} items... (tagged: {tagged})", file=sys.stderr)

    print(f"Done. Scanned: {count}, tagged: {tagged}", file=sys.stderr)
    print(f"CSV: {out_csv}", file=sys.stderr)


if __name__ == "__main__":
    main()
