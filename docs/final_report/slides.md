# Room EQ Correction — Slide Outline

---

## Slide 1 — Title

**Real-Time Room EQ Correction**
DE1-SoC (Cyclone V FPGA + ARM HPS)

Jacob Boxerman · Roland List · Christian Scaff
CSEE 4840 Embedded Systems — Columbia University, Spring 2026

---

## Slide 2 — Problem

**Every room colors the sound inside it**

- Room modes boost or cancel specific frequencies
- Speaker placement tilts the stereo image
- Absorptive materials roll off highs

**Goal:** Measure the room's frequency response, design a compensating FIR filter, output filter taps for downstream use.

---

## Slide 3 — Two-Phase Approach

**Measurement Phase**
- FPGA generates a logarithmic sine sweep (60 Hz → 20 kHz)
- WM8731 codec plays sweep through speakers, captures mic response
- Hardware FFT runs continuously — 8192-point frames

**Analysis Phase**
- HPS reads FFT bins over the lightweight bridge
- Computes correction curve and linear-phase FIR filter
- Writes 511 tap coefficients to a CSV file

---

## Slide 4 — High-Level System Architecture

> Insert: high-level Mermaid block diagram (from report § 2)

Key components:
- **ARM HPS (Linux):** `room_analyze` software, `/dev/mem` peripheral access
- **FPGA Fabric:** `room_eq_peripheral` (Avalon MM), PLL (12.288 MHz)
- **WM8731 Codec:** 24-bit ADC/DAC, I2S, programmed over I2C
- **Analog:** condenser mic in, speakers out

---

## Slide 5 — Room EQ Peripheral

> Insert: room_eq_peripheral Mermaid diagram (from report § Room EQ Peripheral)

- Top-level **Avalon MM slave** — 11 registers, 4-bit address
- 3-state FSM: IDLE → SWEEP → DONE
- Two clock domains: 50 MHz (sys) and 12.288 MHz (audio)
  - Toggle synchronizer for sweep_start (50→12.288 MHz)
  - 2-FF sync for sweep_done (12.288→50 MHz)

---

## Slide 6 — Sweep Generator

> Insert: sweep_generator Mermaid diagram (from report § Sweep Generator)

- **Phase Accumulator:** Q32.32 fixed-point, exponential frequency growth
  - 20 Hz → 20 kHz over ~10 s
  - `done` latches when increment threshold reached
- **Sine Lookup:** 1024-entry quarter-wave BRAM + 5-stage linear interpolation pipeline
  - Eliminates staircase aliasing at high frequencies
  - LUT initialized by HPS at startup via register writes

---

## Slide 7 — I2S & Codec Interface

**I2S Transmitter**
- Serializes 24-bit stereo samples, MSB-first, Philips I2S format
- `i2s_clock_gen` divides 12.288 MHz → 3.072 MHz BCLK, 48 kHz LRCK
- `i2s_shift_register` parallel-loads and shifts out 1 bit per BCLK

**I2S Receiver**
- Deserializes WM8731 ADC output — same BCLK/LRCK as TX
- Left channel: bit_cnt 1–24; right: 33–56

**WM8731 Codec** programmed over I2C at startup:
- 24-bit I2S slave mode, 48 kHz, mic or line-in selectable

---

## Slide 8 — Calibration Engine

> Insert: calibration_engine Mermaid diagram (from report § Calibration Engine)

Linear pipeline:
1. **sample_fifo** — captures I2S samples on bclk, crosses to sysclk via Quartus DCFIFO (showahead, 8192 deep)
2. **sample_fft** — 8192-point FFT IP; SOP/EOP framing via 13-bit sample counter
3. **fft_result_ram** — dual 8192×24-bit BRAM; `fft_done` latches on EOP

Two drain modes:
- **FFT mode (normal):** FFT backpressure controls FIFO reads
- **HPS mode (debug):** HPS pops FIFO directly via register write

---

## Slide 9 — HPS–FPGA Interface

-  Access via `/dev/mem` + `mmap`
- 2 MB window mapped at `0xFF200000` (lightweight HPS-to-FPGA bridge)
- Two peripherals derived from one mapping:
  - `i2c_base` (`+0x0000`) — I2C master for WM8731 codec config
  - `room_eq_base` (`+0x2000`) — Room EQ register bank
