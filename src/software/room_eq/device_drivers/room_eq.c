// ===== Device driver for the Room EQ peripheral =====
//
// A Platform device implemented using the misc subsystem.
//
// Jacob Boxerman, Roland List, Christian Scaff
// CSEE 4840 Spring 2026
//
// On probe the driver:
//   1. Maps the Avalon I2C master (device tree reg index 0)
//   2. Maps the room_eq_peripheral (device tree reg index 1)
//   3. Initializes the WM8731 codec via I2C (I2S slave, 24-bit, 48 kHz)
//   4. Exposes /dev/room_eq for ioctl access to all peripheral registers
//
// "make" to build
// insmod room_eq.ko
//
// ========================================================

#include <linux/module.h>
#include <linux/init.h>
#include <linux/errno.h>
#include <linux/version.h>
#include <linux/kernel.h>
#include <linux/platform_device.h>
#include <linux/miscdevice.h>
#include <linux/slab.h>
#include <linux/io.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/delay.h> // New 
#include "room_eq.h"

#define DRIVER_NAME "room_eq"

/* ── Avalon I2C master register byte offsets ─────────────── */
/* See Intel Avalon I2C Master Core User Guide */
#define I2C_TFR_CMD           0x00 /* Transfer Command FIFO */
#define I2C_RX_DATA           0x04 /* Receive Data FIFO */
#define I2C_CTRL              0x08 /* Control register */
#define I2C_ISR               0x10 /* Interrupt Status */
#define I2C_STATUS            0x14 /* Status register */
#define I2C_SCL_LOW           0x20 /* SCL Low Count */
#define I2C_SCL_HIGH          0x24 /* SCL High Count */
#define I2C_SDA_HOLD          0x28 /* SDA Hold Count */

// Using unsigned constants for bit masks.
#define TFR_CMD_STA  (1u << 9)  /* START condition. */
#define TFR_CMD_STO  (1u << 8)  /* STOP condition */
#define I2C_BUSY     (1u << 0)  /* STATUS bit 0: core busy    */ // TODO: understand
#define I2C_CTRL_EN  (1u << 0)  /* CTRL  bit 0: core enable   */ // TODO: understand
#define I2C_NACK     (1u << 2)  /* ISR   bit 2: NACK received */ // TODO: understand

#define WM8731_ADDR  0x1A       /* 7-bit I2C address          */

/* ── room_eq_peripheral register byte offsets ────────────── */
#define REG_CTRL      0x00   /* W    bit 0 = sweep_start      */
#define REG_STATUS    0x04   /* R    [3:0] FSM state          */
#define REG_RESERVED  0x08   /* -    reserved for future use (Was Sweep Length) */
#define REG_VERSION   0x0C   /* R    32'h0001_0000            */
#define REG_LUT_ADDR  0x10   /* W    [7:0]  LUT write address */
#define REG_LUT_DATA  0x14   /* W    [23:0] LUT write data    */
#define REG_FFT_ADDR  0x18   /* R/W  [12:0] FFT read address  */
#define REG_FFT_RDATA 0x1C   /* R    [23:0] FFT real part     */
#define REG_FFT_IDATA 0x20   /* R    [23:0] FFT imag part     */

struct room_eq_dev {
    struct resource  i2c_res;
    struct resource  eq_res;
    void __iomem    *i2c_base;
    void __iomem    *eq_base;
} dev;

/* ── I2C helpers ──────────────────────────────────────────── */

static inline void i2c_wr(u32 offset, u32 val)
{
    iowrite32(val, dev.i2c_base + offset);
}

static inline u32 i2c_rd(u32 offset)
{
    return ioread32(dev.i2c_base + offset);
}

static int i2c_wait_idle(void)
{
    int timeout = 100000;

    while ((i2c_rd(I2C_STATUS) & I2C_BUSY) && --timeout > 0)
        udelay(1);
    if (timeout == 0) {
        pr_err(DRIVER_NAME ": I2C timeout\n");
        return -ETIMEDOUT;
    }
    return 0;
}

static void i2c_init(void)
{
    i2c_wr(I2C_CTRL, 0);           /* disable during setup                   */
    i2c_wr(I2C_SCL_LOW,  250);     /* 50 MHz / 100 kHz: low  half = 250 cnt  */
    i2c_wr(I2C_SCL_HIGH, 250);     /*                   high half = 250 cnt  */
    i2c_wr(I2C_SDA_HOLD,  30);
    i2c_wr(I2C_CTRL, I2C_CTRL_EN);
    udelay(1000);
}

/*
 * Write one WM8731 register: 7-bit reg addr + 9-bit data packed as two bytes.
 *   byte1 = {reg[6:0], data[8]}
 *   byte2 = data[7:0]
 */
