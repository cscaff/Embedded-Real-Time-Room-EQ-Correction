/*
 * test_room_eq.c — userspace logic test for the room_eq kernel driver
 *
 * Tests ioctl dispatch, register masking, WM8731 byte-packing, and I2C
 * error handling from room_eq.c — without a kernel or FPGA.
 *
 * Mirrors logic in room_eq.c. If you change the driver, update here too.
 *
 * Compile:  clang -Wall -Wno-unused-function -o test_room_eq test_room_eq.c
 * Run:      ./test_room_eq
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>

/* ── Kernel type stubs ─────────────────────────────────────── */

typedef uint8_t  u8;
typedef uint16_t u16;
typedef uint32_t u32;

/* ── ioctl struct definitions (from room_eq.h) ─────────────── */

typedef struct { unsigned int   sweep_start; } room_eq_ctrl_t;
typedef struct { unsigned char  addr;
                 unsigned int   data;        } room_eq_lut_t;
typedef struct { unsigned short addr;        } room_eq_fft_addr_t;
typedef struct { unsigned int   rdata;
                 unsigned int   idata;       } room_eq_fft_data_t;
typedef struct { unsigned int   state;       } room_eq_status_t;
typedef struct { unsigned int   version;     } room_eq_version_t;

/* ── ioctl numbers — Linux bit layout ──────────────────────── */
/*
 * Linux encodes direction, size, type, and number into a u32:
 *   bits 31-30: direction  (01=write, 10=read)
 *   bits 29-16: struct size
 *   bits 15-8:  magic type byte
 *   bits 7-0:   command number
 */
#define _IOC(dir,type,nr,size) (((dir)<<30)|((size)<<16)|((unsigned)(type)<<8)|(nr))
#define _IOC_WRITE 1u
#define _IOC_READ  2u
#define _IOR(type,nr,size) _IOC(_IOC_READ,  type, nr, sizeof(size))
#define _IOW(type,nr,size) _IOC(_IOC_WRITE, type, nr, sizeof(size))

#define ROOM_EQ_MAGIC          'q'
#define ROOM_EQ_WRITE_CTRL     _IOW(ROOM_EQ_MAGIC, 1, room_eq_ctrl_t)
#define ROOM_EQ_WRITE_LUT      _IOW(ROOM_EQ_MAGIC, 2, room_eq_lut_t)
#define ROOM_EQ_WRITE_FFT_ADDR _IOW(ROOM_EQ_MAGIC, 3, room_eq_fft_addr_t)
#define ROOM_EQ_READ_STATUS    _IOR(ROOM_EQ_MAGIC, 4, room_eq_status_t)
#define ROOM_EQ_READ_VERSION   _IOR(ROOM_EQ_MAGIC, 5, room_eq_version_t)
#define ROOM_EQ_READ_FFT_ADDR  _IOR(ROOM_EQ_MAGIC, 6, room_eq_fft_addr_t)
#define ROOM_EQ_READ_FFT_DATA  _IOR(ROOM_EQ_MAGIC, 7, room_eq_fft_data_t)

/* ── EQ peripheral register byte offsets (from room_eq.c) ──── */

#define REG_CTRL      0x00
#define REG_STATUS    0x04
#define REG_VERSION   0x0C
#define REG_LUT_ADDR  0x10
#define REG_LUT_DATA  0x14
#define REG_FFT_ADDR  0x18
#define REG_FFT_RDATA 0x1C
#define REG_FFT_IDATA 0x20

/* ── Avalon I2C master register byte offsets (from room_eq.c) ─ */

#define I2C_TFR_CMD  0x00
#define I2C_ISR      0x10
#define I2C_STATUS   0x14

#define I2C_BUSY     (1u << 0)
#define I2C_NACK     (1u << 2)
#define TFR_CMD_STA  (1u << 9)
#define TFR_CMD_STO  (1u << 8)
#define WM8731_ADDR  0x1A

/* ── Simulated register banks ───────────────────────────────── */

#define N_REGS   16
#define MAX_LOG  64

static u32 eq_regs[N_REGS];
static u32 i2c_regs[N_REGS];

