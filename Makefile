DJGPP_PREFIX  ?= i686-pc-msdosdjgpp
DJGPP_BIN     := /usr/$(DJGPP_PREFIX)/bin
CC            := $(DJGPP_PREFIX)-gcc

VENDOR        := vendor
ALLEG_VER     := 4.2.3.1
ALLEG_TGZ     := $(VENDOR)/allegro-$(ALLEG_VER).tar.gz
ALLEG_URL     := https://github.com/liballeg/allegro5/releases/download/v4-2-3-1/allegro-$(ALLEG_VER).tar.gz
ALLEG_SRC     := $(VENDOR)/allegro-$(ALLEG_VER)
ALLEG_LIB     := $(ALLEG_SRC)/lib/djgpp/liballeg.a
ALLEG_INC     := $(ALLEG_SRC)/include
ALLEG_PLATF   := $(ALLEG_INC)/allegro/platform/alplatf.h

# Shim dir lets Allegro's legacy makefile find unprefixed `gcc`/`cc`/etc.
# Combined with $(DJGPP_BIN) on PATH (provides ar/as/ld/...), this is enough
# to drive `make lib CROSSCOMPILE=1` from a Linux host.
SHIM_DIR      := $(VENDOR)/shim
SHIM_STAMP    := $(SHIM_DIR)/.stamp

CWS_DIR       := $(VENDOR)/cwsdpmi
CWS_STUB      := $(CWS_DIR)/CWSDSTUB.EXE
CWS_URL       := https://raw.githubusercontent.com/jayschwa/cwsdpmi/master/bin/CWSDSTUB.EXE

BUILD         := build
RAW_EXE       := $(BUILD)/dos-game-raw.exe
COFF          := $(BUILD)/dos-game.coff
EXE           := dos-game.exe

