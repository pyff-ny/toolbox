# Auto pipeline (VAD-free version with multiple detection modes):
# Modes:
#   auto  - ffmpeg silencedetect (default)
#   fixed - fixed interval slicing (e.g., every 10s)
#   hybrid- try silence first, fallback to fixed if too few segments
#
# Usage:
#   # MODE: auto|fixed|hybrid   (default: hybrid)
#   ./lyrics_auto_no_vad.sh "/path/to/song.m4a" ja [mode] [interval]
#   ./lyrics_auto_no_vad.sh "song.m4a" ja auto
#   ./lyrics_auto_no_vad.sh "song.m4a" ja fixed 10
#   ./lyrics_auto_no_vad.sh "song.m4a" ja hybrid 15
#
# Output:
#   ./lyrics_<songname>.ja.srt.txt
#   Workdir: ~/toolbox/Lyrics/work_lyrics_<songname>/
# Requirements:
#   ffmpeg, ffprobe, python3, whisper-cli (whisper-cpp)
#!/usr/bin/env bash
set -Eeuo pipefail

# --- Load libs ---
TOOLBOX_DIR="${TOOLBOX_DIR:-$HOME/toolbox}"
LIB_DIR="$TOOLBOX_DIR/scripts/_lib"

# shellcheck source=/dev/null
source "$TOOLBOX_DIR/_lib/rules.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/std.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/log.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/ux.sh"

# --- Script metadata ---
SCRIPT_TITLE="Lyrics Auto (No VAD)"
RUN_TS="$(std_now_ts)"

trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

normalize_drag_path() {
  local p="${1-}"
  p="$(trim "$p")"
  p="${p%\"}"; p="${p#\"}"
  p="${p%\'}"; p="${p#\'}"
  p="${p//\\ / }"          # "\ " -> " "
  p="${p#file://}"
  printf "%s" "$p"
}

read_audio_path_drag() {
  local pick_dir="${1-}"
  [[ -d "$pick_dir" ]] || die "AUDIO_PICK_DIR not found: $pick_dir"

  open "$pick_dir" >/dev/null 2>&1 || true
  printf "Audio file path (drag here): " >/dev/tty

  local raw=""
  IFS= read -r raw </dev/tty || return 1
  raw="$(normalize_drag_path "$raw")"
  [[ -n "$raw" ]] || return 1
  printf "%s" "$raw"
}

# 交互：音频/语言（只问一次）
# ---- Resolve input (CLI first, fallback to interactive) ----
AUDIO_PICK_DIR="${AUDIO_PICK_DIR:-$HOME/Music/Music}"

IN="${1-}"
if [[ -n "$IN" ]]; then
  IN="$(ux_normalize_path "$IN")"
else
  IN="$(ux_pick_file_drag "Audio file path (drag here): " 1 "$AUDIO_PICK_DIR")" || exit $?
fi

LANG_OUT="${2-}"
if [[ -z "$LANG_OUT" ]]; then
  LANG_OUT="$(ux_read_tty "Lang (en|ja|zh) (default: en): " "en" 0)" || exit $?
fi

normalize_interval() {
  # normalize_interval <interval>
  # Output: normalized interval string
  # Exit: 2 on invalid interval
  local in="${1-}"

  # trim spaces
  while [[ "$in" == " "* ]]; do in="${in# }"; done
  while [[ "$in" == *" " ]]; do in="${in% }"; done

  if ! [[ "$in" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    err "Invalid INTERVAL: '${1-}'. Must be a positive number."
    return 2
  fi

  printf "%s" "$in"
}

# Optional CLI override for mode/interval (no prompt)
MODE="${3-hybrid}"
INTERVAL="${4-12}"


MODE="$(normalize_mode "$MODE")"
INTERVAL="$(normalize_interval "$INTERVAL")" || die "Invalid INTERVAL: $INTERVAL"

case "$LANG_OUT" in en|ja|zh) ;; *) die "Unsupported LANG_OUT: $LANG_OUT" ;; esac

# --- Output dirs (single source of truth) ---
LYRICS_DIR="${LYRICS_DIR:-$TOOLBOX_DIR/_out/Lyrics}"
mkdir -p "$LYRICS_DIR"