/* Ordered log of writes to I2C_TFR_CMD to verify transaction byte sequence. */
static u32 i2c_tfr_log[MAX_LOG];
static int i2c_tfr_count;

/* Fault-injection flags — set in individual tests. */
static int sim_i2c_busy;   /* 1 = STATUS always shows BUSY (simulates stuck bus) */
static int sim_i2c_nack;   /* 1 = ISR always shows NACK received                */
static int sim_copy_fail;  /* 1 = copy_from/to_user returns error                */

static void *eq_base;
static void *i2c_base;

static void reset_sim(void)
{
    memset(eq_regs,      0, sizeof(eq_regs));
    memset(i2c_regs,     0, sizeof(i2c_regs));
    memset(i2c_tfr_log,  0, sizeof(i2c_tfr_log));
    i2c_tfr_count = 0;
    sim_i2c_busy  = 0;
    sim_i2c_nack  = 0;
    sim_copy_fail = 0;
}

/* ── MMIO stubs ─────────────────────────────────────────────── */
/* eq_base / i2c_base point at the arrays above; offset is a byte offset. */

static void iowrite32(u32 val, void *addr) { *(u32 *)addr = val; }
static u32  ioread32(void *addr)           { return *(u32 *)addr; }

static void eq_wr(u32 off, u32 val)
{
    iowrite32(val, (char *)eq_base + off);
}
static u32 eq_rd(u32 off)
{
    return ioread32((char *)eq_base + off);
}

static void i2c_wr(u32 off, u32 val)
{
    if (off == I2C_TFR_CMD && i2c_tfr_count < MAX_LOG)
        i2c_tfr_log[i2c_tfr_count++] = val;
    iowrite32(val, (char *)i2c_base + off);
}
static u32 i2c_rd(u32 off)
{
    if (off == I2C_STATUS && sim_i2c_busy) return I2C_BUSY;
    if (off == I2C_ISR    && sim_i2c_nack) return I2C_NACK;
    return ioread32((char *)i2c_base + off);
}

/* ── copy_from/to_user stubs ────────────────────────────────── */

static int copy_from_user(void *to, const void *from, size_t n)
{
    if (sim_copy_fail) return 1;
    memcpy(to, from, n);
    return 0;
}
static int copy_to_user(void *to, const void *from, size_t n)
{
    if (sim_copy_fail) return 1;
    memcpy(to, from, n);
    return 0;
}

/* ── Driver logic — mirrors room_eq.c exactly ───────────────── */

static int i2c_wait_idle(void)
{
    int timeout = 100000;
    while ((i2c_rd(I2C_STATUS) & I2C_BUSY) && --timeout > 0)
        ;   /* udelay(1) is a no-op in test */
    if (timeout == 0)
        return -ETIMEDOUT;
    return 0;
}

static int wm8731_write(u8 reg, u16 data)
{
    u8  byte1 = (reg << 1) | ((data >> 8) & 0x01);
    u8  byte2 = data & 0xFF;
    u32 isr;
    int ret;

    ret = i2c_wait_idle();
    if (ret) return ret;

    i2c_wr(I2C_TFR_CMD, TFR_CMD_STA | (WM8731_ADDR << 1) | 0);
    i2c_wr(I2C_TFR_CMD, byte1);
    i2c_wr(I2C_TFR_CMD, TFR_CMD_STO | byte2);

    ret = i2c_wait_idle();
    if (ret) return ret;

    isr = i2c_rd(I2C_ISR);
    if (isr & I2C_NACK) {
        i2c_wr(I2C_ISR, isr);  /* write-back clears NACK flag on hardware */
        return -EIO;
    }
    return 0;
}

