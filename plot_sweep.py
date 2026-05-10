#!/usr/bin/env python3
"""Plot spectrogram from Room EQ calibration sweep data."""

import numpy as np
import matplotlib.pyplot as plt
import sys

# Load CSV, skip non-CSV header lines
fname = sys.argv[1] if len(sys.argv) > 1 else "sweep_data.csv"

# Find the header line
with open(fname) as f:
    for i, line in enumerate(f):
        if line.startswith("frame,bin,real,imag"):
            skip = i
            break

data = np.genfromtxt(fname, delimiter=',', skip_header=skip+1)
frames = data[:, 0].astype(int)
bins = data[:, 1].astype(int)
real = data[:, 2]
imag = data[:, 3]

# Compute magnitude
mag = np.sqrt(real**2 + imag**2)

# Build spectrogram matrix
n_frames = frames.max() + 1
n_bins = bins.max() + 1
spec = np.zeros((n_bins, n_frames))
for i in range(len(frames)):
    spec[bins[i], frames[i]] = mag[i]

# Only show up to Nyquist (bin 4096 = 24 kHz)
n_show = min(n_bins, 4097)
spec = spec[:n_show, :]

# Frequency and time axes
hz_per_bin = 48000 / 8192
freq_axis = np.arange(n_show) * hz_per_bin
time_axis = np.arange(n_frames) * (8192 / 48000)  # seconds per frame

# Convert to dB
spec_db = 20 * np.log10(spec + 1)  # +1 to avoid log(0)

# --- Plot 1: Spectrogram ---
fig, axes = plt.subplots(2, 2, figsize=(14, 10))

ax = axes[0, 0]
im = ax.pcolormesh(time_axis, freq_axis / 1000, spec_db, shading='auto', cmap='inferno')
ax.set_xlabel('Time (s)')
ax.set_ylabel('Frequency (kHz)')
ax.set_title('Spectrogram (Linear Frequency)')
ax.set_ylim(0, 24)
plt.colorbar(im, ax=ax, label='dB')

# --- Plot 2: Spectrogram with log frequency ---
ax = axes[0, 1]
im = ax.pcolormesh(time_axis, freq_axis, spec_db, shading='auto', cmap='inferno')
ax.set_xlabel('Time (s)')
ax.set_ylabel('Frequency (Hz)')
ax.set_title('Spectrogram (Log Frequency)')
ax.set_yscale('log')
ax.set_ylim(20, 24000)
plt.colorbar(im, ax=ax, label='dB')

# --- Plot 3: Average magnitude spectrum ---
ax = axes[1, 0]
avg_spec = spec_db.mean(axis=1)
ax.plot(freq_axis, avg_spec)
ax.set_xlabel('Frequency (Hz)')
ax.set_ylabel('Magnitude (dB)')
ax.set_title('Average Magnitude Spectrum')
ax.set_xscale('log')
ax.set_xlim(20, 24000)
ax.grid(True, alpha=0.3)

# --- Plot 4: Magnitude vs time for selected frequencies ---
ax = axes[1, 1]
target_freqs = [100, 500, 1000, 5000, 10000]
for f in target_freqs:
    bin_idx = int(f / hz_per_bin)
    if bin_idx < n_show:
        ax.plot(time_axis, spec_db[bin_idx, :], label=f'{f} Hz')
ax.set_xlabel('Time (s)')
ax.set_ylabel('Magnitude (dB)')
ax.set_title('Magnitude vs Time at Selected Frequencies')
ax.legend()
ax.grid(True, alpha=0.3)

plt.suptitle('Room EQ Sweep — Hardware FFT (8192-pt, DE1-SoC)', fontsize=14)
plt.tight_layout()
plt.savefig('sweep_spectrogram.png', dpi=150)
plt.show()
print(f"Saved to sweep_spectrogram.png")
print(f"{n_frames} frames, {n_show} bins, {time_axis[-1]:.1f}s sweep duration")
