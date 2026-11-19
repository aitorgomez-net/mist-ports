#!/usr/bin/env bash
# Render the ZXTRES menu OSD with the Spectrum theme (osd_zx_tb.sv) to a
# PNG picture. Run from WSL or Linux with verilator and python3 (with PIL).
#
#   menu/zxtres/sim/run_osd_zx_sim.sh CHARROM_H FOLDER [OUT_PNG] [SELECTED] [TITLE]
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out="$here/build"
charrom=$1
folder=$2
png=${3:-$out/frame.png}
mkdir -p "$out"
python3 "$here/gen_osd_spi.py" "$charrom" "$folder" "$out/osd.spi" "${4:-5}" "${5:-ZXTres+}"
verilator --binary --timing -O2 -Wno-fatal -Wno-lint -Wno-style --top-module osd_zx_tb \
  --Mdir "$out/obj" -o osd_zx_sim "$here/../osd_zx.v" "$here/osd_zx_tb.sv" \
  > "$out/verilator-build.log" 2>&1 \
  || { grep -E '%Error' "$out/verilator-build.log" | head -20 >&2; exit 1; }
(cd "$out" && ./obj/osd_zx_sim +SPI=osd.spi +OUT=frame.ppm)
python3 -c "from PIL import Image; Image.open('$out/frame.ppm').save('$png')"
echo "$png"
