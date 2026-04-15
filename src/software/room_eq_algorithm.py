"""
Room EQ Algorithm — Pseudocode Reference for FPGA Implementation
================================================================
Pipeline:
  1. Generate logarithmic sine sweep
  2. Build inverse filter for the sweep
  3. Play sweep into room, record microphone response
  4. Estimate room impulse response (IR) via deconvolution
  5. Derive FIR correction coefficients via regularized spectral inversion
  6. Apply FIR filter in real-time using overlap-add
"""

import numpy as np
from scipy.signal import fftconvolve, resample_poly
from scipy.fft import fft
from scipy.io import wavfile
from numpy import kaiser
import sounddevice as sd
from math import gcd


# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

FS            = 44100    # sample rate (Hz)
F1            = 80       # sweep start frequency (Hz)
F2            = 18000    # sweep end frequency (Hz)
T             = 5.0      # sweep duration (seconds)
PRE_PAD       = 1.0      # silence before sweep to absorb Bluetooth/latency delay (s)
POST_PAD      = 1.0      # silence after sweep to capture reverb tail (s)
IR_LEN        = int(0.5 * FS)   # impulse response capture window (samples)
N_TAPS        = 1024     # FIR filter length (taps)
BETA          = 0.0001   # regularization strength (fraction of mean spectral power)
BLOCK         = 512      # real-time block size (samples); ~11.6 ms at 44100 Hz
STREAM_DURATION = 30     # seconds to run the real-time EQ stream
VOLUME        = 0.5      # playback level for sweep (0.0–1.0)
INPUT_DEVICE  = 2        # sounddevice index for microphone
OUTPUT_DEVICE = 5        # sounddevice index for speakers


# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Generate Logarithmic Sine Sweep  (Farina 2000)
#
# A log sweep spends equal time per octave. The instantaneous frequency is:
#   f(t) = f1 * (f2/f1)^(t/T)
#
# Phase is the integral of 2π·f(t), giving:
#   phase(t) = K * (exp(t/L) − 1)
#
# where K = T·w1 / ln(w2/w1)  and  L = T / ln(w2/w1).
# ─────────────────────────────────────────────────────────────────────────────

def generate_sweep(f1=F1, f2=F2, T=T, fs=FS):
    w1 = 2 * np.pi * f1
    w2 = 2 * np.pi * f2
    t  = np.arange(0, T, 1.0 / fs)
    L  = T / np.log(w2 / w1)
    K  = T * w1 / np.log(w2 / w1)
    phase = K * (np.exp(t / L) - 1.0)
    sweep = np.sin(phase)
    return t, sweep


# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: Build Inverse Filter
#
# For a log sweep x(t) recorded through a room h(t):
#   y(t) = x(t) * h(t)  (convolution)
#
# We want x_inv such that x(t) * x_inv(t) = delta(t), so that:
#   y(t) * x_inv(t) = h(t)
#
# Construction:
#   a. Kaiser-window the sweep edges to reduce spectral leakage.
#   b. Time-reverse the windowed sweep.
#   c. Apply a 6 dB/octave decaying envelope to flatten the spectral energy
#      (the log sweep delivers more energy to higher octaves; the envelope
#       cancels that imbalance so the combined response is flat).
#   d. Normalize so the peak of (sweep * inv) equals 1.
# ─────────────────────────────────────────────────────────────────────────────

def generate_inverse_sweep(sweep, f1=F1, f2=F2, T=T, fs=FS):
    N     = len(sweep)
    sweep = sweep.copy()

    # (a) Kaiser window taper — fade in / fade out to suppress spectral leakage
    sweep[:1250]  *= kaiser(2500, beta=16)[:1250]   # fade in  (~28 ms)
    sweep[-1250:] *= kaiser(2500, beta=14)[1250:]   # fade out (~28 ms)

    # (b) Time-reverse
    inv = sweep[::-1].copy()

    # (c) 6 dB/octave exponential decay envelope
    #   total_dB = -6 * log2(f2/f1)   (one dB drop per octave)
    #   envelope[n] = exp(n * k)  where k = ln(10^(total_dB/20)) / N
    num_octaves = np.log2(f2 / f1)
    total_dB    = -6.0 * num_octaves
    kend        = 10 ** (total_dB / 20.0)
    k           = np.log(kend) / N
    envelope    = np.exp(np.arange(N) * k)
    inv        *= envelope

    # (d) Normalize: convolve with sweep, measure mid-band amplitude, scale to 1
    test_conv = fftconvolve(inv, sweep)
    F         = fft(test_conv)
    mid_bin   = round(len(F) / 4)
    scale     = np.abs(F[mid_bin])
    inv      /= scale

    return inv


# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: Play Sweep Into Room and Record Microphone Response
#
# Pad with silence so Bluetooth / amplifier latency does not clip the sweep.
# sounddevice.playrec plays and records simultaneously.
# ─────────────────────────────────────────────────────────────────────────────

