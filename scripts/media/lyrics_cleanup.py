#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
lyrics_cleanup.py
Clean SRT-like lyrics transcripts (index + timestamp + text).
Designed for Whisper/whisper.cpp outputs on music where hallucinations occur.

Usage:
  python3 lyrics_cleanup.py input.srt.txt -o cleaned.srt.txt
  python3 lyrics_cleanup.py input.srt.txt --inplace
  python3 lyrics_cleanup.py input.srt.txt -o cleaned.srt.txt --keep-index
"""

from __future__ import annotations
import argparse
import os
import re
import sys
from dataclasses import dataclass
from typing import List, Tuple


TIME_RE = re.compile(r"^\s*\d{2}:\d{2}:\d{2},\d{3}\s*-->\s*\d{2}:\d{2}:\d{2},\d{3}\s*$")

# Music / non-lyric markers (JP/EN common)
MUSIC_MARKERS = [
    "♪", "♪~", "♪～", "♩", "♫", "♬",
    "[音楽]", "（音楽）", "(music)", "[music]",
    "【音楽】", "【music】",
]

# Lines that are basically separators/noise
NOISE_ONLY_RE = re.compile(r"^[\s\-\_\=\~\.\,\!\?\[\]\(\)【】「」『』（）]+$")

# Kana ranges
KANA_RE = re.compile(r"[\u3040-\u309F\u30A0-\u30FF]")  # hiragana+katakana

# Long vowel mark "ー" and small tsu etc are included in kana block checks via explicit patterns
REPEAT_CHAR_RE = re.compile(r"(.)\1{9,}")  # any same char repeated 10+ times
REPEAT_WAWA_RE = re.compile(r"(わ|ワ|ﾜ|Wa|wa)([ー\-~ ]*\1){6,}", re.IGNORECASE)  # "わーわー..." many times
ALL_WA_RE = re.compile(r"^[\sわワﾜー\-~]+$")  # only wa and elongations

@dataclass
class Block:
    raw_index: str
    timestamp: str
    lines: List[str]  # text lines (1+)

def normalize_line(s: str) -> str:
    # Normalize some common whitespace
    return re.sub(r"[ \t]+", " ", s.strip())

def is_music_marker(line: str) -> bool:
    t = normalize_line(line)
    if not t:
        return True
    for m in MUSIC_MARKERS:
        if t == m:
            return True
    return False

def is_noise_only(line: str) -> bool:
    t = normalize_line(line)
    if not t:
        return True
    if NOISE_ONLY_RE.match(t):
        return True
    return False

def kana_ratio(s: str) -> float:
    if not s:
        return 0.0
    total = len(s)
    kana = len(KANA_RE.findall(s))
    return kana / max(total, 1)

def looks_like_vocalize_gibberish(text: str, *, wa_threshold: int = 12) -> bool:
    """
    Detect "わわわ..." or "わーわー..." or extreme repetition.
    """
    t = normalize_line(text)
    if not t:
        return True

    # Many repeated same character
    if REPEAT_CHAR_RE.search(t):
        return True

    # Common vocalize patterns
    if REPEAT_WAWA_RE.search(t):
        return True

    if ALL_WA_RE.match(t):
        # Count wa-like characters; if too many, drop
        wa_count = sum(1 for ch in t if ch in ("わ", "ワ", "ﾜ"))
        if wa_count >= wa_threshold:
            return True

    return False

def should_drop_block(block: Block, *, min_text_len: int = 2,
                      min_kana_ratio: float = 0.10,
                      drop_music_markers: bool = True,
                      drop_vocalize: bool = True) -> Tuple[bool, str]:
    """
    Decide to drop a block or keep it.
    Returns (drop?, reason).
    """
    # Join all lines for holistic checks
    joined = " ".join(normalize_line(x) for x in block.lines if normalize_line(x))
    joined = normalize_line(joined)

    if not joined or len(joined) < min_text_len:
        return True, "empty_or_too_short"

    # Drop explicit music markers and bracketed music notes
    if drop_music_markers:
        if all(is_music_marker(x) or is_noise_only(x) for x in block.lines):
            return True, "music_marker_only"
        if any(is_music_marker(x) for x in block.lines) and len(joined) <= 6:
            return True, "music_marker_short"

    # Drop pure noise lines (symbols only)
    if all(is_noise_only(x) for x in block.lines):
        return True, "noise_only"

    # Drop vocalize gibberish
    if drop_vocalize and looks_like_vocalize_gibberish(joined):
        return True, "vocalize_gibberish"

    # Optional: if it's almost no kana and has no letters, it might be garbage.
    # But keep English/romaji lines by allowing ASCII letters/digits
    has_ascii_letters = bool(re.search(r"[A-Za-z]", joined))
    if not has_ascii_letters:
        kr = kana_ratio(joined)
        # If kana ratio is extremely low, likely misfire (but keep kanji-only lines by checking CJK)
        has_cjk = bool(re.search(r"[\u4E00-\u9FFF]", joined))  # CJK Unified Ideographs (kanji)
        if not has_cjk and kr < min_kana_ratio:
            return True, f"low_kana_ratio({kr:.2f})"

    return False, "keep"

def parse_blocks(content: str) -> List[Block]:
    """
    Parse SRT-like blocks: index line, timestamp line, text lines, blank line.
    Works even if blank lines are inconsistent.
    """
    lines = content.splitlines()
    blocks: List[Block] = []
    i = 0
    n = len(lines)

    def skip_empty(k: int) -> int:
        while k < n and not lines[k].strip():
            k += 1
        return k

    i = skip_empty(i)
    while i < n:
        idx_line = lines[i].strip()
        # Index line may be missing; handle gracefully
        if idx_line.isdigit():
            raw_index = idx_line
            i += 1
        else:
            raw_index = ""  # no index
        i = skip_empty(i)
        if i >= n:
            break

        ts_line = lines[i].strip()
        if not TIME_RE.match(ts_line):
            # Not a valid timestamp; attempt to resync by searching forward
            # Treat current line as text and try to find next timestamp
            # This is defensive; your outputs are usually well-formed.
            # We'll bail out by stopping parse.
            break

        timestamp = ts_line
        i += 1

        # Collect text lines until blank line or next index+timestamp
        text_lines: List[str] = []
        while i < n:
            if not lines[i].strip():
                break
            # Stop if next looks like an index and following line is a timestamp
            if lines[i].strip().isdigit() and (i + 1) < n and TIME_RE.match(lines[i + 1].strip()):
                break
            text_lines.append(lines[i].rstrip("\n"))
            i += 1

        if not text_lines:
            text_lines = [""]  # keep structure; will be dropped by cleaner

        blocks.append(Block(raw_index=raw_index, timestamp=timestamp, lines=text_lines))
        i = skip_empty(i + 1)

    return blocks

def format_blocks(blocks: List[Block], *, renumber: bool = True) -> str:
    out_lines: List[str] = []
    idx = 1
    for b in blocks:
        if renumber:
            out_lines.append(str(idx))
            idx += 1
        else:
            out_lines.append(b.raw_index if b.raw_index else str(idx))
            idx += 1
        out_lines.append(b.timestamp)
        for ln in b.lines:
            out_lines.append(normalize_line(ln))
        out_lines.append("")  # blank line between blocks
    return "\n".join(out_lines).rstrip() + "\n"

# Optional: output plain lyrics text without indices/timestamps
def format_plain(blocks: List[Block]) -> str:
    out_lines: List[str] = []
    for b in blocks:
        # 把该块所有行合并成一句，再做 normalize
        joined = " ".join(normalize_line(x) for x in b.lines if normalize_line(x))
        joined = normalize_line(joined)
        if not joined:
            continue
        out_lines.append(joined)
        out_lines.append("")  # 段落分隔
    return "\n".join(out_lines).rstrip() + "\n"

def main() -> int:
    ap = argparse.ArgumentParser(description="Clean SRT-like lyrics transcripts (remove music markers / vocalize gibberish).")
    ap.add_argument("input", help="Input SRT-like text file")
    ap.add_argument("-o", "--output", help="Output file path (default: <input>.cleaned.txt)")
    ap.add_argument("--inplace", action="store_true", help="Overwrite input file in place (writes a .bak backup)")
    ap.add_argument("--keep-index", action="store_true", help="Keep original indices (no renumber)")
    ap.add_argument("--min-text-len", type=int, default=2, help="Drop blocks shorter than this (default: 2)")
    ap.add_argument("--min-kana-ratio", type=float, default=0.10, help="Drop blocks with very low kana ratio (default: 0.10)")
    ap.add_argument("--no-drop-vocalize", action="store_true", help="Do not drop 'わわわ/わーわー' style vocalize blocks")
    ap.add_argument("--no-drop-music", action="store_true", help="Do not drop music marker blocks like ♪~, [音楽]")
    ap.add_argument("--write-dropped", action="store_true", help="Write dropped blocks to <output>.dropped.txt for review")
    ap.add_argument("--plain", action="store_true",
                help="Output plain lyrics text (no index/timestamps)")
    args = ap.parse_args()

    in_path = args.input
    if not os.path.isfile(in_path):
        print(f"[ERROR] input not found: {in_path}", file=sys.stderr)
        return 2

    with open(in_path, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()

    blocks = parse_blocks(content)
    if not blocks:
        print("[ERROR] no blocks parsed (unexpected format)", file=sys.stderr)
        return 2

    kept: List[Block] = []
    dropped: List[Tuple[Block, str]] = []

    for b in blocks:
        drop, reason = should_drop_block(
            b,
            min_text_len=args.min_text_len,
            min_kana_ratio=args.min_kana_ratio,
            drop_music_markers=not args.no_drop_music,
            drop_vocalize=not args.no_drop_vocalize,
        )
        if drop:
            dropped.append((b, reason))
        else:
            kept.append(b)

    renumber = not args.keep_index
    cleaned_text = format_plain(kept) if args.plain else format_blocks(kept, renumber=renumber)

    if args.inplace:
        bak = in_path + ".bak"
        if not os.path.exists(bak):
            os.rename(in_path, bak)
        else:
            # If bak exists, don't clobber it; make a numbered backup
            k = 1
            while True:
                bak2 = f"{bak}.{k}"
                if not os.path.exists(bak2):
                    os.rename(in_path, bak2)
                    break
                k += 1
        out_path = in_path
    else:
        out_path = args.output or (in_path + ".cleaned.txt")

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(cleaned_text)

    print(f"[OK] cleaned blocks: {len(kept)} / {len(blocks)}")
    print(f"[OK] output: {out_path}")

    if args.write_dropped:
        drop_path = out_path + ".dropped.txt"
        with open(drop_path, "w", encoding="utf-8") as f:
            for (b, reason) in dropped:
                f.write(f"# reason={reason}\n")
                if b.raw_index:
                    f.write(b.raw_index + "\n")
                f.write(b.timestamp + "\n")
                for ln in b.lines:
                    f.write(ln + "\n")
                f.write("\n")
        print(f"[OK] dropped log: {drop_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
