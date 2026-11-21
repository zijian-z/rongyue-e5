#!/bin/sh
# Auto-run after a fresh successful BROM probe (FDL2 alive).
# Writes the official-mod V4 images (28 partitions incl. super last),
# erases runtimenv/userdata, then resets the device into the modded ROM.
# Runs from vendor/ (ops file paths are relative to vendor/).
set -e
cd "$(dirname "$0")/.."
N=$(grep -c 'write_part\|erase_part' brom-work/flash_ops_trunc.txt)
echo "=== flashing (SPD_WRITE_LIE): $N operations, feeding $N confirmations ==="
{ yes yes | head -n $N; sleep 10800; } | env SPD_WRITE_LIE=1 \
  ./spd_dump-macos/spd_dump --wait 3 verbose 0 disable_transcode timeout 30000 \
  $(cat brom-work/flash_ops_trunc.txt | tr '\n' ' ')
echo "=== FLASH SEQUENCE EXITED ==="
