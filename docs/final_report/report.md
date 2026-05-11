# CSEE 4840 Room EQ Correction Report

## 1. Introduction

Every listening room colors the sound played inside it: room modes boost or cancel specific frequencies, speaker placement tilts the stereo image, absorptive materials roll off highs. We propose to build a room-equalization device on the DE1-SoC that measures a particular room's magnitude response, designs a compensating FIR filter, and writes the resulting filter to a file for reuse. 

## 2. Hardware System Architecture

### Room EQ Peripheral

The Room EQ Peripheral is the top-level Avalon memory-mapped peripheral that integrates all hardware submodules. It exposes a 32-bit register interface to the HPS, manages a 3-state FSM controlling the sweep and capture flow, and bridges two clock domains — the 50 MHz system clock (`clk`) and the 12.288 MHz PLL audio clock (`audio_clk`) — with dedicated synchronizers. Audio conduit signals connect directly to the WM8731 codec pins on the DE1-SoC.

#### Interface

| Direction | Signal | Width | Description |
|-----------|--------|-------|-------------|
| Input | `clk` | 1 | 50 MHz system clock from Platform Designer |
| Input | `reset` | 1 | Active high system reset |
| Input | `writedata` | 32 | Data from HPS write |
| Output | `readdata` | 32 | Data returned to HPS on read |
| Input | `write` | 1 | Avalon write strobe |
| Input | `read` | 1 | Avalon read strobe |
| Input | `chipselect` | 1 | Peripheral select |
| Input | `address` | 4 | Register word offset (0–15) |
| Input | `audio_clk` | 1 | 12.288 MHz audio clock from PLL |
| Output | `AUD_XCK` | 1 | Master clock forwarded to codec |
| Output | `AUD_BCLK` | 1 | I2S bit clock to codec |
| Output | `AUD_DACDAT` | 1 | I2S DAC serial data to codec |
| Output | `AUD_DACLRCK` | 1 | I2S DAC frame clock to codec |
| Output | `AUD_ADCLRCK` | 1 | I2S ADC frame clock to codec (tied to `AUD_DACLRCK`) |
| Input | `AUD_ADCDAT` | 1 | I2S ADC serial data from codec |

#### Register Map

| Offset | Bits | Access | Name | Description |
|--------|------|--------|------|-------------|
| 0 | `[0]` | W | `CTRL` | `sweep_start` — one-cycle pulse to begin sweep; self-clears |
| 0 | `[1]` | R/W | `CTRL` | `fifo_hps_mode` — 1 = HPS drains FIFO directly, 0 = FFT drains |
| 1 | `[3:0]` | R | `STATUS` | FSM state — 0 = IDLE, 1 = SWEEP, 2 = DONE |
| 1 | `[4]` | R | `STATUS` | `fft_done` — high when FFT frame is complete and result RAM is valid |
| 1 | `[5]` | R | `STATUS` | `fifo_empty` — high when sample FIFO holds no data |
| 2 | — | — | — | Reserved |
| 3 | `[31:0]` | R | `VERSION` | Hardware version — reads `32'h0001_0000` |
| 4 | `[9:0]` | W | `LUT_ADDR` | Write address for sine LUT initialization (0–1023) |
| 5 | `[23:0]` | W | `LUT_DATA` | Write data for sine LUT — writing this register pulses `we_lut` |
| 6 | `[12:0]` | R/W | `FFT_ADDR` | Read address into FFT result RAM (0–8191) |
| 7 | `[23:0]` | R | `FFT_RDATA` | Real part of FFT bin at `FFT_ADDR` |
| 8 | `[23:0]` | R | `FFT_IDATA` | Imaginary part of FFT bin at `FFT_ADDR` |
| 9 | `[23:0]` | R | `ADC_LEFT` | Latest left-channel sample from I2S RX |
| 10 | `[23:0]` | R | `FIFO_RDATA` | Pop-on-read from sample FIFO (showahead) |

#### FSM

The peripheral contains a 3-state FSM clocked by `clk`.

| State | Description | Transitions |
|-------|-------------|-------------|
| `IDLE` | Waiting for HPS trigger | --> `SWEEP` on `sweep_start` write |
| `SWEEP` | Sweep active; calibration engine armed | --> `DONE` on rising edge of `sweep_done` (synchronized from audio domain) |
| `DONE` | FFT complete; result RAM available to HPS | --> `SWEEP` on `sweep_start` (allows re-trigger without full reset) |

On entering `SWEEP` from either `IDLE` or `DONE`, a one-cycle `calibrate_start` pulse is issued to arm the calibration engine's FFT pipeline.

#### Submodule Wiring

All submodules share `audio_clk` and a synchronized reset `sweep_reset` derived from the system `reset` via a 2-FF async-reset synchronizer in the audio domain.

