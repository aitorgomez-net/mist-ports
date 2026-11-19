"""Write the OSD SPI commands of a sample core selector screen, as the
middle board firmware sends them with the Spectrum theme, for osd_zx_tb.sv.

  gen_osd_spi.py CHARROM_H FOLDER OUT [SELECTED] [TITLE]

CHARROM_H is the firmware font (mist-firmware/charrom.h); FOLDER is listed
as the selector would list it (folders first, then the .BIT and .ZXT cores).
"""
import datetime
import os
import re
import sys

charrom, folder, out = sys.argv[1:4]
sel = int(sys.argv[4]) if len(sys.argv) > 4 else 5
title = sys.argv[5] if len(sys.argv) > 5 else 'ZXTres+'

src = open(charrom, encoding='latin-1').read()
rows = re.findall(r'\{((?:0x[0-9A-Fa-f]{2},?){8})\}', src)
font = [[int(v, 16) for v in r.split(',') if v] for r in rows[:128]]

COLS, LINES = 32, 16
NORMAL, DIR, SELECTED = 0, 1, 2


def bitmap(s):
    """A line of text: 8 blank columns, then 30 characters, then 8 blank columns."""
    s = (s + ' ' * 30)[:30]
    cols = [0] * 8
    for ch in s:
        cols += font[ord(ch) & 0x7f]
    return cols + [0] * 8


entries = [('..', True)]
names = sorted(os.listdir(folder), key=str.lower)
entries += [(n, True) for n in names if os.path.isdir(os.path.join(folder, n))]
for n in names:
    base, ext = os.path.splitext(n)
    if ext.upper() in ('.BIT', '.ZXT') and base.upper() != 'CORE':
        entries.append((base, False))

tx = []
tx.append([0xC1])                      # theme on
tx.append([0x41])                      # OSD on
# as OsdSetTitle() sends them: the board name, then the page title
tx.append([0xB0] + bitmap(' ' + title))
# OsdStatusBar(): the page title, then the RTC date and time from column 12
status = (' Select' + ' ' * 30)[:12] + datetime.datetime.now().strftime('%d/%m/%y %H:%M:%S')
tx.append([0xB1] + bitmap(status))
for n in range(LINES):
    if n < len(entries):
        name, isdir = entries[n]
        text = (name[:23] + ' ' * 30)[:24] + '<DIR>' if isdir else name[:30]
        attr = SELECTED if n == sel else DIR if isdir else NORMAL
    else:
        text, attr = '', NORMAL
    tx.append([0x20 | n] + bitmap(text))
    tx.append([0xA0 | n, attr])

with open(out, 'w') as f:
    for t in tx:
        f.write(' '.join(f'{b:02X}' for b in t) + '\n')
print(out, len(tx), 'transactions,', len(entries), 'entries')
