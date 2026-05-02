/*
 * codec_init.c — Initialize the WM8731 codec on the DE1-SoC
 *                and start the Room EQ sweep.
 *
 * Configures the codec over I2C for:
 *   - I2S slave mode, 24-bit, 48 kHz
 *   - LINE IN selected, unmuted
 *   - LINE OUT unmuted, headphone volume up
 *   - Digital audio path: no mute, no de-emphasis
 *   - Power: everything on
 *   - Activate codec
 *
 * Then writes to the room_eq_peripheral CTRL register to
 * start the sweep.
 *
 * Usage: ./codec_init
 *
 * Compile on the DE1-SoC:
 *   gcc -o codec_init codec_init.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <linux/i2c-dev.h>
#include <sys/ioctl.h>

/* ── I2C ──────────────────────────────────────────────────── */

#define WM8731_ADDR  0x1a   /* 7-bit I2C address (CSB = low) */
#define I2C_DEV      "/dev/i2c-0"

/*
 * WM8731 register write: 7-bit register address + 9-bit data,
 * packed into two bytes: [AAAA AAA D] [DDDD DDDD]
 */
static int wm8731_write(int fd, unsigned char reg, unsigned short data)
{
    unsigned char buf[2];
    buf[0] = (reg << 1) | ((data >> 8) & 0x01);
    buf[1] = data & 0xFF;

    if (write(fd, buf, 2) != 2) {
        perror("I2C write");
        return -1;
    }
    return 0;
}

static int codec_init(void)
{
    int fd = open(I2C_DEV, O_RDWR);
    if (fd < 0) {
        perror("open I2C device");
        return -1;
    }

    if (ioctl(fd, I2C_SLAVE, WM8731_ADDR) < 0) {
        perror("ioctl I2C_SLAVE");
        close(fd);
        return -1;
    }

    /* Reset codec */
    wm8731_write(fd, 0x0F, 0x000);
    usleep(10000);

    /* Reg 0: Left Line In — 0dB, no mute */
    wm8731_write(fd, 0x00, 0x017);

    /* Reg 1: Right Line In — 0dB, no mute */
    wm8731_write(fd, 0x01, 0x017);

    /* Reg 2: Left Headphone Out — max volume */
    wm8731_write(fd, 0x02, 0x079);

    /* Reg 3: Right Headphone Out — max volume */
    wm8731_write(fd, 0x03, 0x079);

    /* Reg 4: Analog Audio Path — select DAC, no bypass,
       line input, no mute mic */
    wm8731_write(fd, 0x04, 0x012);

    /* Reg 5: Digital Audio Path — no soft mute, no de-emphasis */
    wm8731_write(fd, 0x05, 0x000);

    /* Reg 6: Power Down — everything on (0 = powered up) */
    wm8731_write(fd, 0x06, 0x000);

    /* Reg 7: Digital Audio Interface Format —
       I2S, 24-bit, slave mode */
    wm8731_write(fd, 0x07, 0x00A);

    /* Reg 8: Sampling Control —
       Normal mode, 48 kHz, USB mode off, 256fs */
    wm8731_write(fd, 0x08, 0x000);

    /* Reg 9: Active — activate digital core */
    wm8731_write(fd, 0x09, 0x001);

    printf("WM8731 codec initialized: I2S slave, 24-bit, 48 kHz\n");

    close(fd);
    return 0;
}

/* ── Memory-mapped peripheral access ─────────────────────── */

#define LW_BRIDGE_BASE  0xFF200000
#define LW_BRIDGE_SPAN  0x00200000

/* Offset of room_eq_peripheral within the lightweight bridge.
   Check Platform Designer for the actual base address. */
#define ROOM_EQ_OFFSET  0x00000000  /* TODO: update from Platform Designer */

#define CTRL_REG    0   /* word offset 0: bit 0 = sweep_start */

static int start_sweep(void)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem");
        return -1;
    }

    void *base = mmap(NULL, LW_BRIDGE_SPAN, PROT_READ | PROT_WRITE,
                       MAP_SHARED, fd, LW_BRIDGE_BASE);
    if (base == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return -1;
    }

    volatile unsigned int *periph =
        (volatile unsigned int *)((char *)base + ROOM_EQ_OFFSET);

    /* Write 1 to CTRL[0] to start sweep */
    periph[CTRL_REG] = 0x1;
    printf("Sweep started.\n");

    /* Read back status */
    unsigned int status = periph[CTRL_REG];
    printf("CTRL reg: 0x%08x (sweep_running = %d)\n",
           status, (status >> 1) & 1);

    munmap(base, LW_BRIDGE_SPAN);
    close(fd);
    return 0;
}

/* ── Main ─────────────────────────────────────────────────── */

int main(void)
{
    printf("Room EQ — Codec Init + Sweep Start\n");

    if (codec_init() < 0) {
        fprintf(stderr, "Codec initialization failed\n");
        return 1;
    }

    if (start_sweep() < 0) {
        fprintf(stderr, "Sweep start failed\n");
        return 1;
    }

    return 0;
}