static long room_eq_ioctl(unsigned int cmd, unsigned long arg)
{
    room_eq_ctrl_t     ctrl;
    room_eq_lut_t      lut;
    room_eq_fft_addr_t fft_addr;
    room_eq_fft_data_t fft_data;
    room_eq_status_t   status;
    room_eq_version_t  version;

    switch (cmd) {
    case ROOM_EQ_WRITE_CTRL:
        if (copy_from_user(&ctrl, (void *)arg, sizeof(ctrl)))
            return -EACCES;
        eq_wr(REG_CTRL, ctrl.sweep_start & 0x1u);
        break;

    case ROOM_EQ_WRITE_LUT:
        if (copy_from_user(&lut, (void *)arg, sizeof(lut)))
            return -EACCES;
        eq_wr(REG_LUT_ADDR, lut.addr & 0xFFu);
        eq_wr(REG_LUT_DATA, lut.data & 0xFFFFFFu);
        break;

    case ROOM_EQ_WRITE_FFT_ADDR:
        if (copy_from_user(&fft_addr, (void *)arg, sizeof(fft_addr)))
            return -EACCES;
        eq_wr(REG_FFT_ADDR, fft_addr.addr & 0x1FFFu);
        break;

    case ROOM_EQ_READ_STATUS:
        status.state = eq_rd(REG_STATUS) & 0xFu;
        if (copy_to_user((void *)arg, &status, sizeof(status)))
            return -EACCES;
        break;

    case ROOM_EQ_READ_VERSION:
        version.version = eq_rd(REG_VERSION);
        if (copy_to_user((void *)arg, &version, sizeof(version)))
            return -EACCES;
        break;

    case ROOM_EQ_READ_FFT_ADDR:
        fft_addr.addr = eq_rd(REG_FFT_ADDR) & 0x1FFFu;
        if (copy_to_user((void *)arg, &fft_addr, sizeof(fft_addr)))
            return -EACCES;
        break;

    case ROOM_EQ_READ_FFT_DATA:
        fft_data.rdata = eq_rd(REG_FFT_RDATA) & 0xFFFFFFu;
        fft_data.idata = eq_rd(REG_FFT_IDATA) & 0xFFFFFFu;
        if (copy_to_user((void *)arg, &fft_data, sizeof(fft_data)))
            return -EACCES;
        break;

    default:
        return -EINVAL;
    }
    return 0;
}

/* ── Test harness ───────────────────────────────────────────── */

static int tests_run    = 0;
static int tests_passed = 0;

#define CHECK(cond, name) do {                                          \
    tests_run++;                                                        \
    if (cond) {                                                         \
        tests_passed++;                                                 \
        printf("  PASS  %s\n", name);                                  \
    } else {                                                            \
        printf("  FAIL  %s  (line %d)\n", name, __LINE__);             \
    }                                                                   \
} while (0)

/* ── ioctl tests ────────────────────────────────────────────── */

static void test_write_ctrl(void)
{
    room_eq_ctrl_t ctrl;
    long ret;

    printf("WRITE_CTRL\n");

    reset_sim();
    ctrl.sweep_start = 1;
    ret = room_eq_ioctl(ROOM_EQ_WRITE_CTRL, (unsigned long)&ctrl);
    CHECK(ret == 0,                    "returns 0 on success");
    CHECK(eq_regs[REG_CTRL/4] == 1,   "sweep_start=1 reaches REG_CTRL");

    reset_sim();
    ctrl.sweep_start = 0;
    room_eq_ioctl(ROOM_EQ_WRITE_CTRL, (unsigned long)&ctrl);
    CHECK(eq_regs[REG_CTRL/4] == 0,   "sweep_start=0 reaches REG_CTRL");

    /* Userspace passes garbage — only bit 0 should survive */
    reset_sim();
    ctrl.sweep_start = 0xFFFFFFFF;
    room_eq_ioctl(ROOM_EQ_WRITE_CTRL, (unsigned long)&ctrl);
    CHECK(eq_regs[REG_CTRL/4] == 1,   "0xFFFFFFFF masked to bit 0 only");

    reset_sim();
    sim_copy_fail = 1;
    ret = room_eq_ioctl(ROOM_EQ_WRITE_CTRL, (unsigned long)&ctrl);
    CHECK(ret == -EACCES,              "copy_from_user failure → -EACCES");
}

