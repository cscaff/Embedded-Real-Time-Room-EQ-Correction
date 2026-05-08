KDIR ?= /lib/modules/$(shell uname -r)/build

obj-m := room_eq.o

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