def measure_room(sweep, fs=FS,
                 input_device=INPUT_DEVICE, output_device=OUTPUT_DEVICE,
                 volume=VOLUME, pre_pad=PRE_PAD, post_pad=POST_PAD):
    silence_pre  = np.zeros(int(pre_pad  * fs))
    silence_post = np.zeros(int(post_pad * fs))
    playback     = np.concatenate([silence_pre, sweep * volume, silence_post])
    playback_2d  = playback.reshape(-1, 1)   # sounddevice expects (samples, channels)

    recording_2d = sd.playrec(
        playback_2d,
        samplerate = fs,
        channels   = 1,
        device     = (input_device, output_device),
        dtype      = "float32",
    )
    sd.wait()

    return recording_2d[:, 0]   # flatten to 1-D


# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: Estimate Room Impulse Response (IR)
#
# Deconvolution:
#   recording = sweep * room_ir   (convolution)
#   room_ir   = recording * inv   (deconvolution via inverse filter)
#
# The convolution output is longer than the IR; we find the peak (direct
# sound arrival) and trim IR_LEN samples from that point.
# ─────────────────────────────────────────────────────────────────────────────

def estimate_room_ir(recording, inv, ir_len=IR_LEN):
    full_result  = fftconvolve(recording, inv)
    peak         = np.argmax(np.abs(full_result))
    room_ir      = full_result[peak : peak + ir_len]
    return room_ir


# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: Derive FIR Correction Coefficients
#
# METHOD: Wiener-style regularized spectral inversion.
#
#   H(f)     = FFT of room_ir
#   H_inv(f) = conj(H(f)) / (|H(f)|^2 + beta)
#
# beta prevents division by zero at spectral nulls (room resonances that
# fully cancel a frequency). beta = BETA * mean(|H(f)|^2) scales the floor
# relative to the room's actual power level.
#
# The resulting time-domain filter is truncated to N_TAPS samples, then
# smoothed with a Tukey window (flat over 75% of the buffer, cosine taper
# on the outer 12.5% at each end). Hann would zero tap 0 and destroy the
# direct-sound spike; Tukey preserves it.
# ─────────────────────────────────────────────────────────────────────────────

def make_tukey_window(N, alpha=0.25):
    win   = np.ones(N)
    taper = int(alpha * N / 2)
    if taper > 0:
        ramp = 0.5 * (1 - np.cos(np.linspace(0, np.pi, taper)))
        win[:taper]  = ramp
        win[-taper:] = ramp[::-1]
    return win


def derive_fir_coefficients(room_ir, n_taps=N_TAPS, beta_frac=BETA, fs=FS):
    # Next power-of-two FFT size for efficiency
    N_fft = 1
    while N_fft < len(room_ir):
        N_fft <<= 1

    # Frequency-domain room response
    H = np.fft.rfft(room_ir, n=N_fft)

    # Regularized inverse
    power    = np.mean(np.abs(H) ** 2)
    beta     = beta_frac * power
    H_inv    = np.conj(H) / (np.abs(H) ** 2 + beta)

    # Back to time domain — causal content is at the start
    inv_ir_full = np.fft.irfft(H_inv, n=N_fft)

    # Truncate to desired tap count
    coeffs = inv_ir_full[:n_taps].copy()

    # Tukey window to suppress Gibbs ripple without killing tap 0
    coeffs *= make_tukey_window(n_taps, alpha=0.25)

    # Normalize peak to 1
    coeffs /= np.max(np.abs(coeffs))

    return coeffs


# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: Real-Time FIR EQ via Overlap-Add
#
# Audio arrives in BLOCK-sample chunks from the microphone callback.
# Each chunk:
#   1. Convolve with the N_TAPS-tap FIR → output length = BLOCK + N_TAPS - 1.
#   2. Add the (N_TAPS - 1)-sample tail carried over from the previous block
#      (overlap-add: eliminates clicks at block boundaries).
#   3. Save the new tail for the next block.
#   4. Scale by SAFE_GAIN and hard-clip to [-1, 1] before sending to speakers.
#
# SAFE_GAIN = min(1, 1 / rms_gain) where rms_gain = sqrt(sum(coeffs^2)).
# This ensures the filter never amplifies beyond the input level.
# ─────────────────────────────────────────────────────────────────────────────

def run_realtime_eq(coeffs, fs=FS, block=BLOCK,
                    duration=STREAM_DURATION,
                    input_device=INPUT_DEVICE, output_device=OUTPUT_DEVICE):

    rms_gain  = float(np.sqrt(np.sum(coeffs ** 2)))
    safe_gain = min(1.0, 1.0 / rms_gain)
    n_filt    = len(coeffs)

    state = {"tail": np.zeros(n_filt - 1, dtype=np.float32)}

    def eq_callback(indata, outdata, frames, time, status):
        x      = indata[:, 0].astype(np.float32)
        y_full = np.convolve(x, coeffs.astype(np.float32))   # BLOCK + N_TAPS - 1 samples

        # Overlap-add: accumulate previous tail
        tail_len = len(state["tail"])
        y_full[:tail_len] += state["tail"]

        # Save new tail for next block
        state["tail"] = y_full[frames:].copy()

        # Output: scale, hard-clip, write to speakers
        out = (y_full[:frames] * safe_gain).astype(np.float32)
        np.clip(out, -1.0, 1.0, out=out)
        outdata[:, 0] = out

    with sd.Stream(samplerate=fs,
                   blocksize=block,
                   dtype="float32",
                   device=(input_device, output_device),
                   channels=(1, 1),
                   callback=eq_callback):
        sd.sleep(int(duration * 1000))


