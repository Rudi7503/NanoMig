import re
import os
import subprocess

src_demo = 'argon_demo.s'
with open(src_demo, 'r', encoding='utf-8') as f:
    code = f.read()

# 1. Create argon_static.s
code_static = code

# Jump directly to Act 3
act1_marker = '; ACT I [0:00 - 0:10]:'
jump_act3 = """
        ; DIRECT JUMP TO ACT 3 FOR FAST FOCUSED VERIFICATION
        BRA     .start_act3

        ; ACT I [0:00 - 0:10]:"""
code_static = code_static.replace(act1_marker, jump_act3, 1)

# Add .start_act3 label at Act 3
act3_marker = '; ACT III [0:24 - 0:55]:'
label_act3 = """.start_act3:
        ; ACT III [0:24 - 0:55]:"""
code_static = code_static.replace(act3_marker, label_act3, 1)

# After Act 3, exit immediately back to AmigaDOS (skip Act 4 and Act 5)
act3_end_marker = """        LEA     MsgAct3Done(PC),A0
        BSR     PrintStr"""
act3_exit = """        LEA     MsgAct3Done(PC),A0
        BSR     PrintStr
        BRA     .AbortDemo"""
code_static = code_static.replace(act3_end_marker, act3_exit, 1)

# Fix center band to Band 14 permanently
sweep_calc_static = """.calc_sweep:
        ; Permanently fixed on Band 14 (~676 Hz Formant) - NO SWEEP, NO REGISTER JUMPS!
        MOVEQ   #14,D0
"""
code_static = re.sub(r'\.calc_sweep:.*?(?=; 3\. Build Target Volumes)', sweep_calc_static, code_static, flags=re.DOTALL)

# Update title texts
code_static = code_static.replace('TxtAct3:        DC.B    "ACT 3: 32-BAND VOCODER (30s FADE-IN/OUT)",0',
                                  'TxtAct3:        DC.B    "TEST A: STATIC VOCODER (BAND 14 FIXED)",0')
code_static = code_static.replace('MsgBanner:      DC.B    10,"==================================================",10',
                                  'MsgBanner:      DC.B    10,"=== TEST A: STATIC VOCODER (NO REGISTER JUMPS) ===",10')

with open('argon_static.s', 'w', encoding='utf-8') as f:
    f.write(code_static)
print("Created argon_static.s")


# 2. Create argon_smooth.s
code_smooth = code

# Jump directly to Act 3
code_smooth = code_smooth.replace(act1_marker, jump_act3, 1)
code_smooth = code_smooth.replace(act3_marker, label_act3, 1)
code_smooth = code_smooth.replace(act3_end_marker, act3_exit, 1)

# Update title texts
code_smooth = code_smooth.replace('TxtAct3:        DC.B    "ACT 3: 32-BAND VOCODER (30s FADE-IN/OUT)",0',
                                  'TxtAct3:        DC.B    "TEST B: SMOOTH VOCODER (MICRO-CROSSFADE)",0')
code_smooth = code_smooth.replace('MsgBanner:      DC.B    10,"==================================================",10',
                                  'MsgBanner:      DC.B    10,"=== TEST B: SMOOTH VOCODER (MICRO-CROSSFADE) ===",10')

with open('argon_smooth.s', 'w', encoding='utf-8') as f:
    f.write(code_smooth)
print("Created argon_smooth.s")