`sweep_start` from the HPS (50 MHz domain) is transferred to the audio domain using a toggle synchronizer: the system clock toggles a flip-flop on each `sweep_start` pulse, and a 3-stage synchronizer in the audio domain detects the edge, producing a single-cycle `sweep_start_audio` pulse. `sweep_done` travels the other direction — a 2-FF synchronizer brings it from the audio domain back to `clk` for the FSM.

| Connection | From | To |
|------------|------|----|
| `amplitude` | `sweep_generator` | `i2s_tx` (both left and right channels) |
| `bclk_int`, `lrck_int` | `i2s_tx` | `i2s_rx`, `calibration_engine`, codec pins |
| `rx_left` | `i2s_rx` | `calibration_engine.left_chan` |
| `we_lut`, `lut_addr`, `lut_data` | Register write logic | `sweep_generator` |
| `fft_rd_addr` | Register write logic | `calibration_engine` |
| `fft_rd_real`, `fft_rd_imag` | `calibration_engine` | `readdata` (offsets 7, 8) |
| `fifo_data_out` | `calibration_engine` | `readdata` (offset 10), popped by `chipselect & read & address==10` |

### Clock Generator PLL

The Clock Generator PLL is a Quartus `altera_pll` IP core configured to synthesize a 12.288 MHz audio clock from the 50 MHz system reference clock. This frequency is the standard master clock for the WM8731 codec (256x oversampling at 48 kHz). All I2S and sweep generator logic is clocked from `outclk_0`.

#### Interface

| Direction | Signal | Width | Description |
|-----------|--------|-------|-------------|
| Input | `refclk` | 1 | 50 MHz system reference clock |
| Input | `rst` | 1 | Active-high reset |
| Output | `outclk_0` | 1 | 12.288 MHz audio clock output |
| Output | `locked` | 1 | High when PLL has achieved phase lock |

### Sweep Generator

The sweep generator module orchestrates the frequency sweep from 20 Hz to 20 KHz. On a start signal, the module resets and begins the sweep, outputting 24-bit signed sine values until 20 KHz is reached where a done signal is asserted. 

#### Interface

| Direction | Signal | Width | Description |
|-----------|--------|-------|-------------|
| Input | `clock` | 1 | 12.288 MHz PLL generated clock |
| Input | `reset` | 1 | Active high reset |
| Input | `clk_sys` | 1 | 50 MHz system clock, drives BRAM write port |
| Input | `we_lut` | 1 | Write enable (active high) — assert to write a sine value |
| Input | `addr_lut` | 10 | LUT write address (0–1023) |
| Input | `din_lut` | 24 | Signed sine value to store in LUT |
| Input | `start` | 1 | Trigger to start the sweep (requires 2-FF synchronizer — crosses clock domains) |
| Output | `amplitude` | 24 | Signed sine output for I2S TX |
| Output | `done` | 1 | Asserts and latches high when sweep reaches 20 kHz |

The sweep generator exposes the `addr_lut`, `din_lut`, and `we_lut` ports to the `sine_lookup` look up table (LUT). This allows the parent module to initialize the sine look up table with proper sine values prior to starting the sweep. The `sine_lookup` module is driven by a 50 MHz system clock `clk_sys`.

Upon `start` assertion, the module uses an internal 8-bit clock divider to convert the driving 12.288 MHz PLL clock to a 48 KHz sampling rate to drive the internal submodules `phase_accumulator` and `sine_lookup`.

The internal 32-bit phase signal is accumulated at increasing frequencies in the `phase_accumulator` module before being used to look up the associated sine amplitude value in `sine_lookup`. The resulting amplitude is outputted to the I2S TX module for transmission to the audio codec. When the sweep reaches 20 KHz, the amplitude cuts to 0 and a `done` signal is asserted.

![sweep_generator schematic](../../schematics/sweep_generator.svg)
*Sweep Generator — 8-bit clock divider driving phase_accumulator and sine_lookup, with LUT write port and amplitude/done outputs.*

### Phase Accumulator

The phase accumulator generates a 32-bit phase value that increases exponentially over time, driving the sine lookup with a continuously rising frequency. Starting at 20 Hz, the output frequency continuously doubles roughly, reaching 20 kHz after a 10-second sweep. When the upper frequency threshold is crossed, `done` latches high and accumulation stops.

#### Interface

| Direction | Signal | Width | Description |
|-----------|--------|-------|-------------|
| Input | `clock` | 1 | 12.288 MHz PLL generated clock |
| Input | `reset` | 1 | Active high reset — returns phase and increment to initial state |
| Input | `sample_en` | 1 | 48 kHz sample enable pulse, generated by the sweep generator clock divider |
| Output | `phase` | 32 | Current phase accumulator value, wraps naturally on overflow |
| Output | `done` | 1 | Latches high when the sweep reaches the 20 kHz threshold |

