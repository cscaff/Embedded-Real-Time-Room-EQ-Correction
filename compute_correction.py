#!/usr/bin/env python3
"""Compute room correction FIR filter from sweep calibration data."""

import numpy as np
import matplotlib.pyplot as plt
import sys

# ── Load sweep data ──────────────────────────────────────────
fname = sys.argv[1] if len(sys.argv) > 1 else "sweep_data.csv"

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

n_frames = frames.max() + 1
n_bins = bins.max() + 1
N = 8192
fs = 48000
hz_per_bin = fs / N

# ── Build complex spectrogram ────────────────────────────────
spec = np.zeros((n_bins, n_frames), dtype=complex)
for i in range(len(frames)):
    spec[bins[i], frames[i]] = real[i] + 1j * imag[i]

mag = np.abs(spec)

# ── Extract room response H(f) ──────────────────────────────
# For each frequency bin, find the frame where it has maximum energy.
# That's the frame where the sweep was at that frequency.
# Use the magnitude from that frame as H(f).

H_mag = np.zeros(n_bins)
H_phase = np.zeros(n_bins)
for b in range(n_bins):
    best_frame = np.argmax(mag[b, :])
    H_mag[b] = mag[b, best_frame]
    H_phase[b] = np.angle(spec[b, best_frame])

# Compensate for log sweep energy distribution.
# A log sweep spends more time at low frequencies, so low bins accumulate
# more energy per FFT frame. The energy scales as 1/f. Divide it out
# so the response reflects the room, not the sweep shape.
for b in range(1, n_bins):
    freq_hz = b * hz_per_bin
    H_mag[b] *= (freq_hz / 1000.0)  # normalize relative to 1 kHz

# Smooth H(f) with a log-spaced moving average
def log_smooth(x, frac=0.05):
    """Smooth with a window that grows with frequency."""
    out = np.copy(x)
    for i in range(len(x)):
        width = max(1, int(i * frac))
        lo = max(0, i - width)
        hi = min(len(x), i + width + 1)
        out[i] = np.mean(x[lo:hi])
    return out

H_smooth = log_smooth(H_mag, frac=0.10)

# ── Compute correction filter ───────────────────────────────
# Target flat — the mic response is reasonable, so the slope
# reflects the actual room + speaker response.

# Correction range: 60 Hz - 5 kHz
correction_lo_hz = 60
correction_hi_hz = 5000
correction_lo_bin = int(correction_lo_hz / hz_per_bin)
correction_hi_bin = int(correction_hi_hz / hz_per_bin)

# Target: flat at the mean level between 100-3000 Hz.
# Corrects everything toward that single level.
lo_bin = int(100 / hz_per_bin)
hi_bin = int(3000 / hz_per_bin)
H_mean = np.mean(H_smooth[lo_bin:hi_bin])
print(f"Target level: {20*np.log10(H_mean+1):.1f} dB (mean of 100-3000 Hz)")
H_norm = H_smooth / H_mean

# Correction magnitude: invert, with clamp
max_boost_db = 12  # max correction boost
max_cut_db = 12    # max correction cut
max_boost = 10 ** (max_boost_db / 20)
max_cut = 10 ** (-max_cut_db / 20)

# Correction strength: 0.0 = no correction, 1.0 = fully flat
strength = 0.5

correction_mag = np.ones(n_bins)
for b in range(correction_lo_bin, correction_hi_bin):
    if H_norm[b] > 0.001:
        c = 1.0 / H_norm[b]
        c = np.clip(c, max_cut, max_boost)
        # Blend: partial correction toward flat
        c = 1.0 + strength * (c - 1.0)
        correction_mag[b] = c

# Mirror for negative frequencies (real signal → conjugate symmetric)
correction_full = np.zeros(N, dtype=complex)
correction_full[:n_bins] = correction_mag[:n_bins]
# Mirror: bin[N-k] = conj(bin[k])
for b in range(1, n_bins - 1):
    correction_full[N - b] = correction_full[b]

# ── IFFT to get time-domain FIR taps ────────────────────────
fir_full = np.real(np.fft.ifft(correction_full))

# Window and truncate to reasonable length
n_taps = 511  # shorter filter = less ringing, more natural sound
fir_taps = np.zeros(n_taps)
# Take center of circular convolution
half = n_taps // 2
fir_taps[:half] = fir_full[N-half:]
fir_taps[half:] = fir_full[:half+1]

# Apply window to reduce ringing
window = np.hanning(n_taps)
fir_taps *= window

# Normalize so DC gain = 1
fir_taps /= np.sum(fir_taps)

# ── Save taps ────────────────────────────────────────────────
np.savetxt("correction_taps.csv", fir_taps, fmt="%.10f")
print(f"Saved {n_taps} FIR taps to correction_taps.csv")

# ── Room analysis report ─────────────────────────────────────
print("\n" + "="*60)
print("ROOM ANALYSIS REPORT")
print("="*60)

# Find peaks and dips relative to the mean
H_db = 20 * np.log10(H_smooth + 1)
mean_db = 20 * np.log10(H_mean + 1)
print(f"\nAverage level (100-3000 Hz): {mean_db:.1f} dB")

# Find peaks (>3 dB above mean) and dips (<-3 dB below mean)
# Use smoothed H to avoid noise peaks
peak_threshold = 3.0  # dB above mean
dip_threshold = 3.0   # dB below mean

