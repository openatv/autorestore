# fbprogress: the progress bar of FastRestore. LVGL is the submodule lib/lvgl, configured by include/lv_conf.h,
# the fonts are fonts/*.c from tools/mkfonts.sh.
CFLAGS ?= -Os
override CFLAGS += -Iinclude -Ilib/lvgl -DLV_CONF_INCLUDE_SIMPLE -ffunction-sections -fdata-sections
override LDFLAGS += -Wl,--gc-sections
LDLIBS = -lm

SRC = src/main.c src/bar.c $(wildcard fonts/*.c) $(shell find lib/lvgl/src -name '*.c')
OBJ = $(SRC:.c=.o)

all: fbprogress

fbprogress: $(OBJ)
	$(CC) $(LDFLAGS) -o $@ $(OBJ) $(LDLIBS)

src/main.o src/bar.o: src/main.h

install: fbprogress
	install -D -m 755 fbprogress $(DESTDIR)/usr/bin/fbprogress

clean:
	rm -f $(OBJ) fbprogress

.PHONY: all install clean
