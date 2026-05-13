"""
Generate an animated sine sweep GIF (20 Hz -> 20 kHz, 10 s) from math.
Saves to docs/assets/sweep.gif alongside this script.
"""

import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.animation as animation
from pathlib import Path

FS       = 48_000
DURATION = 10.0       # seconds
F_START  = 60.0       # Hz
F_END    = 20_000.0   # Hz

t = np.arange(int(FS * DURATION)) / FS

# Logarithmic (exponential) sweep — matches phase_accumulator.sv behaviour
# freq(t) = F_START * (F_END/F_START)^(t/DURATION)
# phase(t) = 2π * F_START * DURATION/ln(F_END/F_START) * ((F_END/F_START)^(t/DURATION) - 1)
L = np.log(F_END / F_START)
phase = 2 * np.pi * F_START * DURATION / L * (np.exp(L * t / DURATION) - 1)
data  = np.sin(phase)

# Downsample overview panel for speed
DS      = 40
data_ov = data[::DS]
t_ov    = t[::DS]

N_FRAMES = 80
FPS      = 15
ZOOM_S   = 0.04   # 40 ms zoom window

frame_t = np.linspace(0.2, 9.5, N_FRAMES)

fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 6))
fig.patch.set_facecolor('white')
for ax in (ax1, ax2):
    ax.set_facecolor('white')
    ax.tick_params(colors='black')
    ax.yaxis.label.set_color('black')
    ax.xaxis.label.set_color('black')
    ax.title.set_color('black')
    for spine in ax.spines.values():
        spine.set_edgecolor('#cccccc')

fig.subplots_adjust(hspace=0.55)

ax1.set_xlim(0, DURATION)
ax1.set_ylim(-1.15, 1.15)
ax1.set_ylabel('Amplitude')
ax1.set_title('Exponential Sine Sweep  60 Hz → 20 kHz  (10 s)')
ax1.axhline(0, color='#cccccc', lw=0.6)

ax2.set_ylim(-1.15, 1.15)
ax2.set_xlabel('Time (s)')
ax2.set_ylabel('Amplitude')
ax2.axhline(0, color='#cccccc', lw=0.6)

line1,  = ax1.plot([], [], lw=0.4, color='steelblue')
cursor  = ax1.axvline(0, color='tomato', lw=1.5, alpha=0.9)
line2,  = ax2.plot([], [], lw=1.2, color='steelblue')
ztitle  = ax2.set_title('')

def update(frame):
    tc = frame_t[frame]

    n = min(len(data_ov), int(tc * FS / DS))
    line1.set_data(t_ov[:n], data_ov[:n])
    cursor.set_xdata([tc, tc])

    t0 = max(0.0, tc - ZOOM_S / 2)
    t1 = t0 + ZOOM_S
    if t1 > DURATION:
        t1 = DURATION; t0 = t1 - ZOOM_S
    i0 = int(t0 * FS)
    i1 = min(len(data), int(t1 * FS))
    line2.set_data(t[i0:i1], data[i0:i1])
    ax2.set_xlim(t0, t1)

    freq = F_START * (F_END / F_START) ** (tc / DURATION)
    ztitle.set_text(f'Zoom  t = {tc:.2f} s   f ≈ {freq:,.0f} Hz')
    ztitle.set_color('black')

ani = animation.FuncAnimation(fig, update, frames=N_FRAMES, interval=1000 // FPS)

out = Path(__file__).parent / 'sweep.gif'
ani.save(str(out), writer=animation.PillowWriter(fps=FPS))
print(f'Saved → {out}')
