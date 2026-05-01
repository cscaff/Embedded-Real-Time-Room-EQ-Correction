# Design Defense

## 48 kHz
Satisfies Nyquist theorem for human hearing but is possible with our PLL generation (12.288 MHz).


## 32 Bit AXI Bus
My understanding is that this is a fixed bus in hardware. 32 bits tends to make sense though when you think of writing data types. (Think of uint32_t)

# 8192 Samples

My understanding is that this is a balance of frequency resolution for a given capture time and memory constraint.

`48000 / 8192 ≈ 5.86 Hz per bin`

`8192 / 48000 = 170.66 MS`

`~192 Kbit` Fits along with our other constraints.

# 4097 Complex Bins

"This means the upper half of the spectrum (bins 4097 through 8191) contains exactly the same information as the lower half (bins 1 through 4095), just complex-conjugated. Storing the upper half would be completely redundant" - My friend Claude.

# 128 Taps

"Frequency resolution of the correction filter:
A FIR filter with N taps has a frequency resolution of roughly:
Δf ≈ fs / N = 48000 / 128 ≈ 375 Hz
This means the filter can independently control frequency bands no narrower than about 375 Hz." - My friend Claude.

i.e. 128 Taps ideally gives us decent resolution with modest memory usage.


# Notes

This should be a specification, not a plan.

## Sine LUT:

How big is the sine LUT table itself:

Phase acc. is ok, but issues with phase inc.

See section 4.1

Make sure HPS bus is fast enough and synchronized


Add line in for audio input to blocker diagram.