static void test_write_lut(void)
{
    room_eq_lut_t lut;

    printf("WRITE_LUT\n");

    reset_sim();
    lut.addr = 0xAB;
    lut.data = 0x123456;
    room_eq_ioctl(ROOM_EQ_WRITE_LUT, (unsigned long)&lut);
    CHECK(eq_regs[REG_LUT_ADDR/4] == 0xAB,     "addr=0xAB written to REG_LUT_ADDR");
    CHECK(eq_regs[REG_LUT_DATA/4] == 0x123456,  "data=0x123456 written to REG_LUT_DATA");

    /* data is 32-bit in the struct but the register is only 24 bits */
    reset_sim();
    lut.data = 0xAABBCCDD;
    room_eq_ioctl(ROOM_EQ_WRITE_LUT, (unsigned long)&lut);
    CHECK(eq_regs[REG_LUT_DATA/4] == (0xAABBCCDD & 0xFFFFFFu),
          "upper byte stripped by 24-bit mask");
}

static void test_write_fft_addr(void)
{
    room_eq_fft_addr_t fa;

    printf("WRITE_FFT_ADDR\n");

    reset_sim();
    fa.addr = 0x1FFF;   /* maximum 13-bit value */
    room_eq_ioctl(ROOM_EQ_WRITE_FFT_ADDR, (unsigned long)&fa);
    CHECK(eq_regs[REG_FFT_ADDR/4] == 0x1FFF, "max 13-bit addr written");

    reset_sim();
    fa.addr = 0x3FFF;   /* bit 13 set — should be stripped */
    room_eq_ioctl(ROOM_EQ_WRITE_FFT_ADDR, (unsigned long)&fa);
    CHECK(eq_regs[REG_FFT_ADDR/4] == 0x1FFF, "bit 13 stripped by 0x1FFF mask");
}

static void test_read_status(void)
{
    room_eq_status_t status;

    printf("READ_STATUS\n");

    reset_sim();
    eq_regs[REG_STATUS/4] = 3;  /* DONE */
    room_eq_ioctl(ROOM_EQ_READ_STATUS, (unsigned long)&status);
    CHECK(status.state == 3, "DONE state (3) read back");

    reset_sim();
    eq_regs[REG_STATUS/4] = 0xFF;   /* only [3:0] should reach userspace */
    room_eq_ioctl(ROOM_EQ_READ_STATUS, (unsigned long)&status);
    CHECK(status.state == 0xF, "upper bits stripped by 4-bit mask");

    reset_sim();
    sim_copy_fail = 1;
    long ret = room_eq_ioctl(ROOM_EQ_READ_STATUS, (unsigned long)&status);
    CHECK(ret == -EACCES, "copy_to_user failure → -EACCES");
}

static void test_read_version(void)
{
    room_eq_version_t ver;

    printf("READ_VERSION\n");

    reset_sim();
    eq_regs[REG_VERSION/4] = 0x00010000;
    room_eq_ioctl(ROOM_EQ_READ_VERSION, (unsigned long)&ver);
    CHECK(ver.version == 0x00010000, "version 0x00010000 read back");
}

static void test_read_fft_data(void)
{
    room_eq_fft_data_t fd;

    printf("READ_FFT_DATA\n");

    reset_sim();
    eq_regs[REG_FFT_RDATA/4] = 0xABCDEF;
    eq_regs[REG_FFT_IDATA/4] = 0x123456;
    room_eq_ioctl(ROOM_EQ_READ_FFT_DATA, (unsigned long)&fd);
    CHECK(fd.rdata == 0xABCDEF, "rdata=0xABCDEF read back");
    CHECK(fd.idata == 0x123456, "idata=0x123456 read back");

    /* register holds 32 bits but only [23:0] should reach userspace */
    reset_sim();
    eq_regs[REG_FFT_RDATA/4] = 0xFFFFFFFF;
    eq_regs[REG_FFT_IDATA/4] = 0xFFFFFFFF;
    room_eq_ioctl(ROOM_EQ_READ_FFT_DATA, (unsigned long)&fd);
    CHECK(fd.rdata == 0xFFFFFF, "rdata: bit 24+ stripped");
    CHECK(fd.idata == 0xFFFFFF, "idata: bit 24+ stripped");
}

static void test_invalid_ioctl(void)
{
    printf("invalid cmd\n");
    long ret = room_eq_ioctl(0xDEADBEEF, 0);
    CHECK(ret == -EINVAL, "unknown cmd → -EINVAL");
}

/* ── WM8731 I2C tests ───────────────────────────────────────── */