# Group adjacent bins into regions
def find_features(H_db, mean_db, threshold, direction="peak"):
    features = []
    in_feature = False
    start = 0
    for b in range(correction_lo_bin, correction_hi_bin):
        above = H_db[b] - mean_db
        if direction == "peak":
            hit = above > threshold
        else:
            hit = above < -threshold
        if hit and not in_feature:
            start = b
            in_feature = True
        elif not hit and in_feature:
            # Find the extreme point in this region
            region = H_db[start:b]
            if direction == "peak":
                extreme_bin = start + np.argmax(region)
            else:
                extreme_bin = start + np.argmin(region)
            freq_hz = extreme_bin * hz_per_bin
            deviation = H_db[extreme_bin] - mean_db
            features.append((freq_hz, deviation))
            in_feature = False
    return features

peaks = find_features(H_db, mean_db, peak_threshold, "peak")
dips = find_features(H_db, mean_db, dip_threshold, "dip")

if peaks:
    print(f"\nRoom resonances detected (peaks > +{peak_threshold:.0f} dB):")
    for freq_hz, dev in peaks:
        print(f"  {freq_hz:6.0f} Hz: +{dev:.1f} dB — ", end="")
        if freq_hz < 80:
            print("sub-bass room mode (corner placement?)")
        elif freq_hz < 200:
            print("bass room mode (room dimensions)")
        elif freq_hz < 500:
            print("low-mid buildup (boxy coloration)")
        elif freq_hz < 2000:
            print("midrange resonance")
        else:
            print("upper-mid presence peak")
else:
    print("\nNo significant room resonances detected.")

if dips:
    print(f"\nNull points detected (dips > -{dip_threshold:.0f} dB):")
    for freq_hz, dev in dips:
        print(f"  {freq_hz:6.0f} Hz: {dev:.1f} dB — ", end="")
        if freq_hz < 200:
            print("bass null (speaker/listener placement)")
        elif freq_hz < 500:
            print("low-mid cancellation (reflections)")
        else:
            print("midrange null (surface reflections)")
else:
    print("\nNo significant null points detected.")

# Overall assessment
total_var = np.std(H_db[correction_lo_bin:correction_hi_bin])
print(f"\nOverall variation ({correction_lo_hz}-{correction_hi_hz} Hz): {total_var:.1f} dB std dev")
if total_var < 3:
    print("Assessment: Room is well-treated or small — minimal correction needed.")
elif total_var < 6:
    print("Assessment: Moderate room coloration — correction recommended.")
else:
    print("Assessment: Significant room modes — correction will help noticeably.")

print(f"\nCorrection applied: {correction_lo_hz}-{correction_hi_hz} Hz, "
      f"+/-{max_boost_db}/{max_cut_db} dB, strength={strength:.0%}")
print("="*60)

# ── Plot results ─────────────────────────────────────────────
fig, axes = plt.subplots(2, 2, figsize=(14, 10))
freq = np.arange(n_bins) * hz_per_bin

# Room response
ax = axes[0, 0]
ax.plot(freq[:n_bins//2], 20*np.log10(H_mag[:n_bins//2] + 1), alpha=0.4, label='Raw')
ax.plot(freq[:n_bins//2], 20*np.log10(H_smooth[:n_bins//2] + 1), label='Smoothed')
ax.set_xscale('log')
ax.set_xlim(20, 20000)
ax.set_xlabel('Frequency (Hz)')
ax.set_ylabel('Magnitude (dB)')
ax.set_title('Room Response H(f)')
ax.legend()
ax.grid(True, alpha=0.3)

# Correction curve
ax = axes[0, 1]
ax.plot(freq[:n_bins//2], 20*np.log10(correction_mag[:n_bins//2] + 0.001))
ax.set_xscale('log')
ax.set_xlim(20, 20000)
ax.set_xlabel('Frequency (Hz)')
ax.set_ylabel('Correction (dB)')
ax.set_title(f'Correction Filter ({correction_lo_hz}-{correction_hi_hz} Hz, max +/-{max_boost_db} dB)')
ax.axhline(0, color='gray', linestyle='--', alpha=0.5)
ax.grid(True, alpha=0.3)

# FIR taps
ax = axes[1, 0]
ax.plot(fir_taps)
ax.set_xlabel('Tap index')
ax.set_ylabel('Amplitude')
ax.set_title(f'FIR Filter ({n_taps} taps)')
ax.grid(True, alpha=0.3)

# Corrected vs original response
ax = axes[1, 1]
# Compute corrected response: H_corrected = H * Correction
H_corrected = H_smooth[:n_bins//2] * correction_mag[:n_bins//2]
ax.plot(freq[:n_bins//2], 20*np.log10(H_smooth[:n_bins//2] + 1), label='Original')
ax.plot(freq[:n_bins//2], 20*np.log10(H_corrected + 1), label='Corrected')
ax.set_xscale('log')
ax.set_xlim(20, 20000)
ax.set_xlabel('Frequency (Hz)')
ax.set_ylabel('Magnitude (dB)')
ax.set_title('Original vs Corrected Response')
ax.legend()
ax.grid(True, alpha=0.3)

plt.suptitle('Room EQ Correction Filter — Computed from Hardware FFT Data', fontsize=14)
plt.tight_layout()
plt.savefig('correction_filter.png', dpi=150)
plt.show()
print("Saved to correction_filter.png")