# ─────────────────────────────────────────────────────────────────────────────
# STEP 6b: Load an Audio File for Real-Time EQ Playback
#
# Supports any WAV file (8/16/24/32-bit int or float).
# Converts to mono float32 and resamples to FS if the file's sample rate
# differs.  Returns a 1-D float32 array normalised to peak ≤ 1.
# ─────────────────────────────────────────────────────────────────────────────

def load_audio_file(filepath, target_fs=FS):
    file_fs, data = wavfile.read(filepath)

    # Normalise integer PCM to float32 in [-1, 1]
    if data.dtype == np.int16:
        data = data.astype(np.float32) / 32768.0
    elif data.dtype == np.int32:
        data = data.astype(np.float32) / 2147483648.0
    elif data.dtype == np.uint8:
        data = (data.astype(np.float32) - 128.0) / 128.0
    else:
        data = data.astype(np.float32)

    # Stereo → mono
    if data.ndim == 2:
        data = data.mean(axis=1)

    # Resample if sample rates differ
    if file_fs != target_fs:
        g    = gcd(file_fs, target_fs)
        up   = target_fs // g
        down = file_fs   // g
        data = resample_poly(data, up, down).astype(np.float32)

    # Normalise peak to 1
    peak = np.max(np.abs(data))
    if peak > 0:
        data /= peak

    return data


# ─────────────────────────────────────────────────────────────────────────────
# STEP 6c: Real-Time FIR EQ on a File (no microphone)
#
# Uses an sd.OutputStream (output only) so there is no mic input and no
# feedback risk.  The same overlap-add processing as run_realtime_eq applies,
# driven from a file buffer instead of the mic callback's indata.
#
# Playback stops automatically when the file ends, or on Ctrl+C.
# ─────────────────────────────────────────────────────────────────────────────

def run_realtime_eq_file(coeffs, audio, fs=FS, block=BLOCK,
                         output_device=OUTPUT_DEVICE):
    """
    Process `audio` (1-D float32, already at sample rate `fs`) through the
    FIR correction filter in real-time blocks and play via `output_device`.

    Parameters
    ----------
    coeffs        : 1-D ndarray  — FIR correction coefficients
    audio         : 1-D float32  — source audio at sample rate `fs`
    fs, block     : sample rate and block size
    output_device : sounddevice device index for speakers
    """
    coeffs    = coeffs.astype(np.float32)
    rms_gain  = float(np.sqrt(np.sum(coeffs ** 2)))
    safe_gain = min(1.0, 1.0 / rms_gain)
    n_filt    = len(coeffs)

    state = {
        "pos":  0,
        "tail": np.zeros(n_filt - 1, dtype=np.float32),
        "done": False,
    }

    def callback(outdata, frames, time, status):
        pos = state["pos"]
        x   = audio[pos : pos + frames].copy()

        # End of file — pad with zeros and signal stop
        if len(x) < frames:
            x = np.pad(x, (0, frames - len(x)))
            state["done"] = True

        y_full              = np.convolve(x, coeffs)
        y_full[:n_filt - 1] += state["tail"]
        state["tail"]        = y_full[frames:].copy()
        state["pos"]         = pos + frames

        out = np.clip(y_full[:frames] * safe_gain, -1.0, 1.0).astype(np.float32)
        outdata[:, 0] = out

        if state["done"]:
            raise sd.CallbackStop()

    with sd.OutputStream(samplerate=fs,
                         blocksize=block,
                         dtype="float32",
                         device=output_device,
                         channels=1,
                         callback=callback) as stream:
        # Block until the stream finishes or the user hits Ctrl+C
        while stream.active:
            sd.sleep(100)


# ─────────────────────────────────────────────────────────────────────────────
# MAIN — Full Pipeline
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":

    # 1. Generate sweep
    _, sweep = generate_sweep()

    # 2. Build inverse filter
    inv = generate_inverse_sweep(sweep)

    # 3. Play into room and record
    recording = measure_room(sweep)

    # 4. Estimate room IR
    room_ir = estimate_room_ir(recording, inv)

    # 5. Derive FIR correction coefficients
    coeffs = derive_fir_coefficients(room_ir)

    print(f"FIR filter: {N_TAPS} taps  |  beta = {BETA}  |  fs = {FS} Hz")
    print(f"Coefficient range: [{coeffs.min():.4f}, {coeffs.max():.4f}]")

    # 6. Run real-time EQ
    run_realtime_eq(coeffs)
