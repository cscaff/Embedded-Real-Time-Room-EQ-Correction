# Room EQ Project — Agent Instructions

## What This Is
Real-Time Room EQ Correction system on DE1-SoC (Cyclone V FPGA + ARM HPS).
Plays a sine sweep through the WM8731 codec, captures room response via ADC,
runs hardware FFT, computes correction filter taps on the HPS.

## Critical Rules

1. **NEVER edit files under `lab3-hw/soc_system/synthesis/`** — these are generated
   by Platform Designer. Edit the source files and regenerate.

2. **Always check `lab3-hw/soc_system_top.sv`** when adding conduit ports. New signals
   must be connected in the `soc_system` instantiation AND any stale placeholder
   `assign` statements must be removed.

3. **Build flow after hardware changes:**
   ```bash
   make qsys      # regenerate Platform Designer output
   make quartus   # full Quartus synthesis + place & route
   make rbf       # generate .rbf bitstream
   # Copy lab3-hw/output_files/soc_system.rbf to SD card FAT partition
   ```

4. **Test incrementally.** Don't wire up multiple new modules at once. Add one,
   compile, test on hardware, then add the next.

5. **Use /dev/mem mmap for HPS access** (not the kernel driver). See `codec_init.c`.

6. **IP cores must target 5CSEMA5F31C6** (DE1-SoC Cyclone V SE). Christian's existing
   IPs targeted a different device and must be regenerated.

## Key Files
- `src/hardware/room_eq_peripheral/room_eq_peripheral.sv` — main custom peripheral
- `lab3-hw/soc_system_top.sv` — top-level FPGA wrapper (pin mapping)
- `lab3-hw/room_eq_peripheral_hw.tcl` — Platform Designer component definition
- `src/software/room_eq/codec_init.c` — HPS software (codec init + sweep + mic test)
- `lab3-hw/soc_system.qsf` — pin assignments
- `lab3-hw/soc_system.qsys` — Platform Designer system

## Architecture Notes
- See `docs/design.md` for the full design document
- See `.claude/projects/.../memory/` for debugging notes and architecture details
- Two clock domains: sys_clk (50 MHz) and audio_clk (12.288 MHz)
- CDC uses 2-FF synchronizers (single-bit) and DCFIFO (multi-bit data)
- Audio path: 48 kHz sample rate, 24-bit, I2S format, codec in slave mode
