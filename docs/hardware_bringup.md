# Hardware Bringup Notes

## What We Have Working

- **Sweep generator → I2S TX → WM8731 codec → LINE OUT**: audio plays from the FPGA
- **FPGA I2C master**: codec initialization from C code via Avalon I2C IP in Platform Designer
- **HPS control**: start the sweep from userspace via `/dev/mem` mmap to the peripheral registers
- **Full Platform Designer integration**: `room_eq_peripheral` is a proper Avalon MM component, not a hack

## Architecture

```
soc_system_top.sv
└── soc_system (Platform Designer generated)
    ├── hps_0              — ARM HPS (Linux, I2C, ethernet, etc.)
    ├── clk_0              — 50 MHz system clock
    ├── audio_pll_0        — 12.288 MHz audio clock (University Program Audio PLL)
    ├── i2c_master_0       — Avalon I2C master for FPGA_I2C pins → codec
    └── room_eq_peripheral_0
        ├── sweep_generator
        │   ├── phase_accumulator
        │   └── sine_lookup
        │       └── sine_lut
        └── i2s_tx
            ├── i2s_clock_gen
            └── i2s_shift_register
```

## Platform Designer Addresses

| Component | Base | End |
|-----------|------|-----|
| `i2c_master_0` (Avalon I2C) | `0x00` | `0x3F` |
| `room_eq_peripheral_0` | `0x40` | `0x5F` |

These are offsets from the lightweight bridge base: `0xFF200000`.

## Register Map (room_eq_peripheral)

| Word Offset | Bits | Access | Meaning |
|-------------|------|--------|---------|
| 0 | [0] | W | `sweep_start` — write 1 to trigger sweep |
| 0 | [1] | R | `sweep_running` — 1 while sweep is active |
| 1 | [31:0] | R | STATUS — reserved |
| 2 | [31:0] | R/W | SWEEP_LEN — sweep length in samples (default 480000) |
| 3 | [31:0] | R | VERSION — `0x00010000` |

## I2C: Codec Lives on FPGA I2C Pins, Not HPS I2C

The WM8731 codec is connected to `FPGA_I2C_SCLK` / `FPGA_I2C_SDAT`, **not** the HPS I2C pins (`HPS_I2C1` / `HPS_I2C2`). The HPS I2C bus sees other devices (accelerometer at `0x53`, etc.) but cannot reach the codec.

We added an **Avalon I2C Master IP** in Platform Designer, connected to the HPS lightweight bus, with its conduit exported to the FPGA I2C pins. The top-level wires the open-drain outputs:

```systemverilog
// I2C open-drain: when oe=1, drive low; when oe=0, tri-state (pulled high)
assign FPGA_I2C_SDAT = fpga_i2c_sda_oe ? 1'b0 : 1'bZ;
assign FPGA_I2C_SCLK = fpga_i2c_scl_oe ? 1'b0 : 1'bZ;
```

## WM8731 Codec Configuration

The codec I2C address is `0x1A` (7-bit). Register writes are 2 bytes: `{reg[6:0], data[8]}` then `data[7:0]`.

| Reg | Value | Meaning |
|-----|-------|---------|
| 0x0F | 0x000 | Reset |
| 0x00 | 0x017 | Left Line In: 0dB, no mute |
| 0x01 | 0x017 | Right Line In: 0dB, no mute |
| 0x02 | 0x079 | Left HP Out: near max volume |
| 0x03 | 0x079 | Right HP Out: near max volume |
| 0x04 | 0x012 | Analog Path: DAC select, line in |
| 0x05 | 0x000 | Digital Path: no mute, no de-emphasis |
| 0x06 | 0x000 | Power: all blocks on |
| 0x07 | 0x00A | Format: I2S, 24-bit, slave mode |
| 0x08 | 0x000 | Sampling: normal mode, 48 kHz |
| 0x09 | 0x001 | Active: enable digital core |

## Sine LUT: Currently Using Parabolic Approximation

The sine LUT is initialized at FPGA startup using a parabolic approximation in `room_eq_peripheral.sv`:

```systemverilog
din_lut <= (lut_init_cnt[7:0] * (8'd255 - lut_init_cnt[7:0])) << 7;
```

This produces an audible tone but not a pure sine. To get the real sine wave:
- **Option 1**: Add LUT write registers so the HPS can write `sin()` values from C code at startup
- **Option 2**: Use a Quartus `.mif` (Memory Initialization File) for BRAM preload
- **Option 3**: Compute sine values in C, write them through two new peripheral registers (LUT addr + LUT data)

## Known Limitations / TODO

- **No stop mechanism**: `sweep_active` only gets set, never cleared. Must power cycle to stop. Need to add a stop/reset bit to the CTRL register.
- **Parabolic LUT**: Not a real sine. Add HPS-writable LUT registers or `.mif` file.
- **Sweep runs forever**: No sample counter to stop after `SWEEP_LEN` samples.
- **No `i2s_rx`**: Can't capture audio from LINE IN yet.
- **`AUD_ADCLRCK` tied low**: Needs to be driven by `i2s_rx` when implemented.
- **`AUD_BCLK` and `AUD_DACLRCK` are `inout` in top-level but driven as outputs**: Works but should be cleaned up for bidirectional I2S.

## Build & Deploy Flow

1. Edit SystemVerilog or Platform Designer
2. If Platform Designer changed: **Generate HDL**
3. `make quartus` (or Processing → Start Compilation in GUI)
4. `make rbf`
5. Copy `output_files/soc_system.rbf` to board's boot partition (`/mnt` after `mount /dev/mmcblk0p1 /mnt`)
6. `sync && reboot` on the board
7. After reboot: `ifup eth0`, then run `./codec_init`

## Board Connection Setup

- **Serial console**: `screen /dev/tty.usbserial-AK05OKPX 115200`
- **Networking**: Mac Internet Sharing (Wi-Fi → Ethernet adapter `ax88179a`)
- **Board IP**: DHCP from Internet Sharing, typically `192.168.2.x`
- **SSH**: Had password issues. Used serial console directly. Fix: set password with `passwd root` or use SSH keys.
- **Audio output**: Green 3.5mm jack (LINE OUT)

## Files

| File | Purpose |
|------|---------|
| `src/hardware/room_eq_peripheral/room_eq_peripheral.sv` | Top-level Avalon peripheral (sweep + I2S + registers) |
| `src/hardware/room_eq_peripheral/i2s_tx/i2s_tx.sv` | I2S transmitter top level |
| `src/hardware/room_eq_peripheral/i2s_tx/i2s_clock_gen.sv` | BCLK + LRCK generation |
| `src/hardware/room_eq_peripheral/i2s_tx/i2s_shift_register.sv` | Parallel-to-serial shift register |
| `src/hardware/room_eq_peripheral/sweep_generator/sweep_generator.sv` | Sine sweep source |
| `src/hardware/room_eq_peripheral/sweep_generator/phase_accumulator.sv` | Log-sweep phase generation |
| `src/hardware/room_eq_peripheral/sweep_generator/sine_lookup.sv` | Quadrant decoder + LUT interface |
| `src/hardware/memory/sine_lut.sv` | Dual-port BRAM for sine quarter-wave table |
| `src/software/room_eq/codec_init.c` | Codec I2C init + sweep start (userspace, `/dev/mem`) |
| `lab3-hw/soc_system_top.sv` | Board-level pin mapping |
| `lab3-hw/soc_system.qsys` | Platform Designer system |