The accumulator maintains a 64-bit Q32.32 fixed-point register (`increment`) that tracks the instantaneous phase step per sample. On each `sample_en` pulse, two updates occur:

1. **Frequency growth** — the integer part of `increment` (`increment[63:32]`) is multiplied by the constant `K_FRAC = (K−1)×2^32`, where `K = exp(ln(1000) / (48000 × 10))`. Adding this product back to `increment` applies a per-sample exponential growth factor, producing a logarithmic (perceptually linear) frequency sweep.

2. **Phase accumulation** — the integer part of `increment` is added to the 32-bit `phase` register. Natural 32-bit overflow provides seamless phase wrapping with no additional logic.

On reset, `increment` is loaded with `INCREMENT_START = 1,789,570` (the Q32.32 encoding of the 20 Hz initial step size) and `phase` is cleared to zero. `done` is asserted and held once `increment[63:32]` reaches `INC_STOP = 1,789,569,707`, the threshold corresponding to a 20 kHz step size `(20000/48000) × 2^32`.

![phase_accumulator schematic](../../schematics/phase_accumulator.svg)
*Phase Accumulator — Q32.32 exponential sweep logic; increment register grows each sample until INC_STOP, asserting done.*

### Sine Lookup

The sine lookup module converts the 32-bit phase value from the phase accumulator into a 24-bit signed amplitude sample for the audio codec. To avoid staircase aliasing at high frequencies — where a large phase increment skips many LUT entries per sample — the module performs linear interpolation between adjacent entries using a 5-stage pipeline. A quarter-wave symmetry scheme means the underlying `sine_lut` BRAM only needs to store one quarter of a full sine period; the remaining three quadrants are reconstructed by mirroring the index and negating the output.

#### Interface

| Direction | Signal | Width | Description |
|-----------|--------|-------|-------------|
| Input | `clock` | 1 | 12.288 MHz PLL generated clock |
| Input | `reset` | 1 | Active high async reset |
| Input | `sample_en` | 1 | 48 kHz sample enable pulse from sweep generator |
| Input | `phase` | 32 | Current phase from phase accumulator |
| Input | `clk_sys` | 1 | 50 MHz system clock for LUT initialization |
| Input | `we_lut` | 1 | Write enable for LUT initialization |
| Input | `addr_lut` | 10 | Write address for LUT initialization (0–1023) |
| Input | `din_lut` | 24 | Sine value to write during LUT initialization |
| Output | `amplitude` | 24 | Interpolated, quadrant-corrected signed sine sample |

#### Phase Decomposition

The 32-bit phase word is split into three fields:

| Bits | Field | Purpose |
|------|-------|---------|
| `[31:30]` | `quadrant` | Selects which quarter-wave region (0–3) |
| `[29:20]` | `raw_index` | 10-bit integer LUT address within the quarter |
| `[19:10]` | `frac_bits` | 10-bit fractional position between two LUT entries |

In quadrants 1 and 3 the index is mirrored (`~raw_index`) to read the quarter-wave table in reverse, reconstructing the descending half of the sine. Quadrants 2 and 3 negate the interpolated result to produce the negative half-cycle.

#### Interpolation Pipeline

Each `sample_en` pulse advances a 5-state pipeline to produce one output sample:

| Cycle | Action |
|-------|--------|
| 0 | Present `index0` to BRAM read port; latch `quadrant`, `frac_bits`, `index1` |
| 1 | Wait — BRAM registers `mem[index0]` internally |
| 2 | Latch `val0 = lut_out`; present `index1` to BRAM read port |
| 3 | Wait — BRAM registers `mem[index1]` internally |
| 4 | Compute `interp = val0 + (lut_out − val0) * frac / 1024`; apply quadrant sign; output `amplitude` |

At 12.288 MHz with 256 clock cycles per 48 kHz sample period, the 5-cycle pipeline completes well before the next `sample_en` pulse.

![sine_lookup schematic](../../schematics/sine_lookup.svg)
*Sine Lookup — 5-stage interpolation pipeline; quadrant mirror logic and sine_lut BRAM read port.*

### Sine LUT

The sine LUT is a true dual-port block RAM storing 1024 entries of 24-bit signed sine values, representing one quarter-wave of a full sine period. Port A is write-only and driven by the 50 MHz system clock, used exclusively at startup to load pre-computed values from the HPS. Port B is read-only and driven by the 12.288 MHz audio clock, used by the `sine_lookup` interpolation pipeline during the sweep. The two ports operate in entirely separate clock domains; correct operation depends on all Port A writes completing before any Port B reads begin, which is guaranteed by system-level sequencing.

#### Interface

