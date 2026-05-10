CC = gcc
CFLAGS = -Wall -O2
LDFLAGS = -lm

all: codec_init room_analyze

codec_init: codec_init.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

room_analyze: room_analyze.c
	$(CC) $(CFLAGS) -o $@ $< -lfftw3 $(LDFLAGS)

clean:
	rm -f codec_init room_analyze
