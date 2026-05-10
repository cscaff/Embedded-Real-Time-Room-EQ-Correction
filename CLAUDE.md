# Room EQ Project — Agent Instructions

## What This Is
Real-Time Room EQ Correction system on DE1-SoC (Cyclone V FPGA + ARM HPS).
Plays a sine sweep through the WM8731 codec, captures room response via ADC,
runs continuous hardware FFT during sweep, reads frequency bins on HPS.

## Critical Rules

1. **NEVER edit files under `lab3-hw/soc_system/synthesis/`** — these are generated
   by Platform Designer. Edit the source files and regenerate.

2. **Always check `lab3-hw/soc_system_top.sv`** when adding conduit ports. New signals
   must be connected in the `soc_system` instantiation AND any stale placeholder
   `assign` statements must be removed.

3. **Build flow after hardware changes:**
   ```bash
   # Run from lab3-hw/ directory
   make qsys      # regenerate Platform Designer output
   make quartus   # full Quartus synthesis + place & route
   make rbf       # generate .rbf bitstream
   # Copy lab3-hw/output_files/soc_system.rbf to SD card FAT partition
   ```

4. **Test incrementally.** Use `fifo_hps_mode` (CTRL[1]) to test stages:
   - Stage 1: `./codec_init f` — raw ADC samples through DCFIFO
   - Stage 2: `./codec_init c` — continuous FFT during sweep

5. **Use /dev/mem mmap for HPS access** (not the kernel driver). See `codec_init.c`.

6. **IP cores must target 5CSEMA5F31C6** (DE1-SoC Cyclone V SE). Christian's existing
   IPs targeted a different device and must be regenerated.

7. **Platform Designer TCL fileset only accepts source files** (VERILOG, SYSTEM_VERILOG,
   etc.) — NOT `.qip` files. Use `add_fileset_file foo.v VERILOG PATH foo.v`.
   The `.qip` goes in the `.qsf` at the Quartus project level (Quartus adds it
   automatically when you generate an IP from IP Catalog).

8. **DCFIFO must use showahead mode.** Without `lpm_showahead = "ON"`, the output `q`
   is one read behind, causing data integrity bugs in `sample_fifo.sv`.

## Key Files
- `src/hardware/room_eq_peripheral/room_eq_peripheral.sv` — main custom peripheral
- `src/hardware/room_eq_peripheral/calibration_engine/calibration_engine.sv` — FIFO + FFT + result RAM
- `lab3-hw/soc_system_top.sv` — top-level FPGA wrapper (pin mapping)
- `lab3-hw/room_eq_peripheral_hw.tcl` — Platform Designer component definition
- `src/software/room_eq/codec_init.c` — HPS software (codec init, sweep, FIFO test, calibration)
- `lab3-hw/soc_system.qsf` — pin assignments
- `lab3-hw/soc_system.qsys` — Platform Designer system
- `lab3-hw/capture_fifo.v` — Quartus-generated DCFIFO (24-bit x 8192, showahead)
- `lab3-hw/capture_fft.v` — FFT passthrough stub (replace with real FFT II IP later)
- `sim/` — simulation models (behavioral DCFIFO, echo-stub FFT, extracted Altera dcfifo)

## Register Map (4-bit address, word offsets from 0xFF202000)
| Reg | Name | Access | Description |
|-----|------|--------|-------------|
| 0 | CTRL | R/W | [0] sweep_start (W, self-clears), [1] fifo_hps_mode |
| 1 | STATUS | R | [3:0] FSM state (0=IDLE,1=SWEEP,2=DONE), [4] fft_done, [5] fifo_empty |
| 3 | VERSION | R | 0x0001_0000 |
| 4 | LUT_ADDR | W | [9:0] sine LUT write address (1024 entries) |
| 5 | LUT_DATA | W | [23:0] sine LUT write data (fires we_lut) |
| 6 | FFT_ADDR | R/W | [12:0] FFT result RAM read address |
| 7 | FFT_RDATA | R | [23:0] FFT real part at FFT_ADDR |
| 8 | FFT_IDATA | R | [23:0] FFT imag part at FFT_ADDR |
| 9 | ADC_LEFT | R | [23:0] latest ADC sample (diagnostic) |
| 10 | FIFO_RDATA | R | [23:0] pop-on-read from DCFIFO |

## Architecture Notes
- Two clock domains: sys_clk (50 MHz) and audio_clk (12.288 MHz)
- CDC uses 2-FF synchronizers (single-bit) and DCFIFO (multi-bit data)
- Audio path: 48 kHz sample rate, 24-bit, I2S format, codec in slave mode
- FSM: IDLE → SWEEP → DONE. FFT armed at sweep start, runs continuously.
- Each FFT frame = 8192 samples = ~170ms. HPS has ~170ms to read bins before next frame.
- `sweep_generator.start` resets phase_accumulator (clears `done`) for re-trigger.
- FSM uses rising-edge detector on `done_sync2` to avoid stale-high race on re-start.