| Direction | Signal | Width | Clock Domain | Description |
|-----------|--------|-------|-------------|-------------|
| Input | `clk_a` | 1 | 50 MHz | Port A write clock |
| Input | `we_a` | 1 | `clk_a` | Write enable — high to write `din_a` into `mem[addr_a]` |
| Input | `addr_a` | 10 | `clk_a` | Write address (0–1023) |
| Input | `din_a` | 24 | `clk_a` | Signed sine value to store |
| Input | `clk_b` | 1 | 12.288 MHz | Port B read clock |
| Input | `addr_b` | 10 | `clk_b` | Read address driven by `sine_lookup` pipeline |
| Output | `dout_b` | 24 | `clk_b` | Sine value at `mem[addr_b]`, registered — valid 1 cycle after `addr_b` |

#### Port A — Write

On each rising edge of `clk_a`, if `we_a` is high, `din_a` is written into `mem[addr_a]`. No read capability exists on Port A.

#### Port B — Read

On each rising edge of `clk_b`, `dout_b` is registered from `mem[addr_b]`, giving a one-cycle read latency. The `sine_lookup` pipeline accounts for this latency with its explicit wait states at pipeline stages 1 and 3.

![sine_lut schematic](../../schematics/sine_lut.svg)
*Sine LUT — true dual-port 1024×24-bit BRAM; port A write at 50 MHz, port B read at 12.288 MHz.*

### Calibration Engine

The calibration engine captures the room's acoustic response by recording the microphone signal during a frequency sweep, streaming the samples through an FFT, and storing the resulting frequency-domain bins in a dual-port RAM for the HPS to read. It bridges two clock domains — the I2S bit clock (`bclk`) and the 50 MHz system clock (`sysclk`) — using a sample FIFO, and supports two drain modes: automatic FFT processing or direct HPS readout.

#### Interface

| Direction | Signal | Width | Description |
|-----------|--------|-------|-------------|
| Input | `sysclk` | 1 | 50 MHz system clock |
| Input | `bclk` | 1 | I2S bit clock |
| Input | `lrclk` | 1 | I2S left-right clock |
| Input | `aclr` | 1 | Active high async reset (spans both clock domains) |
| Input | `start` | 1 | One-cycle pulse to begin feeding samples into the FFT pipeline |
| Input | `left_chan` | 24 | 24-bit I2S serial audio data (left channel) |
| Input | `rd_addr` | 13 | RAM read address for HPS to retrieve FFT bins (0–8191) |
| Input | `fifo_hps_mode` | 1 | When high, HPS drains the sample FIFO directly instead of the FFT |
| Input | `fifo_hps_pop` | 1 | One-cycle pop pulse from HPS in `fifo_hps_mode` |
| Output | `rd_real` | 24 | Real part of FFT bin at `rd_addr` |
| Output | `rd_imag` | 24 | Imaginary part of FFT bin at `rd_addr` |
| Output | `fft_done` | 1 | Asserts when FFT processing is complete and RAM is ready to read |
| Output | `fifo_data_out` | 24 | Head of the sample FIFO (showahead — valid whenever `fifo_empty` is low) |
| Output | `fifo_data_valid` | 1 | High when the FIFO contains at least one sample |
| Output | `fifo_empty` | 1 | High when the FIFO is empty |

#### Submodules

The calibration engine composes three submodules in a linear pipeline:

| Submodule | Function |
|-----------|----------|
| `sample_fifo` | Captures incoming I2S samples on `bclk`/`lrclk` and crosses them into the `sysclk` domain via an async FIFO |
| `sample_fft` | Altera FFT IP core — consumes samples via an AXI-ST `sink` interface and produces complex bins on a `source` interface |
| `fft_result_ram` | Accepts FFT output bins and writes them into a dual-port RAM; asserts `fft_done` on end-of-packet |

#### Data Flow

On `start`, a `running` latch arms the FFT input gate. Samples arriving from `sample_fifo` are gated by `running & ~fifo_hps_mode` before being presented to `sample_fft`. This prevents the FFT from consuming stale samples before a sweep begins, and allows the HPS to inspect raw samples directly when `fifo_hps_mode` is asserted.

A consumer MUX on the FIFO read port selects between two drain paths: `fft_to_fifo_ready` (backpressure from the FFT core) in normal mode, or `fifo_hps_pop` (one-cycle pulses from the HPS) in HPS mode. The reset path uses a 2-FF synchronizer on `sysclk` to derive `reset_n` from the async `aclr`, ensuring a glitch-free active-low reset for the FFT IP core.

![calibration_engine schematic](../../schematics/calibration_engine.svg)
*Calibration Engine — CDC bridge from audio domain; sample_fifo, sample_fft, and fft_result_ram pipeline with HPS read mux.*

### Sample FIFO

