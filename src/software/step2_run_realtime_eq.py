"""
Step 2 — Real-Time Room EQ (file playback)
===========================================
Loads the FIR coefficients produced by step1_measure_and_check.py,
re-runs the safety assertions, then plays a WAV file through the
correction filter in real time.

USAGE
-----
    python step2_run_realtime_eq.py <path/to/audio.wav>

PREREQUISITES
-------------
* step1_measure_and_check.py must have exited with GO.
* hw_test_outputs/SAFE must exist  (Step 1 creates it on success).
* hw_test_outputs/coeffs.npy must exist.

STOPPING
--------
Press Ctrl+C at any time to stop the stream cleanly.
"""

import sys
import os
import numpy as np
import sounddevice as sd

sys.path.insert(0, os.path.dirname(__file__))
from room_eq_algorithm import (
    load_audio_file,
    run_realtime_eq_file,
    FS, BLOCK, OUTPUT_DEVICE,
)
from step1_measure_and_check import (
    compute_safe_gain,
    run_safety_checks,
    OUT_DIR,
    SAFE_FILE,
)

COEFFS_PATH = os.path.join(OUT_DIR, "coeffs.npy")


if __name__ == "__main__":

    # ── Argument ──────────────────────────────────────────────────────────────
    if len(sys.argv) < 2:
        print("Usage: python step2_run_realtime_eq.py <path/to/audio.wav>")
        sys.exit(1)

    audio_path = sys.argv[1]
    if not os.path.exists(audio_path):
        print(f"ERROR: audio file not found: {audio_path}")
        sys.exit(1)

    # ── Gate: refuse to run if Step 1 never passed ───────────────────────────
    if not os.path.exists(SAFE_FILE):
        print("ERROR: hw_test_outputs/SAFE not found.")
        print("Run step1_measure_and_check.py first and confirm it exits with GO.")
        sys.exit(1)

    if not os.path.exists(COEFFS_PATH):
        print(f"ERROR: {COEFFS_PATH} not found.")
        print("Run step1_measure_and_check.py first.")
        sys.exit(1)

    # ── Load coefficients ─────────────────────────────────────────────────────
    coeffs    = np.load(COEFFS_PATH)
    safe_gain = compute_safe_gain(coeffs)
    rms_gain  = float(np.sqrt(np.sum(coeffs ** 2)))

    print("── Loaded coefficients ──────────────────────────────────────────")
    print(f"  Taps      : {len(coeffs)}")
    print(f"  Peak      : {np.max(np.abs(coeffs)):.4f}")
    print(f"  RMS gain  : {rms_gain:.2f}")
    print(f"  safe_gain : {safe_gain:.4f}  "
          f"(output will be at {safe_gain * 100:.1f}% of full scale)")

    # ── Re-run safety checks on the loaded coefficients ───────────────────────
    print("\n── Safety re-check ──────────────────────────────────────────────")
    passed, report = run_safety_checks(coeffs)
    for line in report:
        print(line)

    if not passed:
        print("\nNO-GO — safety checks failed on loaded coefficients.")
        print("Re-run step1_measure_and_check.py to get a fresh measurement.")
        sys.exit(1)

    # ── Load audio file ───────────────────────────────────────────────────────
    print(f"\n── Audio file ───────────────────────────────────────────────────")
    print(f"  Loading: {audio_path}")
    audio = load_audio_file(audio_path, target_fs=FS)
    duration_s = len(audio) / FS
    print(f"  Samples : {len(audio)}  ({duration_s:.1f} s at {FS} Hz)")

    # ── Device confirmation ───────────────────────────────────────────────────
    print("\n── Device check ─────────────────────────────────────────────────")
    print(sd.query_devices())
    print(f"\n  Output device: {OUTPUT_DEVICE}")

    # ── Final user confirmation ───────────────────────────────────────────────
    print(f"\n  Ready to play '{os.path.basename(audio_path)}' ({duration_s:.1f} s)")
    print(f"  through the {len(coeffs)}-tap FIR correction filter.")
    print(f"  Output scaled to {safe_gain * 100:.1f}% of full scale, hard-clipped to [-1, 1].")
    print(f"  No microphone used — output only, no feedback risk.")
    print("\n  Press Enter to start, or Ctrl+C to abort.")
    try:
        input()
    except KeyboardInterrupt:
        print("Aborted.")
        sys.exit(0)

    # ── Run ───────────────────────────────────────────────────────────────────
    print(f"\n  Playing — press Ctrl+C to stop early.")
    try:
        run_realtime_eq_file(coeffs, audio)
        print("\n  Playback finished.")
    except KeyboardInterrupt:
        print("\n  Playback stopped by user.")
