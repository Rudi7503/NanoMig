import math

b0 = 6
b1 = 12
b2 = 6
a1 = -31858
a2 = 15499

def sim_fixed(amp):
    x = [amp if ((i % 240) < 120) else -amp for i in range(2400)]
    for stage in range(32):
        y = [0] * len(x)
        x1 = x2 = y1 = y2 = 0
        for i in range(len(x)):
            xi = x[i]
            # acc = b0*xi + b1*x1 + b2*x2 - a1*y1 - a2*y2
            acc = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            # Q14 shift
            yi = acc >> 14
            # saturation
            if yi > 32767: yi = 32767
            elif yi < -32768: yi = -32768
            y[i] = yi
            x2 = x1
            x1 = xi
            y2 = y1
            y1 = yi
        peak = max(abs(s) for s in y[1000:])
        print(f"Stage {stage:2d}: peak = {peak}")
        x = y

print("=== Simulating with AMP = 0x7FFF (Full scale 32767) ===")
sim_fixed(32767)

print("\n=== Simulating with AMP = 0x1FFF (8191 as in gen_rechteck_data.py) ===")
sim_fixed(8191)
