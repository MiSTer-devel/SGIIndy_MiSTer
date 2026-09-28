# wborder - build the dirty-victim ordering image (see wborder.c).
#
# start.S and link.ld are shared with tests/dma, as tests/scsiwr does.
CROSS  ?= mipsel-linux-gnu-
CC     := $(CROSS)gcc
LD     := $(CROSS)ld
OBJDUMP:= $(CROSS)objdump

SHARED := ../dma

ARCH   := -march=mips3 -mabi=n32 -EB -mno-abicalls -fno-pic -G0 -msoft-float
CFLAGS := $(ARCH) -ffreestanding -nostdlib -nostdinc -fno-builtin \
          -fomit-frame-pointer -O1 -g -std=gnu11 -Wall -Wextra -Werror
LDFLAGS:= -EB -T $(SHARED)/link.ld -nostdlib --no-warn-mismatch

all: build/wborder.elf

build/wborder.elf: wborder.c $(SHARED)/start.S $(SHARED)/link.ld
	@mkdir -p build
	$(CC) $(CFLAGS) -c -o build/wborder.o wborder.c
	$(CC) $(ARCH) -ffreestanding -nostdlib -c -o build/start.o $(SHARED)/start.S
	$(LD) $(LDFLAGS) -o $@ build/wborder.o build/start.o
	@$(OBJDUMP) -h $@ | head -8

dis: build/wborder.elf
	$(OBJDUMP) -d $<

clean:
	rm -rf build
