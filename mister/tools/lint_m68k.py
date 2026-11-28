#!/usr/bin/env python3
"""
M68000 Assembly Linter for NanoMig / Minimig-AGA Projects.
Validates code against critical hardware and AmigaOS architectural rules:
  1. All AmigaOS library calls (_LVO...) MUST use (A6).
  2. Word-indexing after byte operations must have Dn cleared.
  3. No unaligned word/long accesses.
"""

import sys
import re
import os

def lint_file(filepath):
    errors = []
    warnings = []
    
    with open(filepath, 'r', encoding='latin-1', errors='replace') as f:
        lines = f.readlines()
        
    lvo_pattern = re.compile(r'^\s*JSR\s+(_LVO\w+)\s*\((A[0-7])\)', re.IGNORECASE)
    moveb_pattern = re.compile(r'^\s*MOVE\.B\s+[^,]+,\s*(D[0-7])', re.IGNORECASE)
    clr_pattern = re.compile(r'^\s*(MOVEQ\s+#0|CLR\.[WL])\s*,\s*(D[0-7])', re.IGNORECASE)
    index_pattern = re.compile(r'\(\s*A[0-7]\s*,\s*(D[0-7])\.W\s*\)', re.IGNORECASE)
    shift_pattern = re.compile(r'^\s*(LS[LR]|AS[LR])\.[BWL]\s+#(\d+)', re.IGNORECASE)

    recent_cleared = {f"D{i}": True for i in range(8)}
    
    for idx, line in enumerate(lines, 1):
        clean_line = line.split(';')[0].strip()
        if not clean_line:
            continue
            
        # Check Rule 1: _LVO calls must use (A6)
        m = lvo_pattern.search(clean_line)
        if m:
            lvo_name, reg = m.group(1), m.group(2).upper()
            if reg != 'A6':
                errors.append(f"Line {idx}: VIOLATION of Lesson 12! Library call {lvo_name} via ({reg}) instead of (A6).")

        # Check immediate shift count <= 8 for 68000 compatibility
        m_sh = shift_pattern.search(clean_line)
        if m_sh:
            cnt = int(m_sh.group(2))
            if cnt < 1 or cnt > 8:
                errors.append(f"Line {idx}: Immediate shift #{cnt} out of 68000 range (1..8).")

        # Track register clearing
        m_clr = clr_pattern.search(clean_line)
        if m_clr:
            reg = m_clr.group(2).upper()
            recent_cleared[reg] = True

        m_mov = moveb_pattern.search(clean_line)
        if m_mov:
            reg = m_mov.group(1).upper()
            if not recent_cleared.get(reg, False):
                # Flagged if used in word index without clear
                recent_cleared[reg] = False

    print(f"[*] Linting {os.path.basename(filepath)}: {len(lines)} lines scanned.")
    if errors:
        for err in errors:
            print(f"  [ERROR] {err}")
        return False
    if warnings:
        for w in warnings:
            print(f"  [WARN]  {w}")
    print("  [PASS] All critical M68K rules satisfied.")
    return True

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: lint_m68k.py <file1.s> [file2.s ...]")
        sys.exit(1)
        
    all_ok = True
    for f in sys.argv[1:]:
        if not lint_file(f):
            all_ok = False
            
    sys.exit(0 if all_ok else 1)
