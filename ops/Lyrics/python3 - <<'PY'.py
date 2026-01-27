python3 - <<'PY'
import re, pathlib

src = pathlib.Path("lyrics.en.srt.txt")
dst = pathlib.Path("lyrics.en.txt")

lines = src.read_text(encoding="utf-8", errors="ignore").splitlines()

out = []
for line in lines:
    s = line.strip()
    if not s:
        continue
    # skip index lines like "1"
    if re.fullmatch(r"\d+", s):
        continue
    # skip timestamp lines
    if re.fullmatch(r"\d\d:\d\d:\d\d,\d{3}\s*-->\s*\d\d:\d\d:\d\d,\d{3}", s):
        continue
    out.append(s)

# optional: collapse repeated identical adjacent lines
clean = []
prev = None
for s in out:
    if s != prev:
        clean.append(s)
    prev = s

dst.write_text("\n".join(clean).strip() + "\n", encoding="utf-8")
print(f"Wrote: {dst}")
PY