BASE="$(basename "$IN")"
NAME="${BASE%.*}"
WORK_DIR="${WORK_DIR:-$LYRICS_DIR/work_lyrics_${NAME}}"
mkdir -p "$WORK_DIR/wav" "$WORK_DIR/txt"

# --- Print header (AFTER args resolved) ---
std_print_header
std_kv "RUN_ID"   "$RUN_TS"
std_kv "Input"    "$IN"
std_kv "Lang"     "$LANG_OUT"
std_kv "Mode"     "$MODE"
std_kv "Interval" "$INTERVAL"
std_kv "Workdir"  "$WORK_DIR"
echo

# optional CLI override for mode/interval (no prompt)
MODE="${3:-$MODE}"
INTERVAL="${4:-$INTERVAL}"


# --- Config ---
LANG_OUT="${LANG_OUT:-en}"  # default to English output
WHISPER_CLI="$(command -v whisper-cli 2>/dev/null || true)"
if [[ -z "$WHISPER_CLI" ]]; then
  WHISPER_CLI="/opt/homebrew/Cellar/whisper-cpp/1.8.3/bin/whisper-cli"
fi
[[ -x "$WHISPER_CLI" ]] || die "whisper-cli not found. Install whisper-cpp or add whisper-cli to PATH."

MODEL="${MODEL:-/opt/homebrew/share/whisper-cpp/models/ggml-small.bin}"
[[ -f "$MODEL" ]] || die "Model not found: $MODEL"

case "$LANG_OUT" in
  en|ja|zh) ;;
  *) die "Unsupported LANG_OUT: $LANG_OUT (use en/ja/zh)" ;;
esac

# Silence detection parameters (for auto/hybrid modes)
SILENCE_THRESHOLD="-35dB"  # more sensitive for music with continuous background
SILENCE_DURATION="0.8"     # longer silence required
MIN_SEGMENT_DUR="2.0"      # minimum speech segment (ignore very short)
MAX_SEGMENT_GAP="1.5"      # merge segments closer than this
MIN_SEGMENTS=3             # if fewer, switch to fixed (hybrid mode)

command -v ffmpeg  >/dev/null 2>&1 || die "ffmpeg not found"
command -v ffprobe >/dev/null 2>&1 || die "ffprobe not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"


# Save meta info
cat > "$WORK_DIR/meta.txt" <<EOF
title=
artist=
lang=$LANG_OUT
source=$IN
mode_used=$MODE
interval=$INTERVAL
model=$MODEL
generated_at=$(date -I)
EOF

# --- Preprocess: convert to mono 16kHz WAV ---
FULL_WAV="${WORK_DIR}/${NAME}.full.wav"
ffmpeg -y -hide_banner -loglevel error \
  -i "$IN" -ar 16000 -ac 1 "$FULL_WAV"

# Get total duration
TOTAL_DUR=$(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 "$FULL_WAV")

SEG="${WORK_DIR}/segments.tsv"

# ---- Segmentation Strategy ----
segment_by_silence() {
  echo "🔍 Mode: Silence detection (threshold: ${SILENCE_THRESHOLD})"
  SILENCE_LOG="${WORK_DIR}/silence.txt"
  
  ffmpeg -i "$FULL_WAV" -af "silencedetect=noise=${SILENCE_THRESHOLD}:d=${SILENCE_DURATION}" \
    -f null - 2>&1 | grep -E "silence_(start|end)" > "$SILENCE_LOG" || true

  if [[ ! -s "$SILENCE_LOG" ]]; then
    echo "⚠️  No silence detected"
    return 1
  fi

  python3 - <<'PY' "$SILENCE_LOG" "$SEG" "$TOTAL_DUR" "$MIN_SEGMENT_DUR" "$MAX_SEGMENT_GAP"
import re, sys

silence_log = open(sys.argv[1]).read()
out_file = sys.argv[2]
total_dur = float(sys.argv[3])
min_dur = float(sys.argv[4])
max_gap = float(sys.argv[5])

silence_starts = []
silence_ends = []

for line in silence_log.splitlines():
    if "silence_start:" in line:
        match = re.search(r"silence_start:\s*([\d.]+)", line)
        if match:
            silence_starts.append(float(match.group(1)))
    elif "silence_end:" in line:
        match = re.search(r"silence_end:\s*([\d.]+)", line)
        if match:
            silence_ends.append(float(match.group(1)))

segments = []
last_end = 0.0

for i in range(len(silence_starts)):
    speech_start = last_end
    speech_end = silence_starts[i]
    
    if speech_end > speech_start and (speech_end - speech_start) >= min_dur:
        segments.append((speech_start, speech_end))
    
    if i < len(silence_ends):
        last_end = silence_ends[i]

if last_end < total_dur and (total_dur - last_end) >= min_dur:
    segments.append((last_end, total_dur))

# Merge close segments
merged = []
for s, e in segments:
    if not merged:
        merged.append([s, e])
        continue
    ps, pe = merged[-1]
    if s - pe < max_gap:
        merged[-1][1] = max(pe, e)
    else:
        merged.append([s, e])

with open(out_file, 'w') as f:
    for s, e in merged:
        f.write(f"{s:.3f}\t{e:.3f}\n")

print(f"Found {len(merged)} segments via silence detection")
sys.exit(0 if len(merged) > 0 else 1)
PY
  return $?
}