static int wm8731_write(u8 reg, u16 data)
{
    u8  byte1 = (reg << 1) | ((data >> 8) & 0x01);
    u8  byte2 = data & 0xFF;
    u32 isr;
    int ret;

    ret = i2c_wait_idle();
    if (ret)
        return ret;

    i2c_wr(I2C_TFR_CMD, TFR_CMD_STA | (WM8731_ADDR << 1) | 0); /* START + addr */
    i2c_wr(I2C_TFR_CMD, byte1);
    i2c_wr(I2C_TFR_CMD, TFR_CMD_STO | byte2);                   /* data + STOP  */

    ret = i2c_wait_idle();
    if (ret)
        return ret;

    isr = i2c_rd(I2C_ISR);
    if (isr & I2C_NACK) {
        i2c_wr(I2C_ISR, isr);   /* clear NACK flag */
        pr_err(DRIVER_NAME ": NACK on WM8731 reg 0x%02x\n", reg);
        return -EIO;
    }
    return 0;
}

static int codec_init(void)
{
    int err = 0;

    pr_info(DRIVER_NAME ": initializing Avalon I2C master\n");
    i2c_init();

    pr_info(DRIVER_NAME ": configuring WM8731\n");

    err |= wm8731_write(0x0F, 0x000);  /* Reset                        */
    msleep(10);
    err |= wm8731_write(0x00, 0x017);  /* Left  Line In: 0 dB, unmuted */
    err |= wm8731_write(0x01, 0x017);  /* Right Line In: 0 dB, unmuted */
    err |= wm8731_write(0x02, 0x079);  /* Left  HP Out:  near-max vol  */
    err |= wm8731_write(0x03, 0x079);  /* Right HP Out:  near-max vol  */
    err |= wm8731_write(0x04, 0x012);  /* Analog path:   DAC, line in  */
    err |= wm8731_write(0x05, 0x000);  /* Digital path:  no mute       */
    err |= wm8731_write(0x06, 0x000);  /* Power:         all on        */
    err |= wm8731_write(0x07, 0x00A);  /* Format: I2S, 24-bit, slave   */
    err |= wm8731_write(0x08, 0x000);  /* Sampling: normal, 48 kHz     */
    err |= wm8731_write(0x09, 0x001);  /* Active                       */

    if (err)
        pr_warn(DRIVER_NAME ": codec init had one or more errors\n");
    else
        pr_info(DRIVER_NAME ": codec ready: I2S slave, 24-bit, 48 kHz\n");

    return err ? -EIO : 0;
}

/* ── room_eq peripheral helpers ──────────────────────────── */

static inline void eq_wr(u32 offset, u32 val)
{
    iowrite32(val, dev.eq_base + offset);
}

static inline u32 eq_rd(u32 offset)
{
    return ioread32(dev.eq_base + offset);
}

/* ── ioctl ────────────────────────────────────────────────── */

static long room_eq_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
    room_eq_ctrl_t      ctrl;
    room_eq_lut_t       lut;
    room_eq_fft_addr_t  fft_addr;
    room_eq_fft_data_t  fft_data;
    room_eq_status_t    status;
    room_eq_version_t   version;

    switch (cmd) {
    case ROOM_EQ_WRITE_CTRL:
        if (copy_from_user(&ctrl, (room_eq_ctrl_t __user *)arg, sizeof(ctrl)))
            return -EACCES;
        eq_wr(REG_CTRL, ctrl.sweep_start & 0x1u);
        break;

    case ROOM_EQ_WRITE_LUT:
        if (copy_from_user(&lut, (room_eq_lut_t __user *)arg, sizeof(lut)))
            return -EACCES;
        eq_wr(REG_LUT_ADDR, lut.addr & 0xFFu);
        eq_wr(REG_LUT_DATA, lut.data & 0xFFFFFFu);
        break;

    case ROOM_EQ_WRITE_FFT_ADDR:
        if (copy_from_user(&fft_addr, (room_eq_fft_addr_t __user *)arg, sizeof(fft_addr)))
            return -EACCES;
        eq_wr(REG_FFT_ADDR, fft_addr.addr & 0x1FFFu);
        break;

    case ROOM_EQ_READ_STATUS:
        status.state = eq_rd(REG_STATUS) & 0xFu;
        if (copy_to_user((room_eq_status_t __user *)arg, &status, sizeof(status)))
            return -EACCES;
        break;

    case ROOM_EQ_READ_VERSION:
        version.version = eq_rd(REG_VERSION);
        if (copy_to_user((room_eq_version_t __user *)arg, &version, sizeof(version)))
            return -EACCES;
        break;

    case ROOM_EQ_READ_FFT_ADDR:
        fft_addr.addr = eq_rd(REG_FFT_ADDR) & 0x1FFFu;
        if (copy_to_user((room_eq_fft_addr_t __user *)arg, &fft_addr, sizeof(fft_addr)))
            return -EACCES;
        break;

    case ROOM_EQ_READ_FFT_DATA:
        fft_data.rdata = eq_rd(REG_FFT_RDATA) & 0xFFFFFFu;
        fft_data.idata = eq_rd(REG_FFT_IDATA) & 0xFFFFFFu;
        if (copy_to_user((room_eq_fft_data_t __user *)arg, &fft_data, sizeof(fft_data)))
            return -EACCES;
        break;

    default:
        return -EINVAL;
    }

    return 0;
}