The sample FIFO captures incoming I2S audio samples on the bit clock domain and makes them available to the FFT pipeline on the 50 MHz system clock domain. It wraps a Quartus-generated dual-clock FIFO (`capture_fifo`) with write and read request logic, using the falling edge of `lrclk` to clock in one 24-bit sample per stereo frame and backpressure from the FFT consumer to control the read side.

#### Interface

| Direction | Signal | Width | Description |
|-----------|--------|-------|-------------|
| Input | `bclk` | 1 | I2S bit clock (3.072 MHz) — write clock domain |
| Input | `lrclk` | 1 | I2S left-right clock (48 kHz) — used to detect new sample boundaries |
| Input | `left_chan` | 24 | 24-bit I2S audio sample (left channel) |
| Input | `sysclk` | 1 | 50 MHz system clock — read clock domain |
| Input | `aclr` | 1 | Active high async reset |
| Input | `fft_ready` | 1 | Backpressure signal from FFT — high when FFT can accept a sample |
| Output | `data_out` | 24 | 24-bit audio sample at the head of the FIFO |
| Output | `data_valid` | 1 | High when the FIFO is non-empty and `data_out` is valid |

#### Write Logic

A falling edge detector on `lrclk` (registered on `bclk`) produces a one-cycle `lrclk_neg_edge` pulse once per 48 kHz frame, marking the boundary of a new left-channel sample. A write request (`wrreq`) is asserted on that pulse only if the FIFO is not full (`~wrfull`), preventing overflow drops.

#### Read Logic

The read side is entirely driven by backpressure. `data_valid` is the logical inverse of `rdempty` — it is high whenever the FIFO holds at least one sample. A read request (`rdreq`) fires only when both `data_valid` and `fft_ready` are high, so the FIFO stalls automatically when the downstream FFT core is not ready to consume.

#### Clock Domain Crossing

The underlying `capture_fifo` is a Quartus DCFIFO primitive with `bclk` as the write clock and `sysclk` as the read clock. All gray-code pointer synchronization is handled internally by the IP, so no additional CDC logic is required in this module.

![sample_fifo schematic](../../schematics/sample_fifo.svg)
*Sample FIFO — wraps Quartus DCFIFO; write on lrclk falling edge (bclk domain), read driven by FFT backpressure or HPS pop (sysclk domain).*

### Sample FFT

The sample FFT module wraps a Quartus-generated 8192-point forward FFT IP core (`capture_fft`) with the SOP/EOP framing logic required by its variable-streaming interface. It accepts a stream of real-valued 24-bit audio samples from the sample FIFO and produces a stream of complex 24-bit frequency-domain bins. The imaginary input is tied to zero since all incoming samples are real.

#### Interface

| Direction | Signal | Width | Description |
|-----------|--------|-------|-------------|
| Input | `sysclk` | 1 | 50 MHz system clock |
| Input | `reset_n` | 1 | Active low reset |
| Input | `sink_real` | 24 | Real part of input sample from FIFO |
| Input | `sink_valid` | 1 | High when input sample is valid and ready to be consumed |
| Output | `sink_ready` | 1 | Backpressure from FFT core — high when the core can accept a sample |
| Output | `source_real` | 24 | Real part of FFT output bin |
| Output | `source_imag` | 24 | Imaginary part of FFT output bin |
| Output | `source_valid` | 1 | High when the output bin is valid |
| Output | `source_sop` | 1 | Start of packet — asserts on the first bin of each FFT frame |
| Output | `source_eop` | 1 | End of packet — asserts on the last bin of each FFT frame |

#### SOP/EOP Framing

The Quartus FFT IP selected uses a variable-streaming interface that requires explicit start-of-packet and end-of-packet signals on the sink side to delimit each 8192-sample frame. A 13-bit counter (`sample_count`) tracks the number of samples consumed by the core, incrementing on every valid handshake (`sink_valid & sink_ready`) and wrapping at 8191.

- `sink_sop` asserts when `sample_count == 0` (first sample of the frame)
- `sink_eop` asserts when `sample_count == 8191` (last sample of the frame)

#### Fixed Configuration

Several inputs to the underlying IP are tied to constants in this module:

| Signal | Value | Reason |
|--------|-------|--------|
| `fftpts_in` | 8192 | Fixed 8192-point transform |
| `inverse` | 0 | Forward FFT only — IFFT not used |
| `sink_imag` | 0 | Real-only input; no imaginary component |
| `source_ready` | 1 | Downstream RAM never stalls — no backpressure needed |
| `sink_error` | 0 | Error injection not used |

The core is instantiated as bidirectional (FFT + IFFT) solely because Quartus requires the bidirectional variant to support variable streaming with fixed-point precision. Only the forward direction is exercised.

![sample_fft schematic](../../schematics/sample_fft.svg)
*Sample FFT — wraps Quartus 8192-point FFT IP; 13-bit sample counter generates SOP/EOP framing for variable streaming.*

