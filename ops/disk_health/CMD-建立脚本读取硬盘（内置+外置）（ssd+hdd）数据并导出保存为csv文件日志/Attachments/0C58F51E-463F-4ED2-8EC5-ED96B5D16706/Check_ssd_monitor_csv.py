python3 - <<'PY‘
import glob, csv, os
files=sorted(glob.glob(os.path.expanduser('~/ssd_logs/ssd_smart_*.csv')))
f=files[-1]
with open(f, newline='', encoding='utf-8-sig') as fp:
    r=csv.DictReader(fp)
    last=None
    for last in r: pass
print("CSV:", f)
for k in ["disk","temp_c","percent_used","data_written_tb","power_on_hours","power_cycles","nvme_log_found"]:
    print(k, "=", last.get(k))
PY
