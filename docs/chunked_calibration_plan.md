# Chunked Calibration Implementation Plan

Complete implementation plan for room EQ calibration. Three tasks:
build the I2S receiver, fix the FSM to capture during the sweep,
and write the chunked software read loop.

FIR engine and tap loading are out of scope. The deliverable is:
sweep the room, capture the response, compute and display the
correction filter.

---

## 1. Architecture

### What exists and works

```
sweep_generator ──► i2s_tx ──► AUD_DACDAT ──► codec DAC ──► LINE OUT ──► speaker
                                                    ▲
                                              12.288 MHz PLL
                                              (AUD_XCK, AUD_BCLK, AUD_DACLRCK)

mic ──► LINE IN ──► codec ADC ──► AUD_ADCDAT ──► ??? (not wired)

sample_fifo (DCFIFO 8192x24) ──► sample_fft (Quartus FFT IP) ──► fft_result_ram
                                                                       │
                                                              HPS reads via ioctl
```

### What's missing

1. **I2S RX module** — deserialize AUD_ADCDAT into 24-bit parallel samples
2. **FSM fix** — start capture when sweep starts, not after it ends
3. **Chunk counter register** — HPS needs to know which FFT frame is ready
4. **Software chunked loop** — read active bins from each chunk, assemble spectrum

### Target architecture

```
sweep_generator ──► i2s_tx ──────► AUD_DACDAT ──► codec DAC ──► LINE OUT
                         │
                    AUD_BCLK, AUD_DACLRCK (shared clocks)
                         │
mic ──► LINE IN ──► codec ADC ──► AUD_ADCDAT ──► i2s_rx ──► left_sample [23:0]
                                                                 │
                                                          calibration_engine
                                                     ┌───────────┴──────────┐
                                                sample_fifo ► sample_fft ► fft_result_ram
                                                (8192x24 DCFIFO)  (8192-pt)   (2x 8192x24)
                                                                                    │
                                                                HPS reads via ioctl ◄┘
                                                                     │
                                                              spectrum assembly
                                                                     │
                                                               fir_design_from_spectrum()
                                                                     │
                                                              128 Q1.23 taps
                                                              (written to file)
```

---

## 2. Timing Analysis

### 2.1 Clocks

| Clock | Frequency | Period | Source |
|-------|-----------|--------|--------|
| sys_clk | 50.000 MHz | 20 ns | Board oscillator |
| audio_clk | 12.288 MHz | 81.4 ns | PLL in Platform Designer |
| BCLK | 3.072 MHz | 325.5 ns | audio_clk / 4 (i2s_clock_gen) |
| LRCK | 48.000 kHz | 20.83 us | BCLK / 64 (i2s_clock_gen) |

### 2.2 Sweep parameters (from phase_accumulator.sv)

```
Start frequency:     20 Hz
End frequency:       20,000 Hz (20 kHz)
Growth factor K:     exp(ln(1000) / 240000) = 1.00002878...
Sample rate:         48,000 Hz
Sweep duration:      240,000 samples = 5.000 s
Sweep type:          Exponential (log) — f(n) = 20 * K^n
```

Hardware constants (phase_accumulator.sv):
```
INCREMENT_START = 32'd1_789_570     = (20/48000) * 2^32
K_FRAC          = 32'd123_621       = (K-1) * 2^32
INC_20KHZ       = 32'd1_789_569_707 = (20000/48000) * 2^32
```

### 2.3 FFT parameters

```
FFT size N:          8,192 points
Unique bins:         N/2 + 1 = 4,097 (Hermitian symmetry)
Bin spacing:         48000 / 8192 = 5.859375 Hz
Bin 0:               DC (0 Hz)
Bin 4096:            Nyquist (24,000 Hz)
Data format:         24-bit signed fixed-point (Q1.23)
FFT IP:              Altera FFT II MegaCore (capture_fft)
FFT mode:            Forward only (inverse=0), variable streaming
Arithmetic:          Fixed-point (not BFP — Quartus forced this for variable streaming)
```

### 2.4 Chunk timing

```
Samples per chunk:   8,192
Time per chunk:      8192 / 48000 = 170.667 ms
Total chunks:        floor(240000 / 8192) = 29
Samples in 29 chunks: 29 * 8192 = 237,568
Leftover samples:    240,000 - 237,568 = 2,432 (tail end of sweep, discarded)
Last chunk sweep:    ~19,200 Hz at start of chunk 28
```

### 2.5 DCFIFO (capture_fifo)

```
Width:               24 bits
Depth:               8,192 entries
Write clock:         BCLK domain (via sample_fifo lrclk edge detect → 48 kHz writes)
Read clock:          sys_clk (50 MHz, gated by FFT sink_ready)
Total storage:       8192 * 24 = 196,608 bits = 192 Kbit
```

The FIFO is deep enough to hold an entire FFT frame. While the FFT IP
processes one frame internally (sink_ready low, ~2-5 ms), at most
48000 * 0.005 = 240 samples arrive. The 8192-deep FIFO will never
overflow.

### 2.6 FFT result RAM (fft_results_ram.sv)

