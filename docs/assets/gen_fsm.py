"""
Generate a clean FSM diagram for room_eq_peripheral.sv
States: IDLE, SWEEP, DONE
"""

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyArrowPatch
import numpy as np
from pathlib import Path

fig, ax = plt.subplots(figsize=(10, 5))
ax.set_xlim(0, 10)
ax.set_ylim(0, 5)
ax.axis('off')
fig.patch.set_facecolor('white')

# ── State positions ──────────────────────────────────────────
states = {
    'IDLE':  (2.0, 2.5),
    'SWEEP': (5.0, 2.5),
    'DONE':  (8.0, 2.5),
}

colors = {
    'IDLE':  '#dbeafe',
    'SWEEP': '#dcfce7',
    'DONE':  '#fef3c7',
}
borders = {
    'IDLE':  '#1e40af',
    'SWEEP': '#166534',
    'DONE':  '#a16207',
}

R = 0.75  # circle radius

# ── Draw states ──────────────────────────────────────────────
for name, (x, y) in states.items():
    circle = plt.Circle((x, y), R, color=colors[name],
                         ec=borders[name], lw=2.5, zorder=3)
    ax.add_patch(circle)
    ax.text(x, y + 0.08, name, ha='center', va='center',
            fontsize=13, fontweight='bold', color=borders[name], zorder=4)
    ax.text(x, y - 0.25, f'({["IDLE","SWEEP","DONE"].index(name)})',
            ha='center', va='center', fontsize=9, color='#555555', zorder=4)

# ── Arrow helper ─────────────────────────────────────────────
def arc_arrow(ax, x0, y0, x1, y1, label, rad=0.0, color='#333333', lbl_offset=(0, 0.22)):
    ax.annotate('', xy=(x1, y1), xytext=(x0, y0),
                arrowprops=dict(arrowstyle='->', color=color, lw=1.8,
                                connectionstyle=f'arc3,rad={rad}'))
    mx, my = (x0 + x1) / 2 + lbl_offset[0], (y0 + y1) / 2 + lbl_offset[1]
    ax.text(mx, my, label, ha='center', va='bottom',
            fontsize=8.5, color=color,
            bbox=dict(boxstyle='round,pad=0.2', fc='white', ec='none', alpha=0.85))

# ── Transitions ───────────────────────────────────────────────

# IDLE → SWEEP (top arc, forward)
arc_arrow(ax,
    states['IDLE'][0] + R, states['IDLE'][1],
    states['SWEEP'][0] - R, states['SWEEP'][1],
    'sweep_start\n→ calibrate_start', rad=-0.35, color='#166534', lbl_offset=(0, 0.55))

# SWEEP → DONE (top arc, forward)
arc_arrow(ax,
    states['SWEEP'][0] + R, states['SWEEP'][1],
    states['DONE'][0] - R, states['DONE'][1],
    'done', rad=-0.35, color='#a16207', lbl_offset=(0, 0.45))

# DONE → SWEEP (bottom arc, backward)
arc_arrow(ax,
    states['DONE'][0] - R, states['DONE'][1],
    states['SWEEP'][0] + R, states['SWEEP'][1],
    'sweep_start\n→ calibrate_start', rad=-0.35, color='#166534', lbl_offset=(0, -0.65))

# ── Start arrow (entering IDLE) ───────────────────────────────
ax.annotate('', xy=(states['IDLE'][0] - R, states['IDLE'][1]),
            xytext=(states['IDLE'][0] - R - 0.9, states['IDLE'][1]),
            arrowprops=dict(arrowstyle='->', color='black', lw=1.8))
ax.text(states['IDLE'][0] - R - 0.95, states['IDLE'][1],
        'reset', ha='right', va='center', fontsize=9)

# ── Title ─────────────────────────────────────────────────────
ax.set_title('room_eq_peripheral FSM', fontsize=14, fontweight='bold', pad=12)

out = Path(__file__).parent / 'fsm_room_eq.png'
plt.savefig(str(out), dpi=150, bbox_inches='tight', facecolor='white')
print(f'Saved → {out}')