segment_by_fixed_interval() {
  local interval=$1
  echo "📏 Mode: Fixed interval (every ${interval}s)"
  
  python3 - <<PY "$SEG" "$TOTAL_DUR" "$interval"
import sys
out_file = sys.argv[1]
total = float(sys.argv[2])
interval = float(sys.argv[3])

segments = []
start = 0.0
while start < total:
    end = min(start + interval, total)
    if end - start >= 1.0:  # skip segments shorter than 1s
        segments.append((start, end))
    start = end

with open(out_file, 'w') as f:
    for s, e in segments:
        f.write(f"{s:.3f}\t{e:.3f}\n")

print(f"Created {len(segments)} segments of ~{interval}s each")

PY
}

read_tty() {
  local prompt="${1-}"
  local out=""
  printf "%s" "$prompt" >/dev/tty
  IFS= read -r out </dev/tty || return 1
  printf "%s" "$out"
}

normalize_mode() {
  local m="${1-}"
  m="$(trim "$m")"
  m="${m,,}"
  m="${m#:}"
  printf "%s" "$m"
}

normalize_interval() {
  local x="${1-}"
  x="$(trim "$x")"
  x="${x#:}"
  [[ "$x" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  printf "%s" "$x"
}

MODE="$(normalize_mode "${MODE:-hybrid}")"
INTERVAL="$(normalize_interval "${INTERVAL:-12}")" || die "Invalid INTERVAL: ${INTERVAL-}"

# Execute segmentation based on mode
case "$MODE" in
  auto)
    if ! segment_by_silence; then
      echo "❌ Silence detection failed. Try 'fixed' or 'hybrid' mode."
      exit 3
    fi
    ;;
  fixed)
    segment_by_fixed_interval "$INTERVAL"
    ;;
  hybrid)
    if segment_by_silence; then
      NUM_SEGS=$(wc -l < "$SEG")
      if [[ $NUM_SEGS -lt $MIN_SEGMENTS ]]; then
        echo "⚠️  Only $NUM_SEGS segments found, switching to fixed interval"
        segment_by_fixed_interval "$INTERVAL"
      fi
    else
      echo "⚠️  Silence detection failed, using fixed interval"
      segment_by_fixed_interval "$INTERVAL"
    fi
    ;;
  *)
    echo "Unknown mode: $MODE (use auto|fixed|hybrid)"
    exit 1
    ;;
esac

if [[ ! -s "$SEG" ]]; then
  echo "❌ No segments created"
  exit 3
fi

