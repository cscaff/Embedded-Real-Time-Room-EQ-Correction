//
// ====== room_eq.h — ioctl interface for the Room EQ kernel driver ====== 
//
// Shared between kernel driver (room_eq.c) and userspace applications.
//
// Register map (from room_eq_peripheral.sv, word offsets × 4 = byte offset):
//   0x00  CTRL      W     bit 0 = sweep_start (self-clears next cycle)
//   0x04  STATUS    R     [3:0] FSM state: 0=IDLE 1=SWEEP 2=CAPTURE 3=DONE
//   0x0C  VERSION   R     32'h0001_0000
//   0x10  LUT_ADDR  W     [7:0]  sine-LUT write address
//   0x14  LUT_DATA  W     [23:0] sine-LUT write data  (fires we_lut pulse)
//   0x18  FFT_ADDR  R/W   [12:0] FFT result RAM read address
//   0x1C  FFT_RDATA R     [23:0] FFT real  part at FFT_ADDR
//   0x20  FFT_IDATA R     [23:0] FFT imag  part at FFT_ADDR
//
// ==========================================================================

#ifndef ROOM_EQ_H
#define ROOM_EQ_H

#include <linux/ioctl.h>

/* Argument structures */

typedef struct {
    unsigned int sweep_start; // 1 to trigger, 0 to no-op
} room_eq_ctrl_t;

typedef struct {
    unsigned char  addr; // [7:0]  LUT address
    unsigned int   data; // [23:0] LUT data   
} room_eq_lut_t;

typedef struct {
    unsigned short addr; // [12:0] FFT RAM address
} room_eq_fft_addr_t;

typedef struct {
    unsigned int rdata; // [23:0] real part 
    unsigned int idata; // [23:0] imag part 
} room_eq_fft_data_t;

typedef struct {
    unsigned int state; // [3:0]: 0=IDLE 1=SWEEP 2=CAPTURE 3=DONE
} room_eq_status_t;

typedef struct {
    unsigned int version; // e.g. 0x00010000 
} room_eq_version_t;

#define ROOM_EQ_MAGIC 'q'

/* ioctl commands */

#define ROOM_EQ_WRITE_CTRL      _IOW(ROOM_EQ_MAGIC, 1, room_eq_ctrl_t)
#define ROOM_EQ_WRITE_LUT       _IOW(ROOM_EQ_MAGIC, 2, room_eq_lut_t)
#define ROOM_EQ_WRITE_FFT_ADDR  _IOW(ROOM_EQ_MAGIC, 3, room_eq_fft_addr_t)
#define ROOM_EQ_READ_STATUS     _IOR(ROOM_EQ_MAGIC, 4, room_eq_status_t)
#define ROOM_EQ_READ_VERSION    _IOR(ROOM_EQ_MAGIC, 5, room_eq_version_t)
#define ROOM_EQ_READ_FFT_ADDR   _IOR(ROOM_EQ_MAGIC, 6, room_eq_fft_addr_t)
#define ROOM_EQ_READ_FFT_DATA   _IOR(ROOM_EQ_MAGIC, 7, room_eq_fft_data_t)

#endif
