#!/usr/bin/env python3
"""
gen_golden_fft.py  —  Generate input and golden FFT output for tb_calibration_engine.

Test signal
-----------
Single cosine at bin k0=64, integer amplitude A=512, over N=8192 samples:

    x[n] = round(512 * cos(2*pi*64*n/8192))

Because k0=64 divides N=8192 exactly (8192/64 = 128 complete periods), the
ideal DFT has exactly two non-zero bins:

    X[64]   ≈  A * N/2 = 512 * 4096 = 2,097,152  (fits in 24-bit signed)
    X[8128] ≈  A * N/2 = 2,097,152               (complex conjugate)

Integer rounding of the input introduces < 1 LSB of spectral leakage.
The Altera FFT II adds a further ~2 LSB of fixed-point error per bin;
the testbench uses a +-16 LSB tolerance to cover this.

Output files (sim_out/, one 24-bit hex value per line)
-------------------------------------------------------
  fft_input.hex       — 8192 input samples (signed 24-bit integer)
  fft_golden_real.hex — real part of numpy FFT of integer input
  fft_golden_imag.hex — imaginary part

24-bit representation: values are stored as unsigned hex with 2's-complement
wrapping (negative values appear as e.g. FFFF00).  $readmemh in the testbench
reads these as logic [23:0] and the testbench interprets them as $signed.
"""
import os
import sys
import numpy as np

# ── Parameters ────────────────────────────────────────────────────────────────
N  = 8192   # FFT size (must match hardware)
k0 = 64     # bin index  →  frequency = k0 * fs / N = 64 * 48000 / 8192 ≈ 375 Hz
A  = 512    # integer amplitude (LSBs)
              # Max safe for single-tone: 2^23 / (N/2) = 8388608 / 4096 = 2048

# ── Output directory ──────────────────────────────────────────────────────────
# When invoked from the Makefile (project root as CWD), sim_out/ is relative.
# When invoked directly from this script's directory, compute the absolute path.
script_dir   = os.path.dirname(os.path.abspath(__file__))
project_root = os.path.normpath(os.path.join(script_dir, '../../../../'))
out_dir      = os.path.join(project_root, 'sim_out')
os.makedirs(out_dir, exist_ok=True)

# ── Generate integer cosine input ─────────────────────────────────────────────
n = np.arange(N)
x_float = A * np.cos(2.0 * np.pi * k0 * n / N)
x = np.round(x_float).astype(np.int32)
x = np.clip(x, -(1 << 23), (1 << 23) - 1)   # enforce 24-bit signed range

# ── Compute FFT of the integer-valued input ───────────────────────────────────
# numpy.fft.fft uses float64 internally, giving the exact mathematical result
# (within float64 precision) for integer inputs.  This is what the hardware
# should produce without fixed-point quantization error.
X = np.fft.fft(x.astype(np.float64))

# Round to nearest integer and clip to 24-bit signed range.
# With A=512, X[k0] ≈ 2,097,152 which is well within [-8388608, 8388607].
FFT_SCALE = 1 << 14  # Altera R22SDF 8192-pt fixed-point scaling factor (13 butterfly stages)
X_real = np.round(X.real / FFT_SCALE).astype(np.int64)
X_imag = np.round(X.imag / FFT_SCALE).astype(np.int64)
X_real = np.clip(X_real, -(1 << 23), (1 << 23) - 1).astype(np.int32)
X_imag = np.clip(X_imag, -(1 << 23), (1 << 23) - 1).astype(np.int32)

# ── Write hex files (24-bit 2's-complement, one value per line) ───────────────
def write_hex24(path, data):
    with open(path, 'w') as f:
        for v in data:
            f.write(f'{int(v) & 0xFFFFFF:06X}\n')

input_path      = os.path.join(out_dir, 'fft_input.hex')
golden_real_path = os.path.join(out_dir, 'fft_golden_real.hex')
golden_imag_path = os.path.join(out_dir, 'fft_golden_imag.hex')

write_hex24(input_path,       x)
write_hex24(golden_real_path, X_real)
write_hex24(golden_imag_path, X_imag)

# ── Summary ───────────────────────────────────────────────────────────────────
print(f"Signal:    cos at bin {k0}, amplitude {A}, N={N}")
print(f"X[{k0:4d}]  = {X_real[k0]:+10d} + j{X_imag[k0]:+10d}   (expected ~+{A*N//2//FFT_SCALE})")
print(f"X[{N-k0:4d}]  = {X_real[N-k0]:+10d} + j{X_imag[N-k0]:+10d}   (conjugate)")

noise_bins = [i for i in range(N) if i != k0 and i != N - k0]
max_noise_r = max(abs(X_real[i]) for i in noise_bins)
max_noise_i = max(abs(X_imag[i]) for i in noise_bins)
print(f"Max noise: real={max_noise_r}  imag={max_noise_i}  (should be < 1 LSB from rounding)")
print(f"Files:     {input_path}")
print(f"           {golden_real_path}")
print(f"           {golden_imag_path}")
