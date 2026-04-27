import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.animation as animation

FS      = 48_000
MAX_AMP = 8_388_607.0
INFILE  = 'sim_out/sweep_amplitude.txt'
OUTFILE = 'sim_out/sweep.gif'

data = np.loadtxt(INFILE, dtype=np.int32).astype(np.float64) / MAX_AMP
t    = np.arange(len(data)) / FS

# Downsample overview panel so each frame renders fast
DS      = 20
data_ov = data[::DS]
t_ov    = t[::DS]

N_FRAMES = 80
FPS      = 15
ZOOM_S   = 0.05  # 50 ms zoom window

frame_t = np.linspace(0.01, 5.0, N_FRAMES)

fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 6))
fig.subplots_adjust(hspace=0.5)

ax1.set_xlim(0, 5)
ax1.set_ylim(-1.1, 1.1)
ax1.set_ylabel('Amplitude')
ax1.set_title('5-Second Sine Sweep  20 Hz → 20 kHz')
ax1.axhline(0, color='gray', lw=0.4, ls='--')

ax2.set_ylim(-1.1, 1.1)
ax2.set_xlabel('Time (s)')
ax2.set_ylabel('Amplitude')
ax2.axhline(0, color='gray', lw=0.4, ls='--')

line1,  = ax1.plot([], [], lw=0.3, color='steelblue')
cursor  = ax1.axvline(0, color='#FF7700', lw=1.5, alpha=0.8)
line2,  = ax2.plot([], [], lw=1.0, color='steelblue')
ztitle  = ax2.set_title('')

def update(frame):
    tc = frame_t[frame]

    n = min(len(data_ov), int(tc * FS / DS))
    line1.set_data(t_ov[:n], data_ov[:n])
    cursor.set_xdata([tc, tc])

    t0 = max(0.0, tc - ZOOM_S / 2)
    t1 = t0 + ZOOM_S
    if t1 > 5.0:
        t1 = 5.0; t0 = t1 - ZOOM_S
    i0 = int(t0 * FS)
    i1 = min(len(data), int(t1 * FS))
    line2.set_data(t[i0:i1], data[i0:i1])
    ax2.set_xlim(t0, t1)

    freq = 20.0 * (1000.0 ** (tc / 5.0))
    ztitle.set_text(f'Zoom  t = {tc:.2f}s   f ≈ {freq:,.0f} Hz')

ani = animation.FuncAnimation(fig, update, frames=N_FRAMES, interval=1000 // FPS)
ani.save(OUTFILE, writer=animation.PillowWriter(fps=FPS))
print(f'Saved → {OUTFILE}')