### FFT Result RAM

The FFT result RAM receives the complex frequency-domain bins from the FFT core and stores them in two 8192-entry 24-bit arrays — one for real parts, one for imaginary parts. Only 4097 entries are used per array. However, a 23-bit array is insufficient for such size. A sequential write pointer traverses the arrays as valid bins arrive, and `fft_done` latches high on the end-of-packet signal to notify the HPS that the full frame is ready. The HPS then reads any bin by supplying a 13-bit address, with a one-cycle read latency.

#### Interface

| Direction | Signal | Width | Description |
|-----------|--------|-------|-------------|
| Input | `sysclk` | 1 | 50 MHz system clock |
| Input | `reset_n` | 1 | Active low reset |
| Input | `fft_real` | 24 | Real part of incoming FFT bin |
| Input | `fft_imag` | 24 | Imaginary part of incoming FFT bin |
| Input | `fft_valid` | 1 | High when the current bin is valid (Avalon-ST) |
| Input | `data_sop` | 1 | Start of packet — marks the first bin of the FFT frame |
| Input | `data_eop` | 1 | End of packet — marks the last bin of the FFT frame |
| Input | `rd_addr` | 13 | Read address from HPS (0–8191) |
| Output | `rd_real` | 24 | Real part of stored bin at `rd_addr` (1-cycle latency) |
| Output | `rd_imag` | 24 | Imaginary part of stored bin at `rd_addr` (1-cycle latency) |
| Output | `fft_done` | 1 | Latches high when the full 8192-bin frame has been stored |

#### Write Logic

Bins are written only when `fft_valid` is high. On `data_sop`, the write pointer resets to zero, the first bin is stored at address 0, `fft_done` is cleared, and the pointer advances to 1. On each subsequent valid cycle the bin is stored at the current pointer address and the pointer increments. When `data_eop` arrives coincident with `fft_valid`, `fft_done` latches high, signalling the HPS that the RAM holds a complete spectrum.

#### Read Logic

Reads are synchronous with a one-cycle latency: `rd_real` and `rd_imag` reflect `ram_real[rd_addr]` and `ram_imag[rd_addr]` on the clock edge following the address being presented.

![fft_result_ram schematic](../../schematics/fft_result_ram.svg)
*FFT Result RAM — dual 8192×24-bit BRAMs storing real and imaginary FFT output; write pointer resets on SOP, fft_done latches on EOP.*

### I2S Transmitter

The I2S transmitter serializes stereo 24-bit parallel audio samples to the WM8731 codec using the standard Philips I2S format — MSB-first, 24 data bits followed by 8 padding bits per channel, with a 1-bit delay relative to the `lrck` frame boundary. The module runs entirely in the 12.288 MHz clock domain; `bclk` and `lrck` are data outputs driven by the module.

#### Interface

| Direction | Signal | Width | Description |
|-----------|--------|-------|-------------|
| Input | `clock` | 1 | 12.288 MHz master clock from PLL |
| Input | `reset` | 1 | Active high synchronous reset |
| Input | `left_sample` | 24 | Signed 24-bit left channel audio sample |
| Input | `right_sample` | 24 | Signed 24-bit right channel audio sample |
| Output | `bclk` | 1 | 3.072 MHz bit clock --> codec `AUD_BCLK` |
| Output | `lrck` | 1 | 48 kHz frame clock --> codec `AUD_DACLRCK` |
| Output | `dacdat` | 1 | Serial data --> codec `AUD_DACDAT` |

#### Submodules

| Submodule | Function |
|-----------|----------|
| `i2s_clock_gen` | Divides the 12.288 MHz master clock to generate `bclk` (3.072 MHz) and `lrck` (48 kHz), along with a `bclk_fall` strobe and a 6-bit `bit_cnt` (0–63) that tracks position within each 64-cycle stereo frame |
| `i2s_shift_register` | 24-bit parallel-load shift register that serializes one channel's sample MSB-first onto `dacdat` |

#### Data Flow

Both input samples are latched into hold registers two bit-clock cycles before the end of each frame (`bit_cnt == 62`), ensuring the inputs are stable before the upcoming load. The shift register is then loaded with the left channel at `bit_cnt == 63` and with the right channel at `bit_cnt == 31`. On all other falling `bclk` edges — except the two delay slots at `bit_cnt == 0` and `bit_cnt == 32` — the shift register shifts by one, advancing the next data bit onto `dacdat`. The two delay slots implement the 1-bit I2S framing delay, holding the MSB on the output for an extra cycle after each channel load before shifting begins.

![i2s_tx schematic](../../schematics/i2s_tx.svg)
*I2S Transmitter — i2s_clock_gen drives bclk/lrck timing; i2s_shift_register serializes left and right 24-bit samples with 1-bit framing delay.*

