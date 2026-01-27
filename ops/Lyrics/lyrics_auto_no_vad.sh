#!/usr/bin/env bash
set -euo pipefail

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

IN="${1:?audio file required}"
LANG="${2:-ja}"
MODE="${3:-hybrid}"      # auto|fixed|hybrid
INTERVAL="${4:-12}"      # for fixed/hybrid mode (seconds)

# --- Config ---

WHISPER_CLI="$(command -v whisper-cli 2>/dev/null || true)"
if [[ -z "$WHISPER_CLI" ]]; then
  WHISPER_CLI="/opt/homebrew/Cellar/whisper-cpp/1.8.3/bin/whisper-cli"
fi
[[ -x "$WHISPER_CLI" ]] || die "whisper-cli not found. Install whisper-cpp or add whisper-cli to PATH."

MODEL="${MODEL:-/opt/homebrew/share/whisper-cpp/models/ggml-small.bin}"
[[ -f "$MODEL" ]] || die "Model not found: $MODEL"

# Silence detection parameters (for auto/hybrid modes)
SILENCE_THRESHOLD="-35dB"  # more sensitive for music with continuous background
SILENCE_DURATION="0.8"     # longer silence required
MIN_SEGMENT_DUR="2.0"      # minimum speech segment (ignore very short)
MAX_SEGMENT_GAP="1.5"      # merge segments closer than this
MIN_SEGMENTS=3             # if fewer, switch to fixed (hybrid mode)

command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg not found"; exit 127; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found"; exit 127; }
[[ -x "$WHISPER_CLI" ]] || { echo "whisper-cli not executable: $WHISPER_CLI"; exit 127; }
[[ -f "$MODEL" ]] || { echo "model not found: $MODEL"; exit 2; }
[[ -f "$IN" ]] || { echo "audio not found: $IN"; exit 2; }

BASE="$(basename "$IN")"
NAME="${BASE%.*}"
WORK="/Users/jiali/toolbox/Lyrics/work_lyrics_${NAME}"
mkdir -p "$WORK"/{wav,txt}

cat > "$WORK/meta.txt" <<EOF
title=Young and Beautiful
artist=Lana Del Rey
lang=$LANG
source=$IN
mode_used=$MODE
interval=$INTERVAL
model=$MODEL
generated_at=$(date -I)
EOF



FULL_WAV="${WORK}/${NAME}.full.wav"
ffmpeg -y -hide_banner -loglevel error \
  -i "$IN" -ar 16000 -ac 1 "$FULL_WAV"

# Get total duration
TOTAL_DUR=$(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 "$FULL_WAV")

SEG="${WORK}/segments.tsv"

# ---- Segmentation Strategy ----
segment_by_silence() {
  echo "🔍 Mode: Silence detection (threshold: ${SILENCE_THRESHOLD})"
  SILENCE_LOG="${WORK}/silence.txt"
  
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

print(f"Created {len(segments)} segments of ~${interval}s each")
PY
}

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
MERGED="${WORK}/lyrics.en.srt.txt"
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

  SEG_WAV="${WORK}/wav/seg_${i}.wav"
  SEG_TXT="${WORK}/txt/seg_${i}.txt"

  ffmpeg -y -hide_banner -loglevel error \
    -i "$FULL_WAV" -ss "$S" -t "$DUR" -ar 16000 -ac 1 "$SEG_WAV"

  "$WHISPER_CLI" -m "$MODEL" -l "$LANG" -f "$SEG_WAV" -nt > "$SEG_TXT" 2>&1 || true

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

OUT="/Users/jiali/toolbox/Lyrics/lyrics_${NAME}.${LANG}.srt.txt"
cp "$MERGED" "$OUT"

echo ""
echo "✅ Done!"
echo "  Mode:     $MODE"
echo "  Segments: $i"
echo "  Output:   $OUT"
echo "  Workdir:  $WORK"
echo ""
echo "💡 Tips:"
echo "  Better results? Try:"
echo "    - hybrid mode with different interval: $0 \"$IN\" $LANG hybrid 8"
echo "    - fixed mode for consistent segments: $0 \"$IN\" $LANG fixed 10"
echo "    - Adjust SILENCE_THRESHOLD (-25dB ~ -40dB) in script for auto mode"

