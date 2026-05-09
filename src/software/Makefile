# Makefile for building on the DE1-SoC (native ARM gcc)
#
# Usage:
#   make          — build eq binary
#   make driver   — build kernel module
#   make all      — build both
#   make clean    — remove build artifacts

CC      = gcc
CFLAGS  = -O2 -Wall -lm

.PHONY: all eq driver clean

all: eq driver

eq: eq.c eq.h room_eq/FIR/fir_design.c room_eq/FIR/fir_design.h room_eq/FIR/fir_internal.h
	$(CC) $(CFLAGS) -Iroom_eq/device_drivers eq.c room_eq/FIR/fir_design.c -o eq

driver:
	$(MAKE) -C room_eq/device_drivers

clean:
	rm -f eq
	$(MAKE) -C room_eq/device_drivers clean