### I2S Clock Generator

The I2S clock generator derives a bit clock `BCLK` and frame clock `LRCK` from the 12.288 MHz system clock. These are outputted as data signals within the system clock domain.

#### Interface

| Direction | Signal | Width | Description |
|-----------|--------|-------|-------------|
| Input | `clock` | 1 | 12.288 MHz master clock from PLL |
| Input | `reset` | 1 | Active high synchronous reset |
| Output | `bclk` | 1 | 3.072 MHz bit clock (12.288 MHz / 4) --> codec `AUD_BCLK` |
| Output | `lrck` | 1 | 48 kHz frame clock (`bclk` / 64) — low = left channel, high = right channel --> codec `AUD_DACLRCK` |
| Output | `bclk_fall` | 1 | One-cycle strobe that fires one master-clock cycle before `bclk` falls; used by `i2s_tx` to time data shifts |
| Output | `bit_cnt` | 6 | Position within the current 64-bit I2S frame (0–63); increments on each `bclk_fall` and wraps naturally |

![i2s_clock_gen schematic](../../schematics/i2s_clock_gen.svg)
*I2S Clock Generator — 2-bit bclk_cnt divides 12.288 MHz by 4 to produce 3.072 MHz bclk; bit_cnt[5] drives lrck.*

### I2S Shift Register

Parallel-to-serial shift register for I2S data transmission. Loads a 24-bit sample and shifts it out MSB-first, one bit per shift pulse.  After 24 shifts, zeros pad the output.

#### Interface

| Direction | Signal | Width | Description |
|-----------|--------|-------|-------------|
| Input | `clock` | 1 | 12.288 MHz master clock |
| Input | `reset` | 1 | Active high synchronous reset — clears shift register to zero |
| Input | `data_in` | 24 | Parallel data to load |
| Input | `load` | 1 | One-cycle pulse — loads `data_in`; takes priority over `shift` |
| Input | `shift` | 1 | One-cycle pulse — shifts register left by 1, zero-fills LSB |
| Output | `serial_out` | 1 | MSB of shift register (combinational) |

![i2s_shift_register schematic](../../schematics/i2s_shift_register.svg)
*I2S Shift Register — parallel-load shift register; load has priority over shift, serial_out is combinational MSB.*

### I2S RX

This I2S receiver module deserializes stereo 24-bit audio from the WM8731 codec. It expects Philips I2S format: 1-bit delay, MSB-first, with 24 bits of data and 8 garbage bits per channel.

`bclk` and `lrck` are shared with the I2S transmitter and treated as data signals in the 12.288 MHz clock domain. The receiver derives rising and falling edge strobes from `bclk` by registering it against the master clock. A 6-bit `bit_cnt` mirrors the transmitter's counter, incrementing on each `bclk` falling edge. Serial data on `adcdat` is sampled on `bclk` rising edges: the left channel occupies `bit_cnt` 1–24 (one cycle after `lrck` falls, per the 1-bit I2S delay) and the right channel occupies `bit_cnt` 33–56. Each channel is shifted MSB-first into a 24-bit accumulator and latched into the output register on its final bit.

#### Interface

| Direction | Signal | Width | Description |
|-----------|--------|-------|-------------|
| Input | `clock` | 1 | 12.288 MHz master clock |
| Input | `reset` | 1 | Active high synchronous reset |
| Input | `bclk` | 1 | 3.072 MHz bit clock from `i2s_tx` — sampled as data |
| Input | `lrck` | 1 | 48 kHz frame clock from `i2s_tx` — low = left channel, high = right channel |
| Input | `adcdat` | 1 | Serial ADC data from codec (`AUD_ADCDAT`) |
| Output | `left_sample` | 24 | Deserialized left channel sample, updated once per frame |
| Output | `right_sample` | 24 | Deserialized right channel sample, updated once per frame |

![i2s_rx schematic](../../schematics/i2s_rx.svg)
*I2S Receiver — deserializes WM8731 ADC output; bclk/lrck treated as data inputs, samples captured on detected rising edges.*

## 2. Resource Utilization

## 3. Software System Architecture

### HPS–FPGA Interface

The software accesses all FPGA peripherals through the lightweight HPS-to-FPGA bridge, mapped into the HPS virtual address space using `/dev/mem`. At startup, `main` opens `/dev/mem` and calls `mmap` to map a 2 MB window starting at physical address `0xFF200000` (`LW_BRIDGE_BASE`) into process memory. Two typed pointers are then derived from this window:

| Pointer | Offset | Physical Base | Target |
|---------|--------|---------------|--------|
| `i2c_base` | `0x0000` | `0xFF200000` | Altera soft I2C master (codec control) |
| `room_eq_base` | `0x2000` | `0xFF202000` | Room EQ peripheral register bank |