- All reads/writes are 32-bit word accesses through `volatile uint32_t *`

| Offset | Name | Access | Purpose |
|--------|------|--------|---------|
| 0 | CTRL | W | Pulse `sweep_start` (bit 0) |
| 1 | STATUS | R | Poll FSM state `[3:0]`, `fft_done` bit 4 |
| 4 | LUT_ADDR | W | Sine LUT write address (0–1023) |
| 5 | LUT_DATA | W | Sine LUT write data — triggers `we_lut` |
| 6 | FFT_ADDR | W | Select FFT bin to read (0–4096) |
| 7 | FFT_RDATA | R | Real part of FFT bin at FFT_ADDR |
| 8 | FFT_IDATA | R | Imaginary part of FFT bin at FFT_ADDR |

**I2C / WM8731 Codec Control** — `i2c_base` (`0xFF200000`)

- WM8731 7-bit address: `0x1A`
- Write codec register: send start bit + address to `I2C_TFR_CMD` (`+0x00`), then data bytes, then stop bit
- Poll `I2C_STATUS` (`+0x14`) for idle before each transaction
- Check `I2C_ISR` (`+0x10`) for NACK errors after each write

| Offset | Name | Purpose |
|--------|------|---------|
| `+0x00` | `I2C_TFR_CMD` | Write address/data with start/stop control bits |
| `+0x08` | `I2C_CTRL` | Enable core, set mode |
| `+0x10` | `I2C_ISR` | Interrupt status — bit 2 = NACK error |
| `+0x14` | `I2C_STATUS` | bit 0 = core busy (poll until 0) |
| `+0x20` | `I2C_SCL_LOW` | SCL low period (set to 250 → 500 ns period) |
| `+0x24` | `I2C_SCL_HIGH` | SCL high period |

---

## Slide 10 — HPS Software: DSP Pipeline

`room_analyze` executes 7 stages in order:

1. **Codec init** — I2C setup, 10 WM8731 registers
2. **LUT load** — 1024 quarter-wave samples written to FPGA BRAM
3. **Sweep + capture** — trigger sweep, poll `fft_done`, read up to 64 frames
4. **Room response** — peak magnitude per bin, 1/f compensation, 10% smoothing
5. **Correction curve** — invert response, clamp ±12 dB, blend by strength (0.5)
6. **FIR taps** — IFFT of correction curve, extract center 511 taps, Hanning window, normalize DC=1
7. **Output** — write `correction_taps.csv`, print terminal graph + room analysis report

---

## Slide 11 — Resource Utilization

Quartus compile — Cyclone V 5CSEMA5F31C6

| Resource | Used | Total | % |
|----------|------|-------|---|
| Logic (ALMs) | 5,912 | 32,070 | 18% |
| Registers | 12,607 | — | — |
| Pins | 362 | 457 | 79% |
| Block Memory Bits | 1,557,532 | 4,065,280 | 38% |
| RAM Blocks | 222 | 397 | 56% |
| DSP Blocks | 21 | 87 | 24% |
| PLLs | 1 | 6 | 17% |

**Key takeaways:** Logic very comfortable at 18%. RAM blocks at 56% driven by FFT IP + result RAM. Pins at 79% — board routes all DE1-SoC peripherals through the FPGA.

---

## Slide 12 — Demo Results

> Insert: correction_filter.jpeg (4-panel plot)

- **Top-left:** Raw + smoothed room response (55–85 dB, 60 Hz–20 kHz) — broad peak 3–10 kHz
- **Top-right:** Correction curve — +6.5 dB boost at low frequencies, −6 dB cut at high frequencies, clamped ±12 dB
- **Bottom-left:** 511-tap Hanning-windowed FIR impulse response — symmetric about tap 256
- **Bottom-right:** Original vs corrected response — noticeably flatter across the full band

---

## Slide 13 — Lessons Learned

*(Fill in per-person)*

**Jacob Boxerman**

**Roland List**

**Christian Scaff**

---

## Slide 14 — Questions?

Thank you.

Source code: `github.com/[your-repo]`
