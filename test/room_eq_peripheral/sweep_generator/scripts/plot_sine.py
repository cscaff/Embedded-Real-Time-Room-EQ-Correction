import csv
import matplotlib.pyplot as plt

phase_indices = []
amplitudes    = []

with open("sim_out/sine_wave.csv") as f:
    reader = csv.DictReader(f)
    for row in reader:
        phase_indices.append(int(row["phase_index"]))
        amplitudes.append(int(row["amplitude"]))

plt.figure(figsize=(12, 5))
plt.plot(phase_indices, amplitudes, linewidth=1.2)
plt.title("sine_lookup output — full cycle (1024 samples)")
plt.xlabel("Phase index (0 = 0°, 1024 = 360°)")
plt.ylabel("Amplitude (24-bit signed)")
plt.axhline(0, color="gray", linewidth=0.8, linestyle="--")
plt.axhline( 8388607, color="red",  linewidth=0.6, linestyle=":", label="+max (8388607)")
plt.axhline(-8388607, color="blue", linewidth=0.6, linestyle=":", label="-max (-8388607)")
plt.axvline(256, color="green", linewidth=0.6, linestyle=":", label="90° boundary")
plt.axvline(512, color="green", linewidth=0.6, linestyle=":")
plt.axvline(768, color="green", linewidth=0.6, linestyle=":")
plt.legend()
plt.tight_layout()
plt.savefig("sim_out/sine_wave.png", dpi=150)
plt.show()
print("Saved sim_out/sine_wave.png")