static void test_wm8731_byte_packing(void)
{
    printf("WM8731 byte packing\n");

    /*
     * reg=0x07 (Digital Audio Interface Format), data=0x00A
     *   byte1 = (0x07 << 1) | ((0x00A >> 8) & 1) = 0x0E | 0 = 0x0E
     *   byte2 = 0x0A
     * Expected TFR sequence:
     *   [0] START | (WM8731_ADDR << 1)   = 0x200 | 0x34 = 0x234
     *   [1] byte1                         = 0x0E
     *   [2] STOP  | byte2                 = 0x100 | 0x0A = 0x10A
     */
    reset_sim();
    wm8731_write(0x07, 0x00A);
    CHECK(i2c_tfr_log[0] == (TFR_CMD_STA | (WM8731_ADDR << 1)),
          "TFR[0]: START + slave addr");
    CHECK(i2c_tfr_log[1] == 0x0E,
          "TFR[1]: byte1 = (reg<<1)|(data[8]) = 0x0E");
    CHECK(i2c_tfr_log[2] == (TFR_CMD_STO | 0x0A),
          "TFR[2]: STOP | byte2 = 0x0A");

    /*
     * reg=0x00 (Left Line In), data=0x117  — data bit 8 is set
     *   byte1 = (0x00 << 1) | ((0x117 >> 8) & 1) = 0 | 1 = 0x01
     *   byte2 = 0x17
     */
    reset_sim();
    wm8731_write(0x00, 0x117);
    CHECK(i2c_tfr_log[1] == 0x01,
          "byte1 carries data[8] when set");
    CHECK(i2c_tfr_log[2] == (TFR_CMD_STO | 0x17),
          "byte2 = data[7:0] = 0x17");

    /*
     * reg=0x0F (Reset), data=0x000 — all zero
     *   byte1 = 0x1E, byte2 = 0x00
     */
    reset_sim();
    wm8731_write(0x0F, 0x000);
    CHECK(i2c_tfr_log[1] == 0x1E, "Reset reg: byte1 = (0x0F<<1) = 0x1E");
    CHECK(i2c_tfr_log[2] == (TFR_CMD_STO | 0x00), "Reset reg: byte2 = 0x00");
}

static void test_i2c_wait_idle(void)
{
    printf("i2c_wait_idle\n");

    reset_sim();
    CHECK(i2c_wait_idle() == 0, "idle bus → 0");

    reset_sim();
    sim_i2c_busy = 1;
    CHECK(i2c_wait_idle() == -ETIMEDOUT, "stuck bus → -ETIMEDOUT");
}

static void test_wm8731_nack(void)
{
    printf("WM8731 NACK handling\n");

    reset_sim();
    sim_i2c_nack = 1;
    int ret = wm8731_write(0x00, 0x017);
    CHECK(ret == -EIO, "NACK → -EIO");
    /* Driver must write back ISR to clear the NACK flag on hardware */
    CHECK(i2c_regs[I2C_ISR/4] == I2C_NACK,
          "ISR written back to clear NACK bit");

    /* Stuck bus: i2c_wait_idle fires before we even touch TFR_CMD */
    reset_sim();
    sim_i2c_busy = 1;
    ret = wm8731_write(0x00, 0x017);
    CHECK(ret == -ETIMEDOUT,     "stuck bus → -ETIMEDOUT before TFR write");
    CHECK(i2c_tfr_count == 0,   "no TFR_CMD bytes sent when bus is stuck");
}

/* ── main ───────────────────────────────────────────────────── */

int main(void)
{
    eq_base  = (void *)eq_regs;
    i2c_base = (void *)i2c_regs;

    printf("=== room_eq driver logic tests ===\n\n");

    test_write_ctrl();       printf("\n");
    test_write_lut();        printf("\n");
    test_write_fft_addr();   printf("\n");
    test_read_status();      printf("\n");
    test_read_version();     printf("\n");
    test_read_fft_data();    printf("\n");
    test_invalid_ioctl();    printf("\n");
    test_wm8731_byte_packing(); printf("\n");
    test_i2c_wait_idle();    printf("\n");
    test_wm8731_nack();      printf("\n");

    printf("%d/%d passed\n", tests_passed, tests_run);
    return (tests_passed == tests_run) ? 0 : 1;
}