static const struct file_operations room_eq_fops = {
    .owner          = THIS_MODULE,
    .unlocked_ioctl = room_eq_ioctl,
};

static struct miscdevice room_eq_misc_device = {
    .minor = MISC_DYNAMIC_MINOR,
    .name  = DRIVER_NAME,
    .fops  = &room_eq_fops,
};

/* ── Probe ────────────────────────────────────────────────── */

static int __init room_eq_probe(struct platform_device *pdev)
{
    int ret;

    /* Map Avalon I2C master (device tree reg index 0) */
    ret = of_address_to_resource(pdev->dev.of_node, 0, &dev.i2c_res);
    if (ret) {
        pr_err(DRIVER_NAME ": no I2C resource in device tree\n");
        return -ENOENT;
    }
    if (!request_mem_region(dev.i2c_res.start, resource_size(&dev.i2c_res),
                            DRIVER_NAME)) {
        pr_err(DRIVER_NAME ": I2C region busy\n");
        return -EBUSY;
    }
    dev.i2c_base = of_iomap(pdev->dev.of_node, 0);
    if (!dev.i2c_base) {
        ret = -ENOMEM;
        goto out_release_i2c;
    }

    /* Map room_eq peripheral (device tree reg index 1) */
    ret = of_address_to_resource(pdev->dev.of_node, 1, &dev.eq_res);
    if (ret) {
        pr_err(DRIVER_NAME ": no room_eq resource in device tree\n");
        ret = -ENOENT;
        goto out_unmap_i2c;
    }
    if (!request_mem_region(dev.eq_res.start, resource_size(&dev.eq_res),
                            DRIVER_NAME)) {
        pr_err(DRIVER_NAME ": room_eq region busy\n");
        ret = -EBUSY;
        goto out_unmap_i2c;
    }
    dev.eq_base = of_iomap(pdev->dev.of_node, 1);
    if (!dev.eq_base) {
        ret = -ENOMEM;
        goto out_release_eq;
    }

    /* Initialize WM8731 codec on module load */
    if (codec_init() < 0)
        pr_warn(DRIVER_NAME ": codec init had errors — continuing\n");

    /* Register /dev/room_eq only after hardware is ready */
    ret = misc_register(&room_eq_misc_device);
    if (ret) {
        pr_err(DRIVER_NAME ": misc_register failed (%d)\n", ret);
        goto out_unmap_eq;
    }

    pr_info(DRIVER_NAME ": /dev/room_eq ready\n");
    return 0;

out_unmap_eq:
    iounmap(dev.eq_base);
out_release_eq:
    release_mem_region(dev.eq_res.start, resource_size(&dev.eq_res));
out_unmap_i2c:
    iounmap(dev.i2c_base);
out_release_i2c:
    release_mem_region(dev.i2c_res.start, resource_size(&dev.i2c_res));
    return ret;
}

static int room_eq_remove(struct platform_device *pdev)
{
    misc_deregister(&room_eq_misc_device);
    iounmap(dev.eq_base);
    release_mem_region(dev.eq_res.start, resource_size(&dev.eq_res));
    iounmap(dev.i2c_base);
    release_mem_region(dev.i2c_res.start, resource_size(&dev.i2c_res));
    return 0;
}

/* ── Platform driver registration ────────────────────────── */

#ifdef CONFIG_OF
static const struct of_device_id room_eq_of_match[] = {
    { .compatible = "csee4840,room_eq-1.0" },
    {},
};
MODULE_DEVICE_TABLE(of, room_eq_of_match);
#endif

static struct platform_driver room_eq_driver = {
    .driver = {
        .name           = DRIVER_NAME,
        .owner          = THIS_MODULE,
        .of_match_table = of_match_ptr(room_eq_of_match),
    },
    .remove = __exit_p(room_eq_remove),
};

static int __init room_eq_init(void)
{
    pr_info(DRIVER_NAME ": init\n");
    return platform_driver_probe(&room_eq_driver, room_eq_probe);
}

static void __exit room_eq_exit(void)
{
    platform_driver_unregister(&room_eq_driver);
    pr_info(DRIVER_NAME ": exit\n");
}

module_init(room_eq_init);
module_exit(room_eq_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("CSEE W4840 Team");
MODULE_DESCRIPTION("Room EQ peripheral driver with WM8731 codec initialization");
