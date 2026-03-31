# March 31st Notes:

What do we need to figure out before building this out?

- What are the input/outputs for the top module.
- How do we divide the overall task into submodules (utilizing existing IP cores from Platform Designer).
  - What are the input/outputs for those.
  
That is the first step. Then we can simulate each component in python before we commit time to building them out in hardware.

Useful Sources: [Manual](http://www.ee.ic.ac.uk/pcheung/teaching/ee2_digital/DE1-SoC_User_manual.pdf)

## Hardware Components

- Mic In, Line In, Line Out
  - Audio Codec
  
**Question:** Are we using Line in or Mic in for a Condenser Microphone?
- I'd assume Mic In but unsure what microphone we have.

**Question:** What microphone are we using?


"The DE1-SoC board provides high-quality 24-bit audio via the Wolfson WM8731 audio CODEC
(Encoder/Decoder). This chip supports microphone-in, line-in, and line-out ports, with a sample rate
adjustable from 8 kHz to 96 kHz. The WM8731 is controlled via a serial I2C bus, which is
connected to HPS or Cyclone V SoC FPGA through a I2C multiplexer." [3.6.4](http://www.ee.ic.ac.uk/pcheung/teaching/ee2_digital/DE1-SoC_User_manual.pdf)

![pins](/docs/assets/audio_pins.png)

![block_diagram_codec](/docs/assets/block_diagram_codec.png)

![I2C](/docs/assets/I2C_multiplexer.png)

Playing w/ Claude to generate a block diagram based on the manual data to give us some vague idea of what the structure looks like:

![Analog-FPGA-Block](/docs/assets/mic_to_fpga_signal_path.svg)

We can use the I2C Master soft IP core.

Seems like we need to implement an I2S Receiver ourselves? Don't know much about this just yet.

There exists an FIR filter IP core.

Were going to have to deal with clock domain crossings but I think Altera provides us something to figure that out too instead of having to manually use a two flip-flop synchronizer. I honestly don't know though lmao.


Ok, so we get a time domain 16 bit sample from the claude-based block diagram. This feeds into our FPGA.

We need to buffer or store the samples somewhere and then convert the samples to frequency domain.

Claude generated: maybe useful? maybe shit? 

![buffer_ideas](/docs/assets/sample_buffer_options.svg)

We can use the FFT IP Core to convert to the frequency domain. 

I assume then that we want to take the frequency samples and pass them through the Avalon Bus to the HPS/ARM Core.

### Useful Example: Karoke Machine

[See section 5.3](http://www.ee.ic.ac.uk/pcheung/teaching/ee2_digital/DE1-SoC_User_manual.pdf). Illustrates example of a karaoke machine that takes line and mic in and outputs line out.