# Tech Stack

## Simulation (current)

| Tool | What it does |
|------|-------------|
| **Icarus Verilog** (`iverilog` + `vvp`) | Compiles and runs SystemVerilog testbenches |
| **GTKWave** | Waveform viewer for `.vcd` dumps |
| **Python 3** (`numpy`, `matplotlib`) | Post-simulation plotting and analysis |

All simulation dependencies are defined in `flake.nix`. Run `nix develop` to enter the dev shell.

### Running simulations

```bash
make all            # compile and run all testbenches
make sim_sweep      # full 5-second sweep simulation
make sim_sine_lut   # dual-port BRAM tests
make sim_sine_lookup # sine lookup + plot
make sim_phase_acc  # phase accumulator tests
make clean          # remove sim_out/
```

## Hardware targeting (when we move to the DE1 board)

| Tool | What it does |
|------|-------------|
| **Quartus Prime Lite** | Synthesis, place-and-route, bitstream generation for Cyclone V |
| **Platform Designer (Qsys)** | Wires up the Avalon bus between HPS and FPGA peripheral |
| **Questa Intel FPGA Edition** | Required for simulating Altera IP cores (FFT, DCFIFO, PLL). Free license from Intel's site. Christian's branch has working testbenches for this. |

Quartus runs on Linux and Windows only — not macOS.

## Target hardware

- **Board:** Terasic DE1-SoC
- **FPGA:** Intel Cyclone V (`5CGXFC7C7F23C8`)
- **CPU:** Dual-core ARM Cortex-A9 (HPS)
- **Audio codec:** Wolfson WM8731 (on-board, I2S + I2C control)
