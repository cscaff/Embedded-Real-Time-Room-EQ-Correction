"""
Step 1 — Room Measurement & Safety Check
=========================================
Plays a sine sweep through the speakers, records the room response,
derives FIR correction coefficients, and runs a set of safety assertions
before anything is sent back to the speakers in real time.

OUTPUT (written to src/software/hw_test_outputs/):
  coeffs.npy           — FIR coefficients for Step 2
  room_ir.npy          — estimated room impulse response
  SAFE                 — empty sentinel file; Step 2 refuses to run without it
  room_eq_analysis.png — four-panel diagnostic plot

BEFORE RUNNING
--------------
1. Run the device query and update INPUT_DEVICE / OUTPUT_DEVICE below:

       python -c "import sounddevice as sd; print(sd.query_devices())"

2. Set your laptop volume to ~40-50% in the OS before running.
3. Keep the room quiet during the 7-second sweep playback.
"""

import sys
import os
import numpy as np
import sounddevice as sd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

sys.path.insert(0, os.path.dirname(__file__))
from room_eq_algorithm import (
    generate_sweep,
    generate_inverse_sweep,
    measure_room,
    estimate_room_ir,
    derive_fir_coefficients,
    FS, F1, F2, N_TAPS, BETA, BLOCK,
    INPUT_DEVICE, OUTPUT_DEVICE,
)

OUT_DIR = os.path.join(os.path.dirname(__file__), "hw_test_outputs")
os.makedirs(OUT_DIR, exist_ok=True)
SAFE_FILE = os.path.join(OUT_DIR, "SAFE")

# ── Safety thresholds ─────────────────────────────────────────────────────────
# safe_gain = min(1, 1/rms_gain).  Below this the filter is so high-energy
# that it will barely pass any signal through.
MIN_SAFE_GAIN     = 0.05

# Maximum allowed peak-to-RMS ratio of the FIR frequency response (in dB).
# A ratio above this means the filter has a narrow spike that could feedback.
MAX_PEAK_TO_RMS_DB = 18.0


# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def compute_safe_gain(coeffs):
    rms = float(np.sqrt(np.sum(coeffs ** 2)))
    return min(1.0, 1.0 / rms)


def fir_frequency_response(coeffs, n_fft=8192):
    """Return (freqs_Hz, magnitude_dB) of the FIR filter."""
    H     = np.fft.rfft(coeffs, n=n_fft)
    mag   = np.abs(H)
    freqs = np.fft.rfftfreq(n_fft, 1.0 / FS)
    return freqs, mag


def passband_mask(freqs, f_lo=F1, f_hi=F2):
    return (freqs >= f_lo) & (freqs <= f_hi)


# ─────────────────────────────────────────────────────────────────────────────
# SAFETY ASSERTIONS
# ─────────────────────────────────────────────────────────────────────────────

def run_safety_checks(coeffs):
    """
    Returns (passed: bool, report: list[str]).
    Each entry in report is a line beginning with [PASS], [FAIL], or [INFO].
    """
    report  = []
    passed  = True
    freqs, mag = fir_frequency_response(coeffs)
    mask       = passband_mask(freqs)

    # ── 1. safe_gain ──────────────────────────────────────────────────────────
    safe_gain = compute_safe_gain(coeffs)
    rms_gain  = float(np.sqrt(np.sum(coeffs ** 2)))
    if safe_gain >= MIN_SAFE_GAIN:
        report.append(f"  [PASS] safe_gain = {safe_gain:.4f}  (rms_gain = {rms_gain:.2f})")
    else:
        report.append(
            f"  [FAIL] safe_gain = {safe_gain:.4f} < {MIN_SAFE_GAIN}  "
            f"(rms_gain = {rms_gain:.2f} — filter is dangerously high-energy)"
        )
        passed = False

    # ── 2. No extreme narrowband peaks in the passband ────────────────────────
    pb_mag      = mag[mask]
    rms_pb      = float(np.sqrt(np.mean(pb_mag ** 2)))
    peak_pb     = float(np.max(pb_mag))
    if rms_pb > 0:
        peak_to_rms_db = 20 * np.log10(peak_pb / rms_pb)
    else:
        peak_to_rms_db = np.inf

    if peak_to_rms_db <= MAX_PEAK_TO_RMS_DB:
        report.append(
            f"  [PASS] FIR peak-to-RMS in passband = {peak_to_rms_db:.1f} dB  "
            f"(limit {MAX_PEAK_TO_RMS_DB:.0f} dB)"
        )
    else:
        report.append(
            f"  [FAIL] FIR peak-to-RMS in passband = {peak_to_rms_db:.1f} dB  "
            f"> {MAX_PEAK_TO_RMS_DB:.0f} dB — narrow spike risks feedback"
        )
        passed = False

    # ── 3. Filter is not silent ───────────────────────────────────────────────
    if np.max(np.abs(coeffs)) > 1e-6:
        report.append(f"  [PASS] FIR coefficients are non-zero (peak = {np.max(np.abs(coeffs)):.4f})")
    else:
        report.append("  [FAIL] FIR coefficients are all near zero — measurement may have failed")
        passed = False

    # ── 4. Informational: expected output level ───────────────────────────────
    report.append(
        f"  [INFO] Real-time output will be scaled to {safe_gain * 100:.1f}% "
        f"of full scale before hard-clip"
    )

    return passed, report


