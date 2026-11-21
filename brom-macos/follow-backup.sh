#!/bin/sh
# Auto-run after a successful BROM probe (FDL2 stays alive in RAM across
# processes). Generates the read_part plan from the just-dumped gpt.xml and
# reads every partition (resume-safe; skips the FDL2-unreadable NV family
# and junk partitions) into vendor/brom-work/backup/.
set -e
cd "$(dirname "$0")/../spd_dump-macos"
BK=../brom-work/backup
mkdir -p "$BK"
python3 scripts/backup_gen.py gpt.xml "$BK" \
  --skip nr_fixnv1_a,nr_fixnv1_b,blackbox,cache,sysdumpdb
echo "=== starting read_part sequence ==="
./spd_dump --wait 3 verbose 0 disable_transcode $(cat ../brom-work/backup_args.txt)
echo "=== BACKUP DONE ==="
ls -la "$BK" | tail -5