# Helper: sec -> SRT timestamp
sec_to_srt() {
  python3 - "$1" <<'PY'
import sys, math
t=float(sys.argv[1])
if t < 0: t = 0.0

hh = int(t // 3600); t -= hh*3600
mm = int(t // 60);   t -= mm*60
ss = int(t);         t -= ss
ms = int(round(t*1000))

# handle rounding overflow
if ms >= 1000:
    ss += 1
    ms -= 1000
if ss >= 60:
    mm += 1
    ss -= 60
if mm >= 60:
    hh += 1
    mm -= 60

print(f"{hh:02d}:{mm:02d}:{ss:02d},{ms:03d}")
PY
}


# ---- Slice + transcribe ----
echo "🎵 Transcribing segments..."
MERGED="${WORK_DIR}/lyrics.${LANG_OUT}.srt.txt"
: > "$MERGED"

i=0
total_segs=$(wc -l < "$SEG")

while IFS=$'\t' read -r S E; do
  i=$((i+1))
  echo -ne "  [$i/$total_segs] "
  
DUR="$(python3 - <<'PY' "$S" "$E"
import sys
s=float(sys.argv[1]); e=float(sys.argv[2])
print(f"{e-s:.3f}")
PY
)"

  SEG_WAV="${WORK_DIR}/wav/seg_${i}.wav"
  SEG_TXT="${WORK_DIR}/txt/seg_${i}.txt"

  ffmpeg -nostdin -y -hide_banner -loglevel error \
    -i "$FULL_WAV" -ss "$S" -t "$DUR" -ar 16000 -ac 1 "$SEG_WAV"

  "$WHISPER_CLI" -m "$MODEL" -l "$LANG_OUT" -f "$SEG_WAV" -nt > "$SEG_TXT" 2>&1 || true

  # Extract clean text (remove timestamps, keep only lyrics)
  CLEAN="$(python3 - <<'PY' "$SEG_TXT"
import sys, re
txt=open(sys.argv[1],encoding="utf-8",errors="ignore").read().splitlines()
out=[]
for line in txt:
    l=line.strip()
    if not l: 
        continue
    # Drop logs (be more specific to avoid filtering lyrics)
    if any(l.lower().startswith(k) for k in ["whisper_", "ggml_", "main:", "system_info:"]):
        continue
    if any(k in l.lower() for k in ["loading model", "gpu device", "metal total size", "model size", "processing", "print_timings", "fallbacks", "deallocating"]):
        continue
    
    # Remove timestamps from line: [00:00:00.000 --> 00:00:05.000]
    l_no_ts = re.sub(r'\[\d\d:\d\d:\d\d\.\d+ --> \d\d:\d\d:\d\d\.\d+\]\s*', '', l)
    l_no_ts = l_no_ts.strip()
    
    if not l_no_ts:
        continue
    
    # Keep lines with letters (for English) or CJK (for Asian languages) or music symbols
    if re.search(r'[a-zA-Z\u3040-\u30ff\u4e00-\u9fff\uac00-\ud7af♪~]', l_no_ts):
        out.append(l_no_ts)

if not out:
    # Fallback: take last non-empty, non-log lines
    for line in txt[-15:]:
        l=line.strip()
        if l and not any(k in l.lower() for k in ["whisper_", "load", "model", "error:", "init", "ggml", "metal", "timings"]):
            l_clean = re.sub(r'\[.*?\]', '', l).strip()
            if l_clean and len(l_clean) > 3:
                out.append(l_clean)
                
print(" ".join(out))
PY
)"

  START_SRT="$(sec_to_srt "$S")"
  END_SRT="$(sec_to_srt "$E")"

  {
    echo "$i"
    echo "${START_SRT} --> ${END_SRT}"
    echo "${CLEAN:-[音楽] }"
    echo
  } >> "$MERGED"
  
  echo "✓"
done < "$SEG"

OUT="$LYRICS_DIR/lyrics_${NAME}.${LANG_OUT}.srt.txt"
cp "$MERGED" "$OUT"

ux_tip "Tips" \
  "hybrid mode with different interval: $0 \"$IN\" $LANG_OUT hybrid 8" \
  "fixed mode for consistent segments:  $0 \"$IN\" $LANG_OUT fixed 10" \
  "Adjust SILENCE_THRESHOLD (-25dB ~ -40dB) for auto mode"

echo ""
log_info "LOCALLY"  " Mode:  $MODE"
log_info "LOCALLY"  "  Segments: $i"
log_info "LOCALLY"  "  Output:   $OUT"
log_info "LOCALLY"  "  Workdir:  $WORK_DIR"

echo ""


ux_open_after "$OUT" "Lyrics output"
std_footer_summary