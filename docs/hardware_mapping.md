# Mapping the Python Algorithm to Hardware

```Python
def generate_sweep(f1=F1, f2=F2, T=T, fs=FS):
    w1 = 2 * np.pi * f1
    w2 = 2 * np.pi * f2
    t  = np.arange(0, T, 1.0 / fs)
    L  = T / np.log(w2 / w1)
    K  = T * w1 / np.log(w2 / w1)
    phase = K * (np.exp(t / L) - 1.0)
    sweep = np.sin(phase)
    return t, sweep
```

The sweep generation will be performed in C on the Dual-core ARM Cortex-A9 (HPS). We will precompute the sweep array in software since it can handle latency. It will be stored in the 1GB DDR3 SDRAM (w/ a 32-bit data bus).