```
Two arrays:          ram_real[8191:0], ram_imag[8191:0]
Width:               24 bits each
Total:               2 * 8192 * 24 = 393,216 bits = 384 Kbit
Write port:          FFT output (sys_clk, gated by fft_valid)
Read port:           HPS via fft_rd_addr (sys_clk, 1-cycle latency)
fft_done:            Asserts on data_eop, clears on next data_sop
```

### 2.7 HPS read window

After fft_done asserts for chunk N, the RAM is stable until the NEXT
chunk's FFT output starts streaming (next data_sop):

```
Gap = (time to collect next 8192 samples) + (FFT pipeline latency)
    = 170.667 ms + ~2-5 ms
    = ~173-176 ms
```

HPS read cost per bin:
```
ioctl(WRITE_FFT_ADDR):    copy_from_user + iowrite32 ≈ 2-3 us
ioctl(READ_FFT_DATA):     2x ioread32 + copy_to_user ≈ 2-3 us
Total per bin:             ~4-5 us
```

Read time for different scenarios:
```
All 4097 bins:       4097 * 5 us = 20.5 ms
200 active bins:     200 * 5 us  = 1.0 ms
600 active bins:     600 * 5 us  = 3.0 ms
```

Margin:
```
Worst case (all bins): 173 ms / 20.5 ms = 8.4x headroom
Typical (200 bins):    173 ms / 1.0 ms  = 173x headroom
```

No double-buffering or handshaking needed.

### 2.8 Bin ranges per chunk

Sweep frequency at global sample n:
```
f(n) = 20 * (20000/20)^(n/240000) = 20 * 1000^(n/240000)
```

FFT bin for frequency f:
```
k = f / 5.859375
```

Computed ranges:

```
Chunk   Samples            Sweep freq (Hz)     FFT bins     Bin count
─────   ───────            ───────────────     ────────     ─────────
  0        0 -   8191       20.0 -    27.2      3 -     5        3
  1     8192 -  16383       27.2 -    37.1      5 -     7        3
  2    16384 -  24575       37.1 -    50.5      6 -     9        4
  3    24576 -  32767       50.5 -    68.7      9 -    12        4
  4    32768 -  40959       68.7 -    93.6     12 -    16        5
  5    40960 -  49151       93.6 -   127.3     16 -    22        7
  6    49152 -  57343      127.3 -   173.3     22 -    30        9
  7    57344 -  65535      173.3 -   235.9     30 -    41       12
  8    65536 -  73727      235.9 -   321.1     40 -    55       16
  9    73728 -  81919      321.1 -   437.0     55 -    75       21
 10    81920 -  90111      437.0 -   594.9     75 -   102       28
 11    90112 -  98303      594.9 -   809.7    102 -   139       38
 12    98304 - 106495      809.7 -  1102.1    138 -   189       52
 13   106496 - 114687     1102.1 -  1500.0    188 -   256       69
 14   114688 - 122879     1500.0 -  2041.4    256 -   349       94
 15   122880 - 131071     2041.4 -  2778.3    348 -   475      128
 16   131072 - 139263     2778.3 -  3781.0    474 -   646      173
 17   139264 - 147455     3781.0 -  5145.7    645 -   879      235
 18   147456 - 155647     5145.7 -  7003.4    878 -  1196      319
 19   155648 - 163839     7003.4 -  9530.6   1195 -  1627      433
 20   163840 - 172031     9530.6 - 12970.4   1627 -  2214      588
 21   172032 - 180223    12970.4 - 17651.3   2213 -  3013      801
 22   180224 - 188415    17651.3 - 20000+    3012 -  3413      402
 23+  (sweep done for remaining chunks — bins filled by chunk 22)
```

Note: The exponential sweep reaches 20 kHz around sample ~240,000.
Chunks 23-28 will contain sweep frequencies at or above 20 kHz.
The phase_accumulator latches done when the increment reaches INC_20KHZ.
Useful data ends around chunk 22-23.

Total unique bins filled: ~3,500-4,000 out of 4,097 (85-97% coverage).
Unfilled bins: DC (bin 0), near-DC (bins 1-2), and above 20 kHz.

---

## 3. Hardware Task 1: I2S Receiver

### 3.1 Specification

New file: `src/hardware/room_eq_peripheral/i2s_rx/i2s_rx.sv`

```
Module name:     i2s_rx
Clock domain:    12.288 MHz (audio_clk), same as i2s_tx
Data format:     Philips I2S — MSB-first, 1-bit delay, 24 data + 8 pad
Frame:           64 BCLK cycles per stereo frame (32 left + 32 right)
```

Port list:
```
Port            Dir     Width   Description
──────────────  ───     ─────   ──────────────────────────────────────
clock           in      1       12.288 MHz master clock
reset           in      1       Active-high synchronous reset
bclk            in      1       3.072 MHz bit clock (from i2s_clock_gen via i2s_tx)
lrck            in      1       48 kHz frame clock (from i2s_clock_gen via i2s_tx)
adcdat          in      1       Serial data from codec ADC (PIN_K7)
left_sample     out     24      Deserialized left channel sample
right_sample    out     24      Deserialized right channel sample
sample_valid    out     1       One-cycle pulse when new stereo pair is latched
```

### 3.2 I2S Receive Timing

The codec outputs ADCDAT synchronized to BCLK, framed by ADCLRCK.
We share BCLK and LRCK with i2s_tx (the FPGA is the I2S master for
both directions).

