/*
 * codec_init.c — Initialize the WM8731 codec via the FPGA I2C master
 *                and start the Room EQ sweep.
 *
 * The Avalon I2C master IP is at offset 0x00 from the lightweight bridge.
 * The room_eq_peripheral is at offset 0x40.
 *
 * Configures the codec for:
 *   - I2S slave mode, 24-bit, 48 kHz
 *   - LINE IN selected, unmuted
 *   - Headphone output unmuted, near-max volume
 *   - DAC selected, no bypass
 *   - All power blocks on
 *   - Codec active
 *
 * Usage: gcc -o codec_init codec_init.c && ./codec_init
 */

#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <stdint.h>
#include <math.h>

/* ── Memory map ──────────────────────────────────────────── */

#define LW_BRIDGE_BASE   0xFF200000
#define LW_BRIDGE_SPAN   0x00200000

#define I2C_BASE_OFFSET  0x0000
#define ROOM_EQ_OFFSET   0x2000  /* must match baseAddress in soc_system.qsys */

/* ── Avalon I2C Master registers (byte offsets) ──────────── */
/* See Intel Avalon I2C Master Core User Guide */

#define I2C_TFR_CMD      0x00  /* Transfer Command FIFO */
#define I2C_RX_DATA      0x04  /* Receive Data FIFO */
#define I2C_CTRL         0x08  /* Control register */
#define I2C_ISER         0x0C  /* Interrupt Status Enable */
#define I2C_ISR          0x10  /* Interrupt Status */
#define I2C_STATUS       0x14  /* Status register */
#define I2C_TFR_CMD_FIFO_LVL  0x18  /* Transfer Command FIFO Level */
#define I2C_RX_DATA_FIFO_LVL  0x1C  /* Receive Data FIFO Level */
#define I2C_SCL_LOW      0x20  /* SCL Low Count */
#define I2C_SCL_HIGH     0x24  /* SCL High Count */
#define I2C_SDA_HOLD     0x28  /* SDA Hold Count */

/* TFR_CMD bits */
#define TFR_CMD_STA      (1 << 9)   /* START condition */
#define TFR_CMD_STO      (1 << 8)   /* STOP condition */
#define TFR_CMD_RW_D     (0 << 8)   /* Data transfer (no STA/STO) */

/* STATUS bits */
#define STATUS_CORE_STATUS  (1 << 0)  /* 1 = busy */

/* CTRL bits */
#define CTRL_EN          (1 << 0)   /* Core enable */

/* ── WM8731 ──────────────────────────────────────────────── */

#define WM8731_ADDR      0x1A  /* 7-bit I2C address */

static volatile uint32_t *i2c_base;
static volatile uint32_t *room_eq_base;

static inline void i2c_write_reg(int reg, uint32_t val)
{
    *(volatile uint32_t *)((uint8_t *)i2c_base + reg) = val;
}

static inline uint32_t i2c_read_reg(int reg)
{
    return *(volatile uint32_t *)((uint8_t *)i2c_base + reg);
}

static void i2c_wait_idle(void)
{
    int timeout = 100000;
    while ((i2c_read_reg(I2C_STATUS) & STATUS_CORE_STATUS) && --timeout > 0)
        usleep(1);
    if (timeout == 0)
        fprintf(stderr, "Warning: I2C timeout waiting for idle\n");
}

static void i2c_init(void)
{
    /* Disable core during setup */
    i2c_write_reg(I2C_CTRL, 0);

    /* Set SCL timing for ~100 kHz
       50 MHz / 100 kHz = 500 total counts
       Low = 250, High = 250 */
    i2c_write_reg(I2C_SCL_LOW, 250);
    i2c_write_reg(I2C_SCL_HIGH, 250);
    i2c_write_reg(I2C_SDA_HOLD, 30);

    /* Enable core */
    i2c_write_reg(I2C_CTRL, CTRL_EN);

    usleep(1000);
}

/*
 * WM8731 register write: 7-bit register + 9-bit data
 * I2C transaction: START, addr+W, byte1, byte2, STOP
 *   byte1 = {reg[6:0], data[8]}
 *   byte2 = data[7:0]
 */
