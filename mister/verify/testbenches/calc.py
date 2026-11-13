import cmath, math
b0, b1, b2 = 6/16384, 12/16384, 6/16384
a1, a2 = -31858/16384, 15499/16384

print("b0,b1,b2:", b0, b1, b2)
print("a1,a2:", a1, a2)

for f in [5, 10, 20, 50, 100, 200, 500, 1000]:
    omega = 2 * math.pi * f / 48000
    z = cmath.exp(1j * omega)
    H = (b0 + b1*z**-1 + b2*z**-2) / (1 + a1*z**-1 + a2*z**-2)
    mag1 = abs(H)
    mag32 = mag1**32
    print(f"{f:4d} Hz: 1 stage = {mag1:.4f}, 32 stages = {mag32:.6e}")
