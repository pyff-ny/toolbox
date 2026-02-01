#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
danger_ops.py
Reusable safety gates for ⚠️ operations:
- Safe directory validation (under allowed_root, reject / and ~)
- Finder reveal (macOS) for user visibility
- Strict two-step confirmation via /dev/tty: "YES" + token exact match
- Semantic deletion: delete only files matching a regex, excluding keep list
- Preview examples + optional dry-run

Designed for toolbox v2: wrappers/menus call into apps/core, and any destructive action
goes through this module.
"""

from __future__ import annotations

import os
import re
import sys
import subprocess
from dataclasses import dataclass
from typing import Iterable, List, Optional, Pattern, Sequence, Tuple


# -----------------------------
# Logging helpers
# -----------------------------
def log_info(msg: str) -> None:
    print(f"[INFO] {msg}")

def log_warn(msg: str) -> None:
    print(f"[WARN] {msg}")

def log_danger(msg: str) -> None:
    print(f"[DANGER] {msg}")

def log_done(msg: str) -> None:
    print(f"[完成] {msg}")


# -----------------------------
# Normalization
# -----------------------------
def _normalize_confirm(s: str) -> str:
    # Strip + remove common invisible chars (IME / copy-paste artifacts)
    s = s.strip()
    s = s.replace("\u3000", "")  # full-width space
    s = s.replace("\ufeff", "")  # BOM
    s = s.replace("\u200b", "")  # zero-width space
    s = s.replace("\u200c", "").replace("\u200d", "")
    return s


# -----------------------------
# Safe directory gate
# -----------------------------
def assert_safe_dir(path: str, *, allowed_root: str, label: str = "dir") -> str:
    """
    Ensure path is safe for destructive ops:
    - canonicalize (abspath+realpath)
    - reject "/" and "~"
    - require path under allowed_root (also canonicalized)
    Returns canonical path.
    """
    raw = path
    p = os.path.abspath(os.path.realpath(path))

    home = os.path.abspath(os.path.expanduser("~"))
    if p in ("/", home):
        raise RuntimeError(f"Refuse operation: unsafe {label}: {p} (raw={raw})")

    root = os.path.abspath(os.path.realpath(allowed_root))
    if not (p == root or p.startswith(root + os.sep)):
        raise RuntimeError(f"Refuse operation: {label} not under allowed_root: {p} (root={root}, raw={raw})")

    log_info(f"Safe {label} confirmed: {p} (raw={raw})")
    return p


# -----------------------------
# Finder reveal (macOS)
# -----------------------------
def reveal_in_finder(path: str) -> None:
    """
    macOS: open Finder and highlight the item.
    Safe no-op on other platforms.
    """
    abs_path = os.path.abspath(os.path.realpath(path))
    if sys.platform == "darwin" and os.path.exists(abs_path):
        # open -R reveals file in Finder
        subprocess.run(["open", "-R", abs_path], check=False)


# -----------------------------
# Strict confirmation gate
# -----------------------------
def confirm_yes_token(*, token: str, prompt: str) -> bool:
    """
    Strict two-step confirmation:
    1) must type EXACT 'YES' (uppercase)
    2) must type token EXACTLY
    Reads from /dev/tty to avoid pipe/redirect accidents.
    """
    if not sys.stdin.isatty():
        log_warn("Not a TTY; refuse confirmation (safety).")
        return False

    try:
        with open("/dev/tty", "r", encoding="utf-8", errors="ignore") as tty:
            log_danger(prompt)
            print("Type YES to confirm, then type the token exactly:")
            print(f"Token (copy/paste): {token}")

            ans1 = _normalize_confirm(tty.readline())
            if ans1 != "YES":
                log_info("Confirmation cancelled.")
                return False

            ans2 = _normalize_confirm(tty.readline())
            if ans2 != token:
                log_info("Confirmation cancelled (token mismatch).")
                return False

            return True
    except Exception as e:
        log_warn(f"Cannot read /dev/tty; refuse confirmation: {e}")
        return False


# -----------------------------
# Semantic selection + deletion
# -----------------------------
@dataclass(frozen=True)
class DeletePlan:
    base_dir: str
    victims: List[str]
    kept: List[str]
    pattern: str


def _canon(path: str) -> str:
    return os.path.abspath(os.path.realpath(path))


def build_delete_plan(
    base_dir: str,
    *,
    match: Pattern[str],
    keep_files: Sequence[str] = (),
    recursive: bool = False,
) -> DeletePlan:
    """
    Select deletable files in base_dir matching regex `match`,
    excluding any `keep_files` (compared by canonical path).
    """
    base_dir_c = _canon(base_dir)
    keep_set = {_canon(p) for p in keep_files if p}

    victims: List[str] = []
    kept: List[str] = sorted(list(keep_set))

    if recursive:
        for root, _, files in os.walk(base_dir_c):
            for fn in files:
                if not match.match(fn):
                    continue
                p = _canon(os.path.join(root, fn))
                if p in keep_set:
                    continue
                victims.append(p)
    else:
        for fn in os.listdir(base_dir_c):
            if not match.match(fn):
                continue
            p = _canon(os.path.join(base_dir_c, fn))
            if p in keep_set:
                continue
            victims.append(p)

    victims.sort()
    return DeletePlan(
        base_dir=base_dir_c,
        victims=victims,
        kept=kept,
        pattern=getattr(match, "pattern", str(match)),
    )


def preview_plan(plan: DeletePlan, *, examples: int = 3) -> None:
    log_warn(f"Cleanup requested. Will delete {len(plan.victims)} files (pattern={plan.pattern}).")
    for p in plan.victims[:max(0, examples)]:
        log_warn(f"Example: {os.path.basename(p)}")


def execute_delete_plan(plan: DeletePlan, *, dry_run: bool = False) -> int:
    """
    Delete files in plan.victims. Returns deleted count.
    """
    if dry_run:
        log_info("Dry-run enabled: no files will be deleted.")
        return 0

    deleted = 0
    for p in plan.victims:
        try:
            os.remove(p)
            deleted += 1
        except FileNotFoundError:
            continue
        except Exception as e:
            log_warn(f"Failed to delete: {p} ({e})")
    return deleted


# -----------------------------
# One-shot high-level helper
# -----------------------------
def guarded_semantic_cleanup(
    *,
    base_dir: str,
    allowed_root: str,
    match: Pattern[str],
    keep_files: Sequence[str],
    token: str,
    prompt: str,
    examples: int = 3,
    dry_run: bool = False,
    recursive: bool = False,
) -> int:
    """
    Full pipeline:
    1) assert safe dir
    2) build delete plan (semantic)
    3) preview examples
    4) strict confirm (YES + token)
    5) execute deletion
    Returns deleted count (0 if cancelled).
    """
    base_dir_safe = assert_safe_dir(base_dir, allowed_root=allowed_root, label="cleanup dir")

    plan = build_delete_plan(
        base_dir_safe,
        match=match,
        keep_files=keep_files,
        recursive=recursive,
    )

    preview_plan(plan, examples=examples)

    if len(plan.victims) == 0:
        log_info("Nothing to delete.")
        return 0

    if not confirm_yes_token(token=token, prompt=prompt):
        log_info("Cleanup skipped.")
        return 0

    deleted = execute_delete_plan(plan, dry_run=dry_run)
    return deleted