static int wm8731_write(uint8_t reg, uint16_t data)
{
    uint8_t byte1 = (reg << 1) | ((data >> 8) & 0x01);
    uint8_t byte2 = data & 0xFF;

    i2c_wait_idle();

    /* START + slave address + W */
    i2c_write_reg(I2C_TFR_CMD, TFR_CMD_STA | (WM8731_ADDR << 1) | 0);

    /* Data byte 1 */
    i2c_write_reg(I2C_TFR_CMD, byte1);

    /* Data byte 2 + STOP */
    i2c_write_reg(I2C_TFR_CMD, TFR_CMD_STO | byte2);

    i2c_wait_idle();

    /* Check for NACK — read ISR */
    uint32_t isr = i2c_read_reg(I2C_ISR);
    if (isr & (1 << 2)) {  /* NACK bit */
        /* Clear it */
        i2c_write_reg(I2C_ISR, isr);
        fprintf(stderr, "NACK on reg 0x%02x\n", reg);
        return -1;
    }

    return 0;
}

static int codec_init(void)
{
    printf("Initializing I2C master...\n");
    i2c_init();

    printf("Configuring WM8731 codec...\n");
    int err = 0;

    err |= wm8731_write(0x0F, 0x000);  /* Reset */
    usleep(10000);                       /* Wait after reset */

    err |= wm8731_write(0x00, 0x017);  /* Left Line In: 0dB, no mute */
    err |= wm8731_write(0x01, 0x017);  /* Right Line In: 0dB, no mute */
    err |= wm8731_write(0x02, 0x079);  /* Left HP Out: near max */
    err |= wm8731_write(0x03, 0x079);  /* Right HP Out: near max */
    err |= wm8731_write(0x04, 0x012);  /* Analog: DAC, line in */
    err |= wm8731_write(0x05, 0x000);  /* Digital: no mute */
    err |= wm8731_write(0x06, 0x000);  /* Power: all on */
    err |= wm8731_write(0x07, 0x00A);  /* Format: I2S, 24-bit, slave */
    err |= wm8731_write(0x08, 0x000);  /* Sampling: normal, 48kHz */
    err |= wm8731_write(0x09, 0x001);  /* Active */

    if (err)
        printf("Some codec writes failed (NACKs)\n");
    else
        printf("Codec initialized: I2S slave, 24-bit, 48 kHz\n");

    return err;
}

/* ── Sine LUT ─────────────────────────────────────────────── */

/*
 * LUT_BASE_OFFSET and LUT_SIZE must match the localparams in
 * room_eq_peripheral.sv (LUT_BASE and LUT_SIZE).
 *
 * The BRAM holds LUT_SIZE quarter-wave sine values (24-bit signed).
 * Entry i = sin(i * π / (2 * LUT_SIZE)) * 8388607
 */
#define LUT_BASE_OFFSET  4
#define LUT_SIZE         1024

static void load_sine_lut(void)
{
    printf("Loading sine LUT (%d entries)...\n", LUT_SIZE);
    for (int i = 0; i < LUT_SIZE; i++) {
        double  angle = i * M_PI / (2.0 * LUT_SIZE);
        int32_t val   = (int32_t)(sin(angle) * 8388607.0);
        room_eq_base[LUT_BASE_OFFSET + i] = (uint32_t)(val & 0x00FFFFFF);
    }
    printf("Sine LUT loaded.\n");
}

/* ── Room EQ peripheral ──────────────────────────────────── */

#define CTRL_REG  0  /* word offset 0: bit 0 = sweep_start */

static int start_sweep(void)
{
    /* Write 1 to start the sweep */
    room_eq_base[CTRL_REG] = 0x1;
    printf("Sweep started.\n");

    usleep(1000);

    /* Read back status */
    uint32_t status = room_eq_base[CTRL_REG];
    printf("CTRL reg: 0x%08x (sweep_running = %d)\n",
           status, (status >> 1) & 1);

    return 0;
}

/* ── Main ─────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    printf("Room EQ — Codec Init + Sweep Start\n");

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem");
        return 1;
    }

    void *base = mmap(NULL, LW_BRIDGE_SPAN, PROT_READ | PROT_WRITE,
                       MAP_SHARED, fd, LW_BRIDGE_BASE);
    if (base == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    i2c_base    = (volatile uint32_t *)((uint8_t *)base + I2C_BASE_OFFSET);
    room_eq_base = (volatile uint32_t *)((uint8_t *)base + ROOM_EQ_OFFSET);

    if (codec_init() < 0)
        fprintf(stderr, "Warning: codec init had errors\n");

    load_sine_lut();
    start_sweep();

    munmap(base, LW_BRIDGE_SPAN);
    close(fd);
    return 0;
}
