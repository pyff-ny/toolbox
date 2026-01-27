
## English Final README (save as `~/Ops/README_EN.md` or replace `~/Ops/README.md`)

```md
# Ops Mini Portfolio (macOS)

This folder contains two small ops-style projects I built on macOS for hands-on IT experience:

1) Disk Health Check  
2) Rsync Backup over SSH

---

## Project 1: Disk Health Check

### Goal
- Enumerate physical disks (internal/external)
- Run disk health checks and produce auditable artifacts: logs, reports, raw evidence
- Parse SMART/NVMe metrics for internal SSDs when supported (e.g., temperature, unsafe shutdowns, percentage used)
- For external HDDs, clearly report `UNSUPPORTED` when USB bridges block SMART passthrough (no guesswork)

### Paths
- Project: `~/Ops/disk-health/`
- Script: `~/Ops/disk-health/bin/check_disk_health.sh`
- Docs: `~/Ops/disk-health/docs/README.md`
- Logs: `~/Ops/disk-health/logs/`
- Reports: `~/Ops/disk-health/reports/`
- Evidence: `~/Ops/disk-health/logs/smartctl_*_*.out` (raw smartctl output)

### Quick Usage
```bash
~/Ops/disk-health/bin/check_disk_health.sh --list
~/Ops/disk-health/bin/check_disk_health.sh
~/Ops/disk-health/bin/check_disk_health.sh --device /dev/disk0


---
```
# Project 2: Rsync Backup over SSH
## Goal
* Back up MacBook data to an iMac external drive via SSH + rsync
* Support dry-run review, exclusions for speed, and safe delete/overwrite protection via --backup-dir
* Keep timestamped logs for auditing and troubleshooting
## Paths
* Project: ~/Ops/rsync-backup/
* Script: ~/Ops/rsync-backup/bin/rsync_backup.sh
* Config: ~/Ops/rsync-backup/conf/
* Docs: ~/Ops/rsync-backup/docs/README.md
* Logs: ~/Ops/rsync-backup/logs/

## Quick Usage
```bash
~/Ops/rsync-backup/bin/rsync_backup.sh --dry-run
~/Ops/rsync-backup/bin/rsync_backup.sh
```
## Recommended Final SUMMARY Line (tool-style output)
```bash
SUMMARY | status=<OK/WARN/ERROR> | code=<0/24/23/...> | dry_run=<true/false> | transferred=<MB> | reg_xfer=<N> | created=<N> | deleted=<N> | elapsed=<HH:MM:SS> | remote=<user@host> | trash=<path or N/A> | log=<rsync_backup_*.log>

```
# Example Output (Interview-ready)
## Disk Health Check (External SMART passthrough blocked)
```bash
## Summary
- Status: UNSUPPORTED (SMART passthrough unavailable via USB bridge)
- Device: /dev/diskX (external, physical)
- Checked on: 2026-01-12
```
## Notes:
* This is a common USB bridge limitation: file access works, but SMART metrics (temperature, sectors, power-on hours, etc.) are not exposed to macOS.
* Mitigation: keep evidence logs; use file-level integrity checks (hash/rsync verification) or switch to a SMART-capable enclosure/host.

# Rsync Backup (Real run incremental sync example)
```bash
Number of files: 85,862 (reg: 75,088, dir: 9,861, link: 912, special: 1)
Number of created files: 11 (reg: 11)
Number of deleted files: 10 (reg: 8, dir: 2)
Number of regular files transferred: 151
Total file size: 12.73G bytes
Total transferred file size: 63.84M bytes
Literal data: 25.42M bytes
Matched data: 38.44M bytes
Total bytes sent: 29.04M
Total bytes received: 235.01K
total size is 12.73G  speedup is 434.83
```
## Key takeaways:
* Incremental sync: out of a 12.73G dataset, only 63.84MB needed transferring.
* Small, controlled changes: 11 creates and 10 deletes, keeping a clean mirror.
* Matched data indicates rsync avoided re-sending unchanged blocks, improving efficiency (speedup=434.83).


# 30-second interview pitch
## I built two ops-style mini projects on macOS:
* (1) a disk health checker that enumerates internal/external physical disks, generates logs/reports/raw evidence, parses internal SSD SMART metrics when available, and clearly reports UNSUPPORTED when external USB bridges block SMART passthrough;
* (2) an rsync+SSH backup workflow with dry-run review, safe delete/overwrite protection via backup-dir, speed optimizations via exclusions, and auditable logs—resulting in a repeatable, traceable backup process.