ZIG           ?= zig
ZIG_SRC       := src/main.zig
ZIG_SRCS      := $(wildcard src/*.zig)
ZIG_C         := $(BUILD)/zig_main.c
ZIG_LIB_DIR   := $(shell $(ZIG) env 2>/dev/null | sed -n 's/^[[:space:]]*\.lib_dir = "\(.*\)",/\1/p')
ZIG_SHIM      := src/zig_shim.h

LDLIBS        := $(ALLEG_LIB) -lm

.PHONY: all run clean distclean
.DEFAULT_GOAL := all
.SUFFIXES:

all: $(EXE)

$(EXE): $(CWS_STUB) $(COFF)
	cat $(CWS_STUB) $(COFF) > $@

# Strip the DJGPP MZ stub from the raw .exe, leaving a pure COFF image.
# MZ header: e_cblp @ +0x02 (bytes in last page), e_cp @ +0x04 (pages).
# Stub size = e_cblp == 0 ? e_cp*512 : (e_cp-1)*512 + e_cblp.
$(COFF): $(RAW_EXE)
	@cblp=$$(od -An -t u2 -N2 -j2 $< | tr -d ' '); \
	cp=$$(od -An -t u2 -N2 -j4 $< | tr -d ' '); \
	if [ $$cblp -eq 0 ]; then size=$$((cp * 512)); \
	else size=$$(((cp - 1) * 512 + cblp)); fi; \
	tail -c +$$((size + 1)) $< > $@

$(RAW_EXE): $(BUILD)/zig_main.o $(BUILD)/compiler_rt_shim.o $(ALLEG_LIB) | $(BUILD)
	$(CC) -o $@ $(BUILD)/zig_main.o $(BUILD)/compiler_rt_shim.o $(LDLIBS)

$(BUILD)/compiler_rt_shim.o: src/compiler_rt_shim.c | $(BUILD)
	$(CC) -O2 -march=i386 -mtune=i586 -mno-sse -c -o $@ $<

# Zig -> C source. Target x86-freestanding so Zig emits no host-OS runtime
# calls; djgpp libc/CRT handles everything at link time. -lc tells Zig that
# libc symbols (malloc/free/...) will be resolved at link, which unlocks
# std.heap.c_allocator. djgpp's sys-include is fed to translate-c so that
# @cImport(allegro.h) can find <errno.h> etc. ALLEGRO_NO_ASM disables Allegro
# 4's GCC inline asm headers (al386gcc.h), which clang/translate-c rejects.
$(ZIG_C): $(ZIG_SRCS) $(ALLEG_PLATF) | $(BUILD)
	$(ZIG) build-obj -target x86-freestanding -ofmt=c -OReleaseSmall -lc \
	    -I$(ALLEG_INC) \
	    -isystem /usr/$(DJGPP_PREFIX)/sys-include \
	    -DALLEGRO_NO_ASM \
	    $(ZIG_SRC) -femit-bin=$@

# Compile emitted C with djgpp-gcc. Pre-include zig_shim.h to neutralise zig.h's
# bogus _Float16 selection on i386 -mno-sse.
$(BUILD)/zig_main.o: $(ZIG_C) $(ZIG_SHIM) | $(BUILD)
	$(CC) -O2 -march=i386 -mtune=i586 -mno-sse -fgnu89-inline \
	    -I$(ZIG_LIB_DIR) -include $(ZIG_SHIM) \
	    -Wno-builtin-declaration-mismatch \
	    -c -o $@ $(ZIG_C)

$(BUILD):
	mkdir -p $@

# --- vendored Allegro 4 source ---
$(ALLEG_TGZ): | $(VENDOR)
	curl -fsSL -o $@ $(ALLEG_URL)

$(ALLEG_SRC)/fix.sh: $(ALLEG_TGZ)
	tar -xzf $< -C $(VENDOR)
	# saved_ds is only read via inline asm; GCC 14 DCEs it. Mark it used.
	sed -i 's/^static unsigned short saved_ds = 0;$$/static unsigned short saved_ds __attribute__((used)) = 0;/' \
	    $(ALLEG_SRC)/src/misc/vbeafex.c
	touch $@

# --- toolchain shim (unprefixed gcc/g++/cc/cpp -> cross binaries) ---
$(SHIM_STAMP): | $(VENDOR)
	mkdir -p $(SHIM_DIR)
	for t in gcc g++ cc cpp; do \
	    target=$(DJGPP_PREFIX)-$$t; \
	    [ "$$t" = cc ] && target=$(DJGPP_PREFIX)-gcc; \
	    printf '#!/bin/sh\nexec /usr/bin/%s "$$@"\n' "$$target" > $(SHIM_DIR)/$$t; \
	    chmod +x $(SHIM_DIR)/$$t; \
	done
	touch $@

# --- cross-compiled Allegro 4 static lib ---
# GCC 14 promoted several legacy C diagnostics to errors; downgrade them so
# Allegro 4.2.3.1's pre-C99 sources still compile.
ALLEG_WFLAGS  := -Wall -Wno-unused -fgnu89-inline \
                 -Wno-error=int-conversion \
                 -Wno-error=incompatible-pointer-types \
                 -Wno-error=implicit-function-declaration \
                 -Wno-error=implicit-int \
                 -Wno-error=return-mismatch

# Configure Allegro for djgpp: rewrites alplatf.h (#define ALLEGRO_DJGPP) and
# generates the djgpp-specific autoconf-derived headers. Required before BOTH
# translating <allegro.h> for Zig (@cImport) AND building liballeg.a — without
# it, allegro.h falls through to the UNIX path and looks for alunixac.h.
$(ALLEG_PLATF): $(ALLEG_SRC)/fix.sh
	cd $(ALLEG_SRC) && sh fix.sh djgpp --quick
	@touch $@

$(ALLEG_LIB): $(ALLEG_PLATF) $(SHIM_STAMP)
	cd $(ALLEG_SRC) && PATH="$(abspath $(SHIM_DIR)):$(DJGPP_BIN):$$PATH" \
	    $(MAKE) lib CROSSCOMPILE=1 DJDIR=/usr/$(DJGPP_PREFIX) \
	    TARGET_ARCH_EXCL=i386 \
	    TARGET_OPTS='-O2 -funroll-loops -ffast-math -mtune=i586 -fomit-frame-pointer' \
	    WFLAGS='$(ALLEG_WFLAGS)' \
	    'MAKE_LIB=ar rs $$(LIB_NAME) $$(OBJECTS)'

# --- CWSDPMI extender stub ---
$(CWS_STUB): | $(CWS_DIR)
	curl -fsSL -o $@ $(CWS_URL)

$(CWS_DIR): | $(VENDOR)
	mkdir -p $@

$(VENDOR):
	mkdir -p $@

run: $(EXE)
	dosbox $(EXE)

clean:
	rm -rf $(BUILD) $(EXE) CWSDPMI.SWP

distclean: clean
	rm -rf $(VENDOR)