All peripheral reads and writes are 32-bit word accesses through `volatile uint32_t *` pointers — no kernel driver is used. We attempted to build a kernel module based on lab three, however, were unable to get the device tree set up properly. We fell back on this design, trading off security for simplicity.

#### Room EQ Register Access

`room_eq_base` is indexed by word offset, matching the hardware register map:

| Offset | Name | Direction | Usage in software |
|--------|------|-----------|-------------------|
| 0 | `CTRL` | W | Write `(1 << 0)` to pulse `sweep_start` |
| 1 | `STATUS` | R | Poll `[3:0]` for FSM state (2 = DONE), `[4]` for `fft_done` |
| 4 | `LUT_ADDR` | W | Write sine LUT address (0–1023) before each `LUT_DATA` write |
| 5 | `LUT_DATA` | W | Write 24-bit sine sample; hardware pulses `we_lut` on each write |
| 6 | `FFT_ADDR` | W | Set bin index (0–4096) before reading result |
| 7 | `FFT_RDATA` | R | Read real part of FFT bin at `FFT_ADDR` |
| 8 | `FFT_IDATA` | R | Read imaginary part of FFT bin at `FFT_ADDR` |

#### I2C / WM8731 Register Access

`i2c_base` exposes the Altera I2C master's control registers. The software programs the codec over I2C by writing to `I2C_TFR_CMD` (`+0x00`) with start/stop control bits, reading `I2C_STATUS` (`+0x14`) to poll for idle, and checking `I2C_ISR` (`+0x10`) for NACK errors. The WM8731 7-bit I2C address is `0x1A`.

### Algorithmic Pipeline

The program executes the following stages in order.

**1. Hardware Setup** (`main` → `hw_codec_init`)

`/dev/mem` is opened and a 2 MB window is mapped. The Altera I2C master is configured (SCL period 500 ns), and 10 WM8731 registers are written over I2C to power up the codec, configure input gain (mic or line-in), enable DAC and ADC, set 24-bit I2S mode, and activate the digital core. This must complete before any audio signal is valid.

**2. Sine LUT Load** (`load_sine_lut`)

1024 quarter-wave samples are computed on the HPS as `sin(i * π / 2048) * 8388607` (scaled to 24-bit signed) and written to the FPGA sine LUT one entry at a time via `LUT_ADDR_REG` / `LUT_DATA_REG`. This initializes the sweep generator's BRAM before the sweep starts.

**3. Sweep and FFT Capture** (`capture_sweep`)

`CTRL_REG` is written with `sweep_start` (bit 0). The software then polls `STATUS_REG` in a tight loop. Each time bit 4 (`fft_done`) goes high, it reads all 4097 bins (`FFT_SIZE/2 + 1`) by writing `FFT_ADDR_REG` and reading `FFT_RDATA_REG` / `FFT_IDATA_REG` for each bin, storing the 24-bit sign-extended values into `frame_real[n]` / `frame_imag[n]`. After consuming a frame it waits for `fft_done` to deassert before continuing. The loop exits when `STATUS[3:0]` reaches `STATE_DONE` (2). Up to 64 frames are captured.

**4. Room Response Computation** (`compute_room_response`)

For each frequency bin, the peak magnitude across all captured frames is selected: `max(sqrt(re² + im²))`. Bins are then scaled by `freq_hz / 1000` to compensate for the 1/f energy distribution of a logarithmic sweep. The resulting spectrum is smoothed with a proportional-bandwidth (10%) sliding window to reduce noise before subsequent stages.

**5. Correction Curve Computation** (`compute_correction`)

The mean level of the smoothed response is computed over the target correction range (default 60 Hz – 20 kHz). Each bin's correction gain is set to the inverse of its normalized response (`1 / H_norm`), clamped to ±`max_db` (default ±12 dB), then blended toward unity by `strength` (default 0.5): `c = 1 + strength * (c - 1)`. Bins outside the correction range are set to unity gain.

**6. FIR Tap Computation** (`compute_fir_taps`)

The correction gain array (real-valued, one entry per bin) is treated as a half-complex frequency-domain spectrum and transformed to the time domain with FFTW's `c2r` inverse FFT. The center `n_taps` samples (default 511) are extracted from the wrap-around impulse response, multiplied by a Hanning window, and normalized so the DC gain equals 1. The result is a linear-phase FIR filter whose frequency response approximates the target correction curve.

**7. Output**

The `n_taps` tap coefficients are written one per line to a CSV file (default `correction_taps.csv`). A terminal frequency-response graph (32 log-spaced rows, 50-character bars) and a room analysis report listing peaks, dips, and standard deviation are printed to stdout.

## 4. Demo



**TODO: Resource Utilization and Timing Closure**
**Software Side**
**Block Diagram**
