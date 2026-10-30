# SPDX-License-Identifier: GPL-2.0-only
# Out-of-tree build of the VM-only test LED module.
#   make                  build against the running kernel
#   make KDIR=<dir>       build against another kernel build tree (e.g. in build/Containerfile)
# The .ko is a build output and is never committed (.gitignore: *.ko).
obj-m := ax20_test_led.o

KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

.PHONY: all clean
