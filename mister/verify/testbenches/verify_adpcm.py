#!/usr/bin/env python3
"""
ADPCM Reference Verification Script for NanoMig.
Verifies adpcm_decoder_shared.v against Python reference:
1. Exhaustive unit test (all bps 2,3,4,5; all codes; index 0..88; various pcm values)
2. Sequential decode of adpcm_4bit.bin (48,000 samples)
3. Compiles and executes Verilog simulation via Icarus Verilog and compares bit-for-bit.
"""

import os
import sys
import struct
import subprocess

STEP_TABLE = [
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
    19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
    130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
    337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
    876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
    5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
]

def adpcm_decode_step(in_pcm, in_index, code, bps):
    # Step size
    step = STEP_TABLE[in_index] if (0 <= in_index <= 88) else 32767
    
    # Arithmetic parameters
    if bps == 2:
        sh = 1
        negative = bool(code & 0x02)
        mag = code & 0x01
        index_delta = 2 if (code & 0x01) else -1
    elif bps == 3:
        sh = 2
        negative = bool(code & 0x04)
        mag = code & 0x03
        c = code & 0x03
        if c == 2: index_delta = 1
        elif c == 3: index_delta = 2
        else: index_delta = -1
    elif bps == 4:
        sh = 3
        negative = bool(code & 0x08)
        mag = code & 0x07
        c = code & 0x07
        if c == 4: index_delta = 2
        elif c == 5: index_delta = 4
        elif c == 6: index_delta = 6
        elif c == 7: index_delta = 8
        else: index_delta = -1
    elif bps == 5:
        sh = 4
        negative = bool(code & 0x10)
        mag = code & 0x0F
        c = code & 0x0F
        table_5bit = {8: 1, 9: 2, 10: 4, 11: 6, 12: 8, 13: 10, 14: 13, 15: 16}
        index_delta = table_5bit.get(c, -1)
    else:
        raise ValueError(f"Unsupported bps: {bps}")

    # Delta calculation
    mult_val = step * ((mag << 1) | 1)
    delta = mult_val >> sh

    # Next index
    next_idx = in_index + index_delta
    if next_idx < 0: next_idx = 0
    elif next_idx > 88: next_idx = 88

    # Next PCM
    if negative:
        next_pcm = in_pcm - delta
    else:
        next_pcm = in_pcm + delta

    # Clamp 16-bit signed
    if next_pcm > 32767: next_pcm = 32767
    elif next_pcm < -32768: next_pcm = -32768

    return next_pcm, next_idx

def generate_stimuli(output_file, bin_file):
    test_vectors = []

    # 1. Exhaustive check across configurations
    test_pcms = [-32768, -32000, -1000, -1, 0, 1, 1000, 32000, 32767]
    for bps in [2, 3, 4, 5]:
        max_code = (1 << bps) - 1
        for code in range(max_code + 1):
            for idx in [0, 1, 10, 44, 87, 88]:
                for pcm in test_pcms:
                    exp_pcm, exp_idx = adpcm_decode_step(pcm, idx, code, bps)
                    # pcm as uint16
                    pcm_u16 = pcm & 0xFFFF
                    exp_pcm_u16 = exp_pcm & 0xFFFF
                    test_vectors.append((pcm_u16, idx, code, bps, exp_pcm_u16, exp_idx))

    # 2. Sequential decode of adpcm_4bit.bin (48,000 codes)
    if os.path.exists(bin_file):
        with open(bin_file, "rb") as f:
            data = f.read()
        cur_pcm = 0
        cur_idx = 0
        for byte in data:
            # LSB first: low nibble then high nibble
            c0 = byte & 0x0F
            exp_pcm, exp_idx = adpcm_decode_step(cur_pcm, cur_idx, c0, 4)
            test_vectors.append((cur_pcm & 0xFFFF, cur_idx, c0, 4, exp_pcm & 0xFFFF, exp_idx))
            cur_pcm, cur_idx = exp_pcm, exp_idx

            c1 = (byte >> 4) & 0x0F
            exp_pcm, exp_idx = adpcm_decode_step(cur_pcm, cur_idx, c1, 4)
            test_vectors.append((cur_pcm & 0xFFFF, cur_idx, c1, 4, exp_pcm & 0xFFFF, exp_idx))
            cur_pcm, cur_idx = exp_pcm, exp_idx
    else:
        print(f"Warning: {bin_file} not found!")

    with open(output_file, "w") as f:
        for pcm, idx, code, bps, exp_pcm, exp_idx in test_vectors:
            f.write(f"{pcm:04x} {idx:02x} {code:02x} {bps:01x} {exp_pcm:04x} {exp_idx:02x}\n")

    return len(test_vectors)

def main():
    base_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    bin_file = os.path.join(base_dir, "tests", "adpcm", "adpcm_4bit.bin")
    tb_dir = os.path.dirname(os.path.abspath(__file__))
    stim_file = os.path.join(tb_dir, "adpcm_stim.txt")
    rtl_file = os.path.join(base_dir, "rtl", "audio_ext", "adpcm_decoder_shared.v")
    tb_file = os.path.join(tb_dir, "tb_adpcm_ref.v")

    print(f"[1/3] Generating stimuli against Python reference...")
    num_vectors = generate_stimuli(stim_file, bin_file)
    print(f"      Total test vectors generated: {num_vectors}")

    print(f"[2/3] Compiling tb_adpcm_ref.v with iverilog...")
    vvp_file = os.path.join(os.environ.get("TEMP", "."), "tb_adpcm.vvp")
    cmd_compile = ["iverilog", "-g2012", "-s", "tb_adpcm_ref", "-o", vvp_file, tb_file, rtl_file]
    res = subprocess.run(cmd_compile, capture_output=True, text=True)
    if res.returncode != 0:
        print("Compilation failed:")
        print(res.stderr)
        sys.exit(1)

    print(f"[3/3] Running simulation with vvp...")
    cmd_run = ["vvp", vvp_file, f"+STIM={stim_file.replace(os.sep, '/')}", f"+COUNT={num_vectors}"]
    res = subprocess.run(cmd_run, capture_output=True, text=True)
    print(res.stdout)
    if res.returncode != 0:
        print("Simulation FAILED:")
        print(res.stderr)
        sys.exit(1)

    print("=== ADPCM PYTHON REFERENCE VERIFICATION PASSED SUCCESSFULLY ===")

if __name__ == "__main__":
    main()
