"""
plot_eq.py — visualise the room EQ correction pipeline output.

Reads the two text files written by test_fir_e2e and plots three curves:
  1. Synthetic room response       (what the mic measures)
  2. FIR correction filter         (what fir_design() computed)
  3. Corrected response            (room × filter — should be approximately flat)

All curves are normalised to their mean level in the 100 Hz – 10 kHz band so
the plot is always centred at 0 dB regardless of absolute gain.

Run from the project root after building and running test_fir_e2e:
  ./test_fir_e2e
  python3 test/software/plot_eq.py
"""

import sys
import numpy as np
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker

# ── constants ────────────────────────────────────────────────────────────────

FS     = 48_000   # sample rate (Hz) — matches WM8731 codec
N_FFT  = 8192
N_HALF = N_FFT // 2 + 1   # 4097
N_TAPS = 128

# ── load data ────────────────────────────────────────────────────────────────

try:
    room_mag = np.loadtxt("fir_e2e_room.txt")   # linear magnitudes, shape (N_HALF,)
    taps_q23 = np.loadtxt("fir_e2e_taps.txt", dtype=np.int32)  # Q1.23 integers
except OSError as e:
    print(f"Error reading data files: {e}")
    print("Run ./test_fir_e2e first to generate them.")
    sys.exit(1)

if len(room_mag) != N_HALF:
    print(f"Expected {N_HALF} room bins, got {len(room_mag)}")
    sys.exit(1)
if len(taps_q23) != N_TAPS:
    print(f"Expected {N_TAPS} taps, got {len(taps_q23)}")
    sys.exit(1)

# ── frequency axes ───────────────────────────────────────────────────────────

freqs_room = np.arange(N_HALF) * FS / N_FFT          # bin centre frequencies (Hz)

# ── FIR frequency response ───────────────────────────────────────────────────

# Convert Q1.23 integer taps to floating-point
taps_f = taps_q23.astype(np.float64) / (1 << 23)

# Zero-pad to N_FFT for the same frequency resolution as the room measurement.
# rfft returns N_FFT//2+1 = N_HALF complex bins.
H_fir = np.fft.rfft(taps_f, n=N_FFT)
freqs_fir = np.arange(len(H_fir)) * FS / N_FFT       # same grid as freqs_room

# ── convert to dB ────────────────────────────────────────────────────────────

EPS = 1e-10   # floor to avoid log(0)

room_db = 20.0 * np.log10(np.maximum(room_mag,      EPS))
fir_db  = 20.0 * np.log10(np.maximum(np.abs(H_fir), EPS))
corr_db = room_db + fir_db   # combined in dB

# ── normalise to band mean (100 Hz – 10 kHz) ─────────────────────────────────

def band_mean(freqs, values, f_lo=100.0, f_hi=10_000.0):
    mask = (freqs >= f_lo) & (freqs <= f_hi)
    return float(np.mean(values[mask]))

room_db -= band_mean(freqs_room, room_db)
fir_db  -= band_mean(freqs_fir,  fir_db)
corr_db -= band_mean(freqs_fir,  corr_db)

# ── compute flatness metrics ──────────────────────────────────────────────────

def band_std(freqs, values, f_lo=100.0, f_hi=10_000.0):
    mask = (freqs >= f_lo) & (freqs <= f_hi)
    return float(np.std(values[mask]))

std_room = band_std(freqs_room, room_db)
std_corr = band_std(freqs_fir,  corr_db)

print(f"Room response  std (100 Hz – 10 kHz): {std_room:.2f} dB")
print(f"Corrected      std (100 Hz – 10 kHz): {std_corr:.2f} dB")
print(f"Flatness improvement: {std_room / std_corr:.1f}×")

# ── plot ─────────────────────────────────────────────────────────────────────

fig, ax = plt.subplots(figsize=(13, 6))

# Skip bin 0 (DC, f=0) to avoid log(0) on the x-axis
ax.semilogx(freqs_room[1:], room_db[1:],
            label="Room response (measured)", color="tab:red",
            linewidth=1.5, alpha=0.85)

ax.semilogx(freqs_fir[1:], fir_db[1:],
            label="FIR correction filter", color="tab:blue",
            linewidth=1.5, alpha=0.85)

ax.semilogx(freqs_fir[1:], corr_db[1:],
            label=f"Corrected  (σ = {std_corr:.1f} dB vs {std_room:.1f} dB room)",
            color="tab:green", linewidth=2.0, linestyle="--")

ax.axhline(0, color="black", linewidth=0.7, linestyle=":")

# Standard audio frequency tick marks
std_freqs = [20, 31, 50, 63, 100, 125, 200, 250, 315, 500,
             1000, 2000, 4000, 8000, 16000, 20000]
std_labels = ["20", "31", "50", "63", "100", "125", "200", "250", "315", "500",
              "1k", "2k", "4k", "8k", "16k", "20k"]
ax.set_xticks(std_freqs)
ax.set_xticklabels(std_labels)
ax.xaxis.set_minor_formatter(ticker.NullFormatter())

ax.set_xlim(20, 20_000)
ax.set_ylim(-22, 16)
ax.set_xlabel("Frequency (Hz)", fontsize=12)
ax.set_ylabel("Level (dB, normalised to band mean)", fontsize=12)
ax.set_title(
    f"Room EQ Correction — End-to-End Verification  "
    f"(N={N_FFT}, {N_TAPS} taps, Hann window)",
    fontsize=13,
)
ax.legend(fontsize=11)
ax.grid(True, which="both", alpha=0.25)
ax.grid(True, which="major", alpha=0.45)

plt.tight_layout()

out_path = "fir_e2e_plot.png"
plt.savefig(out_path, dpi=150)
print(f"\nPlot saved to {out_path}")
plt.show()
