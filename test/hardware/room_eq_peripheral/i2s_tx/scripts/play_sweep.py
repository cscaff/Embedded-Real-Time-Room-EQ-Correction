import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import wave
import struct

FS       = 48_000
MAX_AMP  = 8_388_607.0
INFILE   = 'sim_out/i2s_sweep_samples.txt'
WAV_FILE = 'sim_out/i2s_sweep.wav'
PNG_FILE = 'sim_out/i2s_sweep.png'

# Read reconstructed samples from simulation
data = np.loadtxt(INFILE, dtype=np.int32)
n_samples = len(data)
duration = n_samples / FS

print(f'Read {n_samples} samples ({duration:.3f}s at {FS} Hz)')

# Normalize to [-1.0, 1.0]
norm = data.astype(np.float64) / MAX_AMP
t = np.arange(n_samples) / FS

# ── Plot ─────────────────────────────────────────────────────
fig, axes = plt.subplots(2, 1, figsize=(12, 6))
fig.subplots_adjust(hspace=0.4)

# Full waveform
axes[0].plot(t, norm, lw=0.5, color='steelblue')
axes[0].set_xlim(0, duration)
axes[0].set_ylim(-1.1, 1.1)
axes[0].set_xlabel('Time (s)')
axes[0].set_ylabel('Amplitude')
axes[0].set_title(f'Sweep through I2S — {n_samples} samples ({duration:.3f}s)')
axes[0].axhline(0, color='gray', lw=0.4, ls='--')

# Zoomed view of first few cycles
zoom_samples = min(n_samples, 2000)
axes[1].plot(t[:zoom_samples], norm[:zoom_samples], lw=0.8, color='steelblue')
axes[1].set_xlim(0, zoom_samples / FS)
axes[1].set_ylim(-1.1, 1.1)
axes[1].set_xlabel('Time (s)')
axes[1].set_ylabel('Amplitude')
axes[1].set_title('Zoomed — first cycles (expect ~20 Hz)')
axes[1].axhline(0, color='gray', lw=0.4, ls='--')

plt.savefig(PNG_FILE, dpi=150, bbox_inches='tight')
print(f'Saved plot → {PNG_FILE}')

# ── WAV file ─────────────────────────────────────────────────
# Convert 24-bit samples to 16-bit PCM for WAV compatibility.
data_16 = np.clip(data >> 8, -32768, 32767).astype(np.int16)

with wave.open(WAV_FILE, 'w') as wf:
    wf.setnchannels(1)       # mono
    wf.setsampwidth(2)       # 16-bit
    wf.setframerate(FS)
    wf.writeframes(data_16.tobytes())

print(f'Saved WAV  → {WAV_FILE}')
print(f'\nTo play on macOS:  afplay {WAV_FILE}')
print(f'To play on Linux:  aplay {WAV_FILE}')