# ─────────────────────────────────────────────────────────────────────────────
# PLOT
# ─────────────────────────────────────────────────────────────────────────────

def save_analysis_plot(room_ir, coeffs):
    freqs, mag   = fir_frequency_response(coeffs)
    N_plt        = len(freqs)
    mag_db       = 20 * np.log10(mag + 1e-12)

    # Room frequency response
    N_fft        = 1
    while N_fft < len(room_ir): N_fft <<= 1
    H_room       = np.fft.rfft(room_ir, n=N_fft)
    f_room       = np.fft.rfftfreq(N_fft, 1.0 / FS)
    room_db      = 20 * np.log10(np.abs(H_room) + 1e-12)

    # Normalise both to 0 dB at 1 kHz for visual comparison
    ref_room = room_db[np.argmin(np.abs(f_room - 1000))]
    ref_fir  = mag_db[np.argmin(np.abs(freqs - 1000))]
    room_db -= ref_room
    mag_db  -= ref_fir

    fig, axes = plt.subplots(2, 2, figsize=(13, 8))
    fig.suptitle("Room EQ — Measurement & Safety Analysis", fontsize=13)

    # Panel 1: Room IR (time domain)
    ax = axes[0, 0]
    t_ms = np.arange(len(room_ir)) / FS * 1000
    ax.plot(t_ms, room_ir, color="tomato", lw=0.8)
    ax.set_xlabel("Time (ms)")
    ax.set_ylabel("Amplitude")
    ax.set_title("Estimated Room Impulse Response")
    ax.grid(True, alpha=0.3)

    # Panel 2: Room frequency response
    ax = axes[0, 1]
    mask = (f_room >= 50) & (f_room <= 20000)
    ax.semilogx(f_room[mask], room_db[mask], color="tomato", lw=1.2)
    ax.axvspan(F1, F2, alpha=0.07, color="grey", label="EQ passband")
    ax.axhline(0, color="grey", lw=0.7, ls=":")
    ax.set_xlabel("Frequency (Hz)"); ax.set_ylabel("Relative magnitude (dB)")
    ax.set_title("Room Frequency Response (ref = 1 kHz)")
    ax.set_xlim(50, 20000); ax.grid(True, which="both", alpha=0.3)
    ax.legend(fontsize=8)

    # Panel 3: FIR correction coefficients (time domain)
    ax = axes[1, 0]
    ax.plot(coeffs, color="steelblue", lw=0.8)
    ax.set_xlabel("Tap index"); ax.set_ylabel("Amplitude")
    ax.set_title(f"FIR Correction Coefficients ({N_TAPS} taps)")
    ax.grid(True, alpha=0.3)

    # Panel 4: FIR frequency response
    ax = axes[1, 1]
    mask2 = (freqs >= 50) & (freqs <= 20000)
    ax.semilogx(freqs[mask2], mag_db[mask2], color="steelblue", lw=1.2,
                label="FIR correction")
    # Expected combined response: room + correction (should be near-flat)
    # Interpolate room_db onto freqs grid for the sum
    room_interp = np.interp(freqs, f_room, room_db + ref_room)
    combined_db = room_interp + (mag_db + ref_fir)
    combined_db -= combined_db[np.argmin(np.abs(freqs - 1000))]
    ax.semilogx(freqs[mask2], combined_db[mask2], color="seagreen", lw=1.2,
                ls="--", label="Room + FIR (expected)")
    ax.axvspan(F1, F2, alpha=0.07, color="grey")
    ax.axhline(0, color="grey", lw=0.7, ls=":")
    ax.set_xlabel("Frequency (Hz)"); ax.set_ylabel("Relative magnitude (dB)")
    ax.set_title("FIR Frequency Response (ref = 1 kHz)")
    ax.set_xlim(50, 20000); ax.grid(True, which="both", alpha=0.3)
    ax.legend(fontsize=8)

    plt.tight_layout()
    path = os.path.join(OUT_DIR, "room_eq_analysis.png")
    plt.savefig(path, dpi=150)
    plt.close()
    return path


# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":

    # Remove any stale SAFE sentinel from a previous run
    if os.path.exists(SAFE_FILE):
        os.remove(SAFE_FILE)

    print("── Device check ─────────────────────────────────────────────────")
    print(sd.query_devices())
    print(f"\n  Using input={INPUT_DEVICE}, output={OUTPUT_DEVICE}")
    print("  (Edit INPUT_DEVICE / OUTPUT_DEVICE in room_eq_algorithm.py if wrong)\n")

    print("── Step 1: Generate sweep ────────────────────────────────────────")
    _, sweep = generate_sweep()
    inv      = generate_inverse_sweep(sweep)
    print(f"  Sweep ready: {len(sweep)} samples")

    print("\n── Step 2: Play sweep + record room ─────────────────────────────")
    print("  >>> Sine sweep starting — keep the room quiet <<<")
    recording = measure_room(sweep)
    print("  Recording complete.")

    print("\n── Step 3: Estimate room IR ──────────────────────────────────────")
    room_ir = estimate_room_ir(recording, inv)
    print(f"  Room IR: {len(room_ir)} samples | peak = {np.max(np.abs(room_ir)):.4f}")

    print("\n── Step 4: Derive FIR correction coefficients ───────────────────")
    coeffs    = derive_fir_coefficients(room_ir)
    safe_gain = compute_safe_gain(coeffs)
    rms_gain  = float(np.sqrt(np.sum(coeffs ** 2)))
    print(f"  Coefficients: {N_TAPS} taps | peak = {np.max(np.abs(coeffs)):.4f} "
          f"| rms = {rms_gain:.2f} | safe_gain = {safe_gain:.4f}")

    print("\n── Safety checks ────────────────────────────────────────────────")
    passed, report = run_safety_checks(coeffs)
    for line in report:
        print(line)

    print("\n── Saving outputs ───────────────────────────────────────────────")
    np.save(os.path.join(OUT_DIR, "coeffs.npy"),  coeffs)
    np.save(os.path.join(OUT_DIR, "room_ir.npy"), room_ir)
    print(f"  coeffs.npy  → {OUT_DIR}")
    print(f"  room_ir.npy → {OUT_DIR}")

    plot_path = save_analysis_plot(room_ir, coeffs)
    print(f"  Plot        → {plot_path}")

    print("\n── Result ───────────────────────────────────────────────────────")
    if passed:
        open(SAFE_FILE, "w").close()   # write sentinel for Step 2
        print("  GO — all safety checks passed.")
        print("  Inspect room_eq_analysis.png, then run step2_run_realtime_eq.py")
    else:
        print("  NO-GO — safety checks failed. Do NOT run Step 2.")
        print("  Common causes:")
        print("    • Wrong device indices → microphone barely recorded anything")
        print("    • Room too loud during sweep → noisy IR estimate")
        print("    • BETA too small → try increasing BETA in room_eq_algorithm.py")
        sys.exit(1)