I2S frame structure (64 BCLK cycles):
```
bit_cnt:  63  0  1  2  3  ... 24 25 ... 31 32 33 34 ... 56 57 ... 63
LRCK:      H  L  L  L  L  ...  L  L  ...  L  H  H  H  ...  H  H  ...  H
                  ▲                            ▲
                  │ 1-bit delay                │ 1-bit delay
ADCDAT:    x  x  MSB ............. LSB  pad    x  MSB ............. LSB pad
              └── left channel data ──┘            └── right channel data ──┘
```

The 1-bit I2S delay means:
- Left channel MSB appears at bit_cnt = 1 (one BCLK after LRCK goes low)
- Left channel LSB appears at bit_cnt = 24
- bit_cnt 0 is the "delay slot" (data not yet valid)
- bit_cnt 25-31 are don't-care padding
- Right channel MSB at bit_cnt = 33, LSB at bit_cnt = 56

### 3.3 Implementation

The i2s_rx module does NOT instantiate its own i2s_clock_gen. It
receives bclk and lrck as inputs (generated by i2s_tx's clock_gen).
It needs its own bclk_rise detector and bit counter synchronized to
the same frame:

```systemverilog
module i2s_rx (
    input  logic        clock,        // 12.288 MHz
    input  logic        reset,
    input  logic        bclk,         // 3.072 MHz from i2s_tx clock_gen
    input  logic        lrck,         // 48 kHz from i2s_tx clock_gen
    input  logic        adcdat,       // serial data from codec
    output logic [23:0] left_sample,
    output logic [23:0] right_sample,
    output logic        sample_valid
);

    // ── BCLK edge detection ──────────────────────────────
    // bclk is a data signal toggled at 12.288/4 = 3.072 MHz.
    // We sample it at 12.288 MHz and detect rising edges.
    logic bclk_d;
    wire  bclk_rise = bclk && !bclk_d;

    always_ff @(posedge clock) begin
        if (reset) bclk_d <= 1'b0;
        else       bclk_d <= bclk;
    end

    // ── Bit counter ──────────────────────────────────────
    // Counts 0-63 within each I2S frame, synchronized to LRCK.
    // Resets to 0 on the BCLK rising edge where LRCK goes low.
    logic [5:0] bit_cnt;
    logic       lrck_d;

    always_ff @(posedge clock) begin
        if (reset) begin
            bit_cnt <= 6'd0;
            lrck_d  <= 1'b0;
        end else if (bclk_rise) begin
            lrck_d <= lrck;
            if (lrck_d && !lrck)      // LRCK falling edge = start of left
                bit_cnt <= 6'd0;
            else
                bit_cnt <= bit_cnt + 6'd1;
        end
    end

    // ── Shift register ───────────────────────────────────
    // Shifts in ADCDAT on every BCLK rising edge during data slots.
    // Left channel: bits 1-24 (bit_cnt 1..24, after 1-bit delay)
    // Right channel: bits 33-56 (bit_cnt 33..56)
    logic [23:0] shift_l, shift_r;

    always_ff @(posedge clock) begin
        if (reset) begin
            shift_l <= 24'd0;
            shift_r <= 24'd0;
        end else if (bclk_rise) begin
            // Left channel data: bit_cnt 1..24
            if (bit_cnt >= 6'd1 && bit_cnt <= 6'd24)
                shift_l <= {shift_l[22:0], adcdat};
            // Right channel data: bit_cnt 33..56
            if (bit_cnt >= 6'd33 && bit_cnt <= 6'd56)
                shift_r <= {shift_r[22:0], adcdat};
        end
    end

    // ── Output latch ─────────────────────────────────────
    // Latch complete samples after right channel is done (bit_cnt 57).
    // Pulse sample_valid for one 12.288 MHz cycle.
    always_ff @(posedge clock) begin
        if (reset) begin
            left_sample  <= 24'd0;
            right_sample <= 24'd0;
            sample_valid <= 1'b0;
        end else begin
            sample_valid <= 1'b0;
            if (bclk_rise && bit_cnt == 6'd57) begin
                left_sample  <= shift_l;
                right_sample <= shift_r;
                sample_valid <= 1'b1;
            end
        end
    end

endmodule
```

### 3.4 Codec ADC configuration

The WM8731 codec is already configured for ADC capture in the driver
(room_eq.c codec_init):

```
Register 0x00: Left Line In = 0x017  → 0 dB gain, no mute
Register 0x01: Right Line In = 0x017 → 0 dB gain, no mute
Register 0x04: Analog Path  = 0x012  → DAC selected, LINE IN to ADC
Register 0x06: Power Down   = 0x000  → All blocks on (including ADC)
Register 0x07: Format       = 0x00A  → I2S, 24-bit, slave mode
Register 0x08: Sampling     = 0x000  → Normal mode, 48 kHz
Register 0x09: Active       = 0x001  → Digital audio interface active
```

The ADC is on and routed from LINE IN. No driver changes needed for
audio capture — only the FPGA side is missing.

### 3.5 ADCDAT timing from the codec

In slave mode, the WM8731 clocks ADCDAT using the BCLK and ADCLRCK
provided by the FPGA master. Data transitions on BCLK falling edge,
is stable for sampling on BCLK rising edge. This matches our
bclk_rise-based sampling.

ADCLRCK must be driven by the FPGA. We use the same LRCK signal as
DACLRCK (both clocks are identical in frequency and phase):

```systemverilog
assign AUD_ADCLRCK = AUD_DACLRCK;
```

---

## 4. Hardware Task 2: FSM and Register Changes

### 4.1 Current FSM (BROKEN)

File: `src/hardware/room_eq_peripheral/room_eq_peripheral.sv`, lines 164-192

```
IDLE ──sweep_start──► SWEEP ──sweep_done──► CAPTURE ──fft_done──► DONE
                                                 ▲
                                          calibrate_start fires HERE
                                          (after sweep, capturing silence)
```

### 4.2 New FSM

```
IDLE ──sweep_start──► CALIBRATING ──sweep_done──► DONE
              ▲
       calibrate_start fires HERE
       (simultaneous with sweep)
       FFTs cycle continuously during CALIBRATING
       chunk_count increments on each fft_done rising edge
```

### 4.3 New signals

```systemverilog
// Add to signal declarations (after line 76):
logic        fft_done_prev;
logic [7:0]  chunk_count;
```

### 4.4 FSM state enum

Replace lines 79-85:

```systemverilog
typedef enum logic [3:0] {
    IDLE        = 4'd0,
    CALIBRATING = 4'd1,
    DONE        = 4'd3
} state_t;
state_t state;
```

### 4.5 Chunk counter

Insert before the FSM (after the synchronization block):

```systemverilog
// ── Chunk counter ────────────────────────────────────
// Increments on each rising edge of fft_done.
// Each rising edge = one complete 8192-point FFT frame written to RAM.
always_ff @(posedge clk) begin
    if (reset) begin
        fft_done_prev <= 1'b0;
        chunk_count   <= 8'd0;
    end else begin
        fft_done_prev <= fft_done;
        if (state == IDLE)
            chunk_count <= 8'd0;              // reset on new calibration
        else if (fft_done && !fft_done_prev)  // rising edge of fft_done
            chunk_count <= chunk_count + 8'd1;
    end
end
```

### 4.6 New FSM logic

Replace lines 164-192:

```systemverilog
// ── FSM ─────────────────────────────────────
always_ff @(posedge clk) begin
    if (reset) begin
        state           <= IDLE;
        calibrate_start <= 1'b0;
    end else begin
        calibrate_start <= 1'b0;             // default: one-cycle pulse
        case (state)
            IDLE: begin
                if (sweep_start) begin
                    state           <= CALIBRATING;
                    calibrate_start <= 1'b1; // arm capture engine NOW
                end
            end
            CALIBRATING: begin
                // sweep and capture run simultaneously.
                // FFTs cycle automatically (sample_fft wraps at 8191).
                // fft_done toggles once per chunk.
                if (done_sync2)              // sweep finished
                    state <= DONE;
            end
            DONE: begin
                // Sticky. HPS reads final chunk, then can re-trigger.
                if (sweep_start)
                    state <= IDLE;
            end
        endcase
    end
end
```

### 4.7 Register read update

Replace lines 87-100:

```systemverilog
// ── Register read ───────────────────────────────────────
always_comb begin
    readdata = 32'd0;
    if (chipselect && read)
        case (address)
            4'd0: readdata = 32'd0;                    // CTRL (write-only)
            4'd1: readdata = {28'd0, state};           // STATUS
            4'd2: readdata = {24'd0, chunk_count};     // CHUNK_COUNT (new)
            4'd3: readdata = 32'h0002_0000;            // VERSION (bumped)
            4'd6: readdata = {19'd0, fft_rd_addr};     // FFT_ADDR
            4'd7: readdata = {8'd0, fft_rd_real};      // FFT_RDATA
            4'd8: readdata = {8'd0, fft_rd_imag};      // FFT_IDATA
            default: readdata = 32'd0;
        endcase
end
```

### 4.8 Register write — no changes needed

The existing register write block (lines 102-125) handles CTRL,
LUT_ADDR, LUT_DATA, and FFT_ADDR. No new writable registers are
needed for the chunked calibration (CHUNK_COUNT is read-only).

### 4.9 Updated register map

```
Word    Byte    Bits     Access  Name          Description
────    ────    ────     ──────  ────          ───────────
 0      0x00    [0]      W       CTRL          sweep_start (self-clears)
 1      0x04    [3:0]    R       STATUS        0=IDLE, 1=CALIBRATING, 3=DONE
 2      0x08    [7:0]    R       CHUNK_COUNT   Completed FFT chunks (0 before first)
 3      0x0C    [31:0]   R       VERSION       32'h0002_0000
 4      0x10    [7:0]    W       LUT_ADDR      Sine LUT write address
 5      0x14    [23:0]   W       LUT_DATA      Sine LUT write data (fires we_lut)
 6      0x18    [12:0]   R/W     FFT_ADDR      FFT result RAM read address
 7      0x1C    [23:0]   R       FFT_RDATA     FFT real part at FFT_ADDR
 8      0x20    [23:0]   R       FFT_IDATA     FFT imag part at FFT_ADDR
```

Address field is 4 bits (offsets 0-15). Only 9 used. No width change.

---

## 5. Hardware Task 3: Wiring

### 5.1 room_eq_peripheral.sv — new ports

Add to the module port list (after line 42):

```systemverilog
    input  logic        AUD_ADCDAT,   // I2S serial data from codec ADC
    output logic        AUD_ADCLRCK   // I2S ADC frame clock (= DACLRCK)
```

### 5.2 room_eq_peripheral.sv — I2S RX instance

Replace lines 232-234 (the TODO block) with:

```systemverilog
    // ── I2S receiver ─────────────────────────────────────
    logic [23:0] i2s_rx_left;
    logic [23:0] i2s_rx_right;
    logic        i2s_rx_valid;

    assign AUD_ADCLRCK = AUD_DACLRCK;  // shared frame clock

    i2s_rx i2s_rx_inst (
        .clock       (audio_clk),
        .reset       (sweep_reset),
        .bclk        (AUD_BCLK),
        .lrck        (AUD_DACLRCK),
        .adcdat      (AUD_ADCDAT),
        .left_sample (i2s_rx_left),
        .right_sample(i2s_rx_right),
        .sample_valid(i2s_rx_valid)
    );
```

### 5.3 room_eq_peripheral.sv — connect to calibration engine

Replace line 213:

```systemverilog
// OLD: .left_chan(left_chan_tb), // TODO: Replace with I2S RX output when RX is wired up.
// NEW:
        .left_chan(i2s_rx_left),
```

Remove the `left_chan_tb` signal declaration (line 65):

```systemverilog
// DELETE: logic [23:0] left_chan_tb;
```

### 5.4 soc_system_top.sv — wire AUD_ADCDAT and AUD_ADCLRCK

Add to the Platform Designer instance (after line 275):

```systemverilog
     .audio_adcdat                 ( AUD_ADCDAT ),
     .audio_adclrck                ( AUD_ADCLRCK ),
```

Remove line 298:

```systemverilog
// DELETE: assign AUD_ADCLRCK = 1'b0;
```

### 5.5 room_eq_peripheral_hw.tcl — new source file

Add after line 53 (calibration_engine.sv):

```tcl
add_fileset_file i2s_rx.sv SYSTEM_VERILOG PATH ../src/hardware/room_eq_peripheral/i2s_rx/i2s_rx.sv
```

### 5.6 room_eq_peripheral_hw.tcl — new conduit ports

Add after line 150 (AUD_XCK):

```tcl
add_interface_port audio AUD_ADCDAT  adcdat  Input  1
add_interface_port audio AUD_ADCLRCK adclrck Output 1
```

### 5.7 Platform Designer regeneration

After editing the TCL, open Platform Designer in Quartus:
1. Open `lab3-hw/soc_system.qsys`
2. The room_eq component should show the new audio conduit ports
3. Re-export the new ports (adcdat, adclrck) to the top level
4. Generate HDL → produces updated `soc_system.v` wrapper
5. The new port names in soc_system_top.sv (5.4) must match the
   generated wrapper's port names exactly

### 5.8 Pin assignments (already in .qsf)

These already exist in `lab3-hw/soc_system.qsf` — no changes needed:

```
PIN_K7  →  AUD_ADCDAT   (3.3-V LVTTL, input)
PIN_K8  →  AUD_ADCLRCK  (3.3-V LVTTL, inout — now driven as output)
```

### 5.9 Calibration engine — no changes

`calibration_engine.sv`, `sample_fft.sv`, and `fft_results_ram.sv`
need zero modifications. The `running` latch already works: it latches
high on `start` and stays high. The only change is WHEN `start` fires
(now at sweep begin, handled by FSM change in section 4).

The FFT pipeline cycles naturally:
- `sample_fft.sv` wraps sample_count at 8191, auto-generating SOP/EOP
- `fft_result_ram.sv` resets write_addr on SOP, asserts fft_done on EOP
- Next frame's SOP clears fft_done and starts overwriting

---

## 6. Software Task 1: Driver Changes

### 6.1 New register offset

File: `src/software/room_eq/device_drivers/room_eq.c`

```c
#define REG_CHUNK_COUNT  0x08   /* R    [7:0] completed FFT chunks  */
```

### 6.2 New ioctl struct

File: `src/software/room_eq/device_drivers/room_eq.h`

```c
typedef struct {
    unsigned int count;     // [7:0] completed chunk count
} room_eq_chunk_count_t;
```

### 6.3 New ioctl command

File: `src/software/room_eq/device_drivers/room_eq.h`

```c
#define ROOM_EQ_READ_CHUNK_COUNT  _IOR(ROOM_EQ_MAGIC, 8, room_eq_chunk_count_t)
```

### 6.4 Driver ioctl case

File: `src/software/room_eq/device_drivers/room_eq.c`

Add to the switch statement (after the ROOM_EQ_READ_FFT_DATA case):

```c
case ROOM_EQ_READ_CHUNK_COUNT: {
    room_eq_chunk_count_t cc;
    cc.count = eq_rd(REG_CHUNK_COUNT) & 0xFFu;
    if (copy_to_user((room_eq_chunk_count_t *)arg, &cc, sizeof(cc)))
        return -EACCES;
    break;
}
```

Add `room_eq_chunk_count_t` to the local variable declarations in
room_eq_ioctl (or declare inline as shown above).

### 6.5 FSM state constants update

File: `src/software/eq.c`

```c
// Replace STATE_SWEEP, STATE_CAPTURE with:
#define STATE_IDLE        0u
#define STATE_CALIBRATING 1u
#define STATE_DONE        3u
```

---

## 7. Software Task 2: Chunked Calibration Loop

### 7.1 New constants

File: `src/software/eq.h`

```c
#define N_FFT       8192
#define N_HALF      (N_FFT / 2 + 1)        /* 4097 */
#define N_LUT       256
#define FS          48000
#define F_START     20.0
#define F_END       20000.0
#define SWEEP_SAMPS (FS * 5)                /* 240000 */
#define N_CHUNKS    (SWEEP_SAMPS / N_FFT)   /* 29 */
#define BIN_WIDTH   ((double)FS / N_FFT)    /* 5.859375 Hz */
```

### 7.2 Sweep frequency helpers

File: `src/software/eq.c` (or eq.h as static inline)

```c
/*
 * sweep_freq — instantaneous frequency at global sample index n.
 * Matches phase_accumulator.sv exponential sweep.
 */
static double sweep_freq(int n)
{
    return F_START * pow(F_END / F_START, (double)n / SWEEP_SAMPS);
}

/*
 * chunk_bin_range — compute which FFT bins are excited during chunk c.
 * Returns inclusive range [k_lo, k_hi].
 */
static void chunk_bin_range(int chunk, int *k_lo, int *k_hi)
{
    double f_lo = sweep_freq(chunk * N_FFT);
    double f_hi = sweep_freq((chunk + 1) * N_FFT - 1);
    *k_lo = (int)floor(f_lo / BIN_WIDTH);
    *k_hi = (int)ceil(f_hi / BIN_WIDTH);
    if (*k_lo < 1)        *k_lo = 1;          /* skip DC */
    if (*k_hi >= N_HALF)  *k_hi = N_HALF - 1;
}
```

### 7.3 Main function rewrite

Replace the current main() in eq.c. The structure stays the same
(open device, load LUT, trigger sweep, read, design, close) but
step 5 becomes a chunked loop:

```c
int main(void)
{
    int ret = 0;
    int fd = open(DEVICE_PATH, O_RDWR);
    if (fd < 0) { perror("eq: open"); return 1; }

    /* 1. Generate and load sine LUT (unchanged) */
    int32_t lut[N_LUT];
    generate_sine_lut(lut, N_LUT);
    if (load_lut(fd, lut, N_LUT) < 0) { ret = 1; goto done; }

    /* 2. Trigger sweep (unchanged) */
    if (trigger_sweep(fd) < 0) { ret = 1; goto done; }

    /* 3. Chunked spectrum assembly */
    double spectrum[N_HALF];
    int    filled[N_HALF];
    memset(spectrum, 0, sizeof(spectrum));
    memset(filled, 0, sizeof(filled));

    int last_chunk = -1;
    int running = 1;

    while (running) {
        room_eq_status_t status;
        ioctl(fd, ROOM_EQ_READ_STATUS, &status);

        room_eq_chunk_count_t cc;
        ioctl(fd, ROOM_EQ_READ_CHUNK_COUNT, &cc);
        int current_chunk = (int)cc.count;

        /* Process all new chunks since last poll */
        while (last_chunk + 1 < current_chunk && last_chunk + 1 < N_CHUNKS) {
            int c = last_chunk + 1;
            int k_lo, k_hi;
            chunk_bin_range(c, &k_lo, &k_hi);

            for (int k = k_lo; k <= k_hi; k++) {
                room_eq_fft_addr_t addr = { .addr = (unsigned short)k };
                ioctl(fd, ROOM_EQ_WRITE_FFT_ADDR, &addr);

                room_eq_fft_data_t data;
                ioctl(fd, ROOM_EQ_READ_FFT_DATA, &data);

                int32_t re = sign_extend_24(data.rdata);
                int32_t im = sign_extend_24(data.idata);
                double r = re / (double)(1 << 23);
                double i = im / (double)(1 << 23);
                spectrum[k] = sqrt(r * r + i * i);
                filled[k] = 1;
            }

            printf("eq: chunk %2d  bins %4d-%4d  (%.0f-%.0f Hz)\n",
                   c, k_lo, k_hi,
                   k_lo * BIN_WIDTH, k_hi * BIN_WIDTH);
            last_chunk = c;
        }

        if (status.state == STATE_DONE)
            running = 0;
        else
            usleep(1000);  /* 1 ms poll interval */
    }

    /* Fill unfilled bins with 1.0 (no correction) */
    int n_filled = 0;
    for (int k = 0; k < N_HALF; k++) {
        if (filled[k]) n_filled++;
        else spectrum[k] = 1.0;
    }
    printf("eq: %d of %d bins filled across %d chunks\n",
           n_filled, N_HALF, last_chunk + 1);

    /* 4. Design correction filter */
    int32_t taps[N_TAPS];
    if (fir_design_from_spectrum(spectrum, N_HALF, taps) < 0) {
        fprintf(stderr, "eq: fir_design failed\n");
        ret = 1; goto done;
    }

    /* 5. Write taps to file */
    FILE *f = fopen("fir_taps.bin", "wb");
    if (f) {
        fwrite(taps, sizeof(int32_t), N_TAPS, f);
        fclose(f);
        printf("eq: %d Q1.23 taps written to fir_taps.bin\n", N_TAPS);
    }

    /* 6. Write spectrum to file (for plotting) */
    FILE *sf = fopen("room_spectrum.txt", "w");
    if (sf) {
        for (int k = 0; k < N_HALF; k++)
            fprintf(sf, "%.10f\n", spectrum[k]);
        fclose(sf);
        printf("eq: spectrum written to room_spectrum.txt\n");
    }

done:
    close(fd);
    return ret;
}
```

### 7.4 Memory usage

```
spectrum[4097]:   4097 * 8 bytes (double) = 32,776 bytes
filled[4097]:     4097 * 4 bytes (int)    = 16,388 bytes
taps[128]:        128 * 4 bytes (int32)   =    512 bytes
lut[256]:         256 * 4 bytes (int32)   =  1,024 bytes
─────────────────────────────────────────────────────────
Total stack/heap:                          ~50 KB
```

The Cortex-A9 has 1 GB of DDR3. No memory concern.

---

## 8. Software Task 3: FIR Pipeline Update

### 8.1 New entry point

File: `src/software/room_eq/FIR/fir_design.c`

Add after the existing `fir_design()` function:

```c
int fir_design_from_spectrum(const double *mag_in, int n_bins,
                             int32_t *taps_out)
{
    int n_full = 2 * (n_bins - 1);   /* 8192 for n_bins=4097 */

    double *smoothed = malloc(n_bins * sizeof(double));
    double *c_mag    = malloc(n_bins * sizeof(double));
    double *c_full   = malloc(n_full * sizeof(double));
    double *h        = malloc(n_full * sizeof(double));
    double *taps_d   = malloc(N_TAPS * sizeof(double));
    if (!smoothed || !c_mag || !c_full || !h || !taps_d) {
        free(smoothed); free(c_mag); free(c_full); free(h); free(taps_d);
        return -1;
    }

    octave_smooth(mag_in, n_bins, 1.0 / 3.0, smoothed);
    compute_inverse(smoothed, n_bins, 1.0, c_mag);
    hermitian_extend(c_mag, n_bins, n_full, c_full);
    real_ifft(c_full, n_full, h);
    window_taps(h, n_full, N_TAPS, taps_d);
    quantise_taps(taps_d, N_TAPS, taps_out);

    free(smoothed); free(c_mag); free(c_full); free(h); free(taps_d);
    return 0;
}
```

Heap usage inside fir_design_from_spectrum:
```
smoothed:  4097 * 8  =  32,776 bytes
c_mag:     4097 * 8  =  32,776 bytes
c_full:    8192 * 8  =  65,536 bytes
h:         8192 * 8  =  65,536 bytes
taps_d:     128 * 8  =   1,024 bytes
──────────────────────────────────────
Total:                  197,648 bytes ≈ 193 KB
```

### 8.2 New prototype

File: `src/software/room_eq/FIR/fir_design.h`

Add:

```c
int fir_design_from_spectrum(const double *mag_in, int n_bins,
                             int32_t *taps_out);
```

### 8.3 What stays unchanged

All 7 stages in fir_design.c are unchanged:
- compute_magnitudes (still used by original fir_design)
- octave_smooth
- compute_inverse
- hermitian_extend
- real_ifft (hand-rolled Cooley-Tukey, works for 8192-point)
- window_taps
- quantise_taps

The original fir_design() entry point stays for unit testing.
fir_internal.h is unchanged.

---

## 9. Complete Calibration Sequence

```
Time      HPS (eq.c)                        FPGA hardware
────      ──────────                        ──────────────

 0.0s     generate_sine_lut(256 entries)
          load_lut() ────────────────────►  sine_lut BRAM written
                                            FSM: IDLE

 0.1s     trigger_sweep()
          ioctl(WRITE_CTRL, 1) ──────────►  FSM: IDLE → CALIBRATING
                                            sweep_start_toggle crosses to audio domain
                                            sweep_generator begins: 20 Hz sine
                                            calibrate_start → calibration_engine armed
                                            I2S TX plays sweep through LINE OUT
                                            I2S RX captures mic from LINE IN
                                            sample_fifo fills from i2s_rx_left

 0.1s     poll loop starts
          usleep(1ms) between polls
                                     ┌────  FIFO feeds FFT (8192 samples)
 0.27s                               │      FFT processes, outputs to RAM
          chunk_count = 1 ◄──────────┘      fft_done rises → chunk_count = 1
          read bins 3-5 (20-27 Hz)
          store in spectrum[]
                                     ┌────  Next 8192 samples collected
 0.44s                               │      FFT processes
          chunk_count = 2 ◄──────────┘      fft_done rises → chunk_count = 2
          read bins 5-7 (27-37 Hz)
          ...
          (continues for 29 chunks)
          ...
 5.0s                                       sweep reaches 20 kHz
                                            sweep_done latches
                                            done_sync2 in sys_clk domain
                                            FSM: CALIBRATING → DONE

 5.0s     STATUS == DONE
          exit poll loop
          fill unfilled bins with 1.0

 5.0s     fir_design_from_spectrum()
          → octave_smooth
          → compute_inverse (±12 dB clamp)
          → hermitian_extend (4097 → 8192)
          → real_ifft (8192-pt, ~few ms on Cortex-A9)
          → window_taps (128 taps, Hann window)
          → quantise_taps (Q1.23)

 5.1s     write fir_taps.bin (512 bytes)
          write room_spectrum.txt (for plotting)
          print summary
          done.
```

---

## 10. Files Summary

### New files (1):
```
src/hardware/room_eq_peripheral/i2s_rx/i2s_rx.sv       ~80 lines
```

### Modified files (6):
```
src/hardware/room_eq_peripheral/room_eq_peripheral.sv   FSM, chunk_count, I2S RX wiring, new ports
lab3-hw/soc_system_top.sv                               Remove AUD_ADCLRCK=0, wire through PD
lab3-hw/room_eq_peripheral_hw.tcl                       Add i2s_rx.sv, add conduit ports
src/software/room_eq/device_drivers/room_eq.h           Add chunk_count ioctl struct/command
src/software/room_eq/device_drivers/room_eq.c           Add chunk_count ioctl case, REG offset
src/software/eq.c                                       Chunked loop, sweep_freq, chunk_bin_range
src/software/eq.h                                       Sweep constants (FS, F_START, etc.)
src/software/room_eq/FIR/fir_design.c                   Add fir_design_from_spectrum()
src/software/room_eq/FIR/fir_design.h                   Add prototype
```

### Unchanged:
```
src/hardware/room_eq_peripheral/calibration_engine/*    (all 3 files)
src/hardware/room_eq_peripheral/sweep_generator/*       (all 3 files)
src/hardware/room_eq_peripheral/i2s_tx/*                (all 3 files)
src/hardware/memory/fft_results_ram.sv
src/hardware/memory/sine_lut.sv
src/software/room_eq/FIR/fir_internal.h
quartus/ip/room_eq_peripheral/capture_fft/*
quartus/ip/room_eq_peripheral/capture_fifo/*
test/software/FIR/test_fir.c                            (all tests still pass)
test/software/FIR/test_fir_e2e.c
test/software/test_eq.c
```

---

## 11. Testing

### 11.1 I2S RX simulation (Icarus Verilog)

File: `test/hardware/room_eq_peripheral/i2s_rx/tb_i2s_rx.sv`

Test cases:
- Drive ADCDAT with known left/right samples (e.g., 0x555555 / 0xAAAAAA)
- Verify left_sample and right_sample match after deserialization
- Verify sample_valid pulses once per frame (every 64 BCLK cycles)
- Test with zero, full-scale positive (0x7FFFFF), full-scale negative (0x800000)

### 11.2 I2S loopback simulation

File: `test/hardware/room_eq_peripheral/i2s_rx/tb_i2s_loopback.sv`

Connect i2s_tx DACDAT output to i2s_rx ADCDAT input. Drive i2s_tx
with known samples, verify i2s_rx recovers them. This validates the
full serialize/deserialize round-trip including timing alignment.

### 11.3 Chunked FSM simulation

Extend `test/hardware/room_eq_peripheral/tb_room_eq_peripheral.sv`:
- Trigger sweep_start
- Verify state transitions: IDLE → CALIBRATING → DONE
- Feed test data through left_chan (via i2s_rx or direct)
- Verify chunk_count increments on each fft_done rising edge
- Read FFT bins via register interface during CALIBRATING
- Verify RAM is readable between fft_done and next SOP

### 11.4 Software test

File: `test/software/FIR/test_chunked_assembly.c`

- Synthesize what the per-chunk reads would produce for a known room model
- Run fir_design_from_spectrum() on the assembled spectrum
- Compare taps to fir_design() run on the same room model (single-shot)
- Verify taps are similar (not identical — chunking introduces slight
  differences due to bin selection, but the 1/3-octave smoothing
  should make the correction filters nearly equivalent)

### 11.5 Hardware integration (on DE1-SoC)

**Step 1: Loopback cable test**
- Connect LINE OUT to LINE IN with a 3.5mm cable
- Run eq, expect flat spectrum (no room coloring)
- Taps should approximate a scaled delta function

**Step 2: Room measurement**
- Connect mic preamp to LINE IN
- Place mic at listening position
- Run eq, expect room modes visible in spectrum
- Plot with plot_eq.py to visualize

---

## 12. Risk Checklist

| Risk | Mitigation |
|------|-----------|
| I2S RX bit alignment off by 1 | Loopback sim catches this before hardware |
| ADCDAT sampled on wrong BCLK edge | WM8731 datasheet confirms: data transitions on BCLK fall, stable on rise |
| chunk_count wraps (>255 chunks) | Sweep is 29 chunks. 8-bit counter is sufficient |
| FFT output ordering (natural vs bit-reversed) | Quartus FFT IP defaults to natural order. Verify in sim |
| Sweep doesn't reach 20 kHz exactly at sample 240000 | phase_accumulator uses INC_20KHZ threshold. May stop 1-2 chunks early. Software handles via filled[] array |
| FIFO overflow during FFT processing | DCFIFO is 8192 deep, only ~240 samples arrive during processing. Impossible |
| HPS misses a chunk (reads too slow) | 173ms window vs 20ms worst-case read. 8.4x margin. Won't happen |
| Platform Designer port name mismatch | After re-generation, check soc_system.v wrapper port names match soc_system_top.sv |
