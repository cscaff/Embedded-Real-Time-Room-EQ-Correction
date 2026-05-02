CC = gcc
CFLAGS = -Wall -O2

all: codec_init

codec_init: codec_init.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f codec_init
