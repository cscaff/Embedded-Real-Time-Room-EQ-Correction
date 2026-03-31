# Real-Time Room EQ Correction Device

*Embedded Systems Project Proposal — DE1-SoC*
Jacob Boxerman (JIB2137) • Roland List (RJL2184) • Christian Scaff (CTS2148)

## Overview

We propose a room equalization correction device built on the DE1-SoC. The system plays a sine sweep through connected speakers, records the room's response through a microphone, and computes a correction filter. All subsequent audio input is then filtered in real time to compensate for the room's acoustic colorations.

## Hardware

- DE1-SoC with on-board audio codec
- Speakers connected via LINE OUT (3.5 mm aux)
- Condenser microphone connected via LINE IN (3.5 mm aux)

## FPGA Responsibilities

- I2S interface to the WM8731 audio codec
- Logarithmic sine sweep generator (20 Hz – 20 kHz)
- Sample capture during sweep for room response measurement
- Real-time FIR filter bank applying the correction coefficients

## ARM CPU Responsibilities

- Codec initialization
- FFT analysis of captured room response
- EQ coefficient computation and write-back to FPGA via HPS–FPGA bridge
- User control: trigger recalibration or bypass filter via switches/UART

## Operation

On startup, the FPGA runs the sweep while the CPU collects samples and computes correction coefficients. In normal operation, audio passes through the FPGA filter in real time with the computed EQ applied.
