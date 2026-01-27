#!/usr/bin/env python3
"""
restore_finder_tags_xattr.py
Restore macOS Finder Tags from a CSV exported by export_finder_tags_xattr.py

CSV columns expected:
  path,is_dir,tags
Where tags are separated by ';' (e.g. s:to-watch;g:crime;q:1080p)

Usage (replace existing tags with CSV):
  python3 restore_finder_tags_xattr.py ~/Desktop/finder_tags_export.csv

Dry run (no changes, just report):
  python3 restore_finder_tags_xattr.py ~/Desktop/finder_tags_export.csv --dry-run

Merge mode (add tags from CSV without removing existing ones):
  python3 restore_finder_tags_xattr.py ~/Desktop/finder_tags_export.csv --merge

Path remap (useful if your drive name changed after reinstall):
  python3 restore_finder_tags_xattr.py ~/Desktop/finder_tags_export.csv --path-replace "/Volumes/OldDrive" "/Volumes/NewDrive"
"""

import csv
import sys
import plistlib
import subprocess
from pathlib import Path

XATTR_KEY = "com.apple.metadata:_kMDItemUserTags"

def run_xattr(args: list[str]) -> bytes:
    return subprocess.check_output(args, stderr=subprocess.STDOUT)

def decode_finder_tags_from_raw(raw: bytes) -> list[str]:
    try:
        obj = plistlib.loads(raw)
        if not isinstance(obj, list):
            return []
        tags = []
        for item in obj:
            if isinstance(item, str):
                name = item.split("\n", 1)[0].strip()
                if name:
                    tags.append(name)
        # de-dup keep order
        seen = set()
        out = []
        for t in tags:
            if t not in seen:
                seen.add(t)
                out.append(t)
        return out
    except Exception:
        return []

def read_existing_tags(path: str) -> list[str]:
    # xattr -px prints hex; we convert back to bytes
    try:
        hex_bytes = run_xattr(["/usr/bin/xattr", "-px", XATTR_KEY, path])
    except Exception:
        return []
    hex_str = b"".join(hex_bytes.split()).decode("ascii", errors="ignore")
    if not hex_str:
        return []
    try:
        raw = bytes.fromhex(hex_str)
    except ValueError:
        return []
    return decode_finder_tags_from_raw(raw)

def write_tags(path: str, tags: list[str], dry_run: bool = False) -> None:
    # Finder stores tags as ["TagName\\n0", ...] where trailing number is color index.
    # We use 0 for all tags (keeps names; color is not important for most workflows).
    payload = [f"{t}\n0" for t in tags]
    raw = plistlib.dumps(payload, fmt=plistlib.FMT_BINARY)
    hex_str = raw.hex()

    if dry_run:
        return

    # xattr -wx <key> <hex> <file>
    subprocess.check_call(["/usr/bin/xattr", "-wx", XATTR_KEY, hex_str, path])

def parse_tags_field(tags_field: str) -> list[str]:
    if not tags_field:
        return []
    tags = [t.strip() for t in tags_field.split(";")]
    return [t for t in tags if t]

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 restore_finder_tags_xattr.py <csv_path> [--dry-run] [--merge] [--path-replace OLD NEW]")
        sys.exit(1)

    csv_path = Path(sys.argv[1]).expanduser().resolve()
    dry_run = "--dry-run" in sys.argv
    merge = "--merge" in sys.argv

    old_prefix = None
    new_prefix = None
    if "--path-replace" in sys.argv:
        i = sys.argv.index("--path-replace")
        try:
            old_prefix = sys.argv[i + 1]
            new_prefix = sys.argv[i + 2]
        except Exception:
            print("Error: --path-replace requires OLD and NEW strings.")
            sys.exit(1)

    if not csv_path.exists():
        print(f"Error: CSV not found: {csv_path}")
        sys.exit(1)

    total = 0
    changed = 0
    skipped_missing = 0
    failed = 0

    # utf-8-sig handles CSVs that may start with BOM
    with csv_path.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        required = {"path", "tags"}
        if not required.issubset(set(reader.fieldnames or [])):
            print(f"Error: CSV must contain columns: {sorted(required)}. Found: {reader.fieldnames}")
            sys.exit(1)

        for row in reader:
            total += 1
            p = (row.get("path") or "").strip()
            if not p:
                continue

            if old_prefix and new_prefix:
                if p.startswith(old_prefix):
                    p = new_prefix + p[len(old_prefix):]

            if not Path(p).exists():
                skipped_missing += 1
                continue

            csv_tags = parse_tags_field(row.get("tags", ""))

            # If CSV has empty tags, we still restore "empty" by clearing tags (replace mode).
            final_tags = csv_tags

            if merge:
                existing = read_existing_tags(p)
                # union (keep order: existing first, then new ones)
                seen = set(existing)
                final_tags = existing[:]
                for t in csv_tags:
                    if t not in seen:
                        seen.add(t)
                        final_tags.append(t)

            try:
                # Only count as "changed" if not dry-run and write succeeded
                # We'll still compare to show meaningful progress.
                before = read_existing_tags(p) if not dry_run else []
                if merge:
                    # in merge mode, write only if it would add something
                    if not dry_run and all(t in before for t in final_tags):
                        continue

                write_tags(p, final_tags, dry_run=dry_run)
                changed += 1
            except subprocess.CalledProcessError as e:
                failed += 1
                # Print a short error line (common causes: read-only filesystem, permission)
                msg = getattr(e, "output", b"").decode("utf-8", errors="ignore").strip()
                print(f"[FAIL] {p} :: {msg or str(e)}")

    print("\n=== Summary ===")
    print(f"CSV rows processed: {total}")
    print(f"Applied (or would apply): {changed}{' (dry-run)' if dry_run else ''}")
    print(f"Skipped missing paths: {skipped_missing}")
    print(f"Failed writes: {failed}")
    if failed:
        print("\nIf you see 'Read-only file system', your external drive may be NTFS or mounted read-only.")
        print("If you see permission errors, give Terminal Full Disk Access and try again.")

if __name__ == "__main__":
    main()

