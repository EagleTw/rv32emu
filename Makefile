include mk/common.mk
include mk/color.mk
include mk/toolchain.mk

OUT ?= build
BIN := $(OUT)/rv32emu

CONFIG_FILE := $(OUT)/.config
-include $(CONFIG_FILE)

CFLAGS = -std=gnu99 -O2 -Wall -Wextra
CFLAGS += -Wno-unused-label
CFLAGS += -include src/common.h
CFLAGS_emcc ?=

# Enable link-time optimization (LTO)
ENABLE_LTO ?= 1
ifeq ($(call has, LTO), 1)
ifeq ("$(CC_IS_CLANG)$(CC_IS_GCC)$(CC_IS_EMCC)", "")
$(warning LTO is only supported in clang, gcc and emcc.)
override ENABLE_LTO := 0
endif
endif
$(call set-feature, LTO)
ifeq ($(call has, LTO), 1)
ifeq ("$(CC_IS_EMCC)", "1")
ifeq ($(call has, SDL), 1)
$(warning LTO is not supported to build emscripten-port SDL using emcc.)
else
CFLAGS += -flto
endif
endif
ifeq ("$(CC_IS_GCC)", "1")
CFLAGS += -flto
endif
ifeq ("$(CC_IS_CLANG)", "1")
CFLAGS += -flto=thin -fsplit-lto-unit
LDFLAGS += -flto=thin
endif
endif

# Disable Intel's Control-flow Enforcement Technology (CET)
CFLAGS += $(CFLAGS_NO_CET)

OBJS_EXT :=

# Integer Multiplication and Division instructions
ENABLE_EXT_M ?= 1
$(call set-feature, EXT_M)

# Atomic Instructions
ENABLE_EXT_A ?= 1
$(call set-feature, EXT_A)

# Single-precision floating point instructions
ENABLE_EXT_F ?= 1
$(call set-feature, EXT_F)
ifeq ($(call has, EXT_F), 1)
AR := ar
ifeq ("$(CC_IS_EMCC)", "1")
AR = emar
endif
SOFTFLOAT_OUT = $(abspath $(OUT)/softfloat)
src/softfloat/build/Linux-RISCV-GCC/Makefile:
	git submodule update --init src/softfloat/
SOFTFLOAT_LIB := $(SOFTFLOAT_OUT)/softfloat.a
$(SOFTFLOAT_LIB): src/softfloat/build/Linux-RISCV-GCC/Makefile
	$(MAKE) -C $(dir $<) BUILD_DIR=$(SOFTFLOAT_OUT) CC=$(CC) AR=$(AR)
$(OUT)/decode.o $(OUT)/riscv.o: $(SOFTFLOAT_LIB)
LDFLAGS += $(SOFTFLOAT_LIB)
LDFLAGS += -lm
endif

# Compressed extension instructions
ENABLE_EXT_C ?= 1
$(call set-feature, EXT_C)

# Control and Status Register (CSR)
ENABLE_Zicsr ?= 1
$(call set-feature, Zicsr)

# Instruction-Fetch Fence
ENABLE_Zifencei ?= 1
$(call set-feature, Zifencei)

# Experimental SDL oriented system calls
ENABLE_SDL ?= 1
ifneq ("$(CC_IS_EMCC)", "1") # note that emcc generates port SDL headers/library, so it does not requires system SDL headers/library
ifeq ($(call has, SDL), 1)
ifeq (, $(shell which sdl2-config))
$(warning No sdl2-config in $$PATH. Check SDL2 installation in advance)
override ENABLE_SDL := 0
endif
ifeq (1, $(shell pkg-config --exists SDL2_mixer; echo $$?))
$(warning No SDL2_mixer lib installed. Check SDL2_mixer installation in advance)
override ENABLE_SDL := 0
endif
endif
$(call set-feature, SDL)
ifeq ($(call has, SDL), 1)
OBJS_EXT += syscall_sdl.o
$(OUT)/syscall_sdl.o: CFLAGS += $(shell sdl2-config --cflags)
LDFLAGS += $(shell sdl2-config --libs) -pthread
LDFLAGS += $(shell pkg-config --libs SDL2_mixer)
endif
endif

ENABLE_GDBSTUB ?= 0
$(call set-feature, GDBSTUB)
ifeq ($(call has, GDBSTUB), 1)
GDBSTUB_OUT = $(abspath $(OUT)/mini-gdbstub)
GDBSTUB_COMM = 127.0.0.1:1234
src/mini-gdbstub/Makefile:
	git submodule update --init $(dir $@)
GDBSTUB_LIB := $(GDBSTUB_OUT)/libgdbstub.a
$(GDBSTUB_LIB): src/mini-gdbstub/Makefile
	$(MAKE) -C $(dir $<) O=$(dir $@)
# FIXME: track gdbstub dependency properly
$(OUT)/decode.o: $(GDBSTUB_LIB)
OBJS_EXT += gdbstub.o breakpoint.o
CFLAGS += -D'GDBSTUB_COMM="$(GDBSTUB_COMM)"'
LDFLAGS += $(GDBSTUB_LIB) -pthread
gdbstub-test: $(BIN)
	$(Q).ci/gdbstub-test.sh && $(call notice, [OK])
endif

ENABLE_JIT ?= 0
$(call set-feature, JIT)
ifeq ($(call has, JIT), 1)
OBJS_EXT += jit.o
ifneq ($(processor),$(filter $(processor),x86_64 aarch64 arm64))
$(error JIT mode only supports for x64 and arm64 target currently.)
endif

src/rv32_jit.c:
	$(Q)tools/gen-jit-template.py $(CFLAGS) > $@

$(OUT)/jit.o: src/jit.c src/rv32_jit.c
	$(VECHO) "  CC\t$@\n"
	$(Q)$(CC) -o $@ $(CFLAGS) -c -MMD -MF $@.d $<
endif
# For tail-call elimination, we need a specific set of build flags applied.
# FIXME: On macOS + Apple Silicon, -fno-stack-protector might have a negative impact.

# Enable tail-call for emcc
ifeq ("$(CC_IS_EMCC)", "1")
CFLAGS += -mtail-call
endif

# Build emscripten-port SDL
ifeq ("$(CC_IS_EMCC)", "1")
ifeq ($(call has, SDL), 1)
CFLAGS_emcc += -sUSE_SDL=2 -sSDL2_MIXER_FORMATS=wav,mid -sUSE_SDL_MIXER=2
OBJS_EXT += syscall_sdl.o
LDFLAGS += -pthread
endif
endif

ENABLE_UBSAN ?= 0
ifeq ("$(ENABLE_UBSAN)", "1")
CFLAGS += -fsanitize=undefined -fno-sanitize=alignment -fno-sanitize-recover=all
LDFLAGS += -fsanitize=undefined -fno-sanitize=alignment -fno-sanitize-recover=all
endif

$(OUT)/emulate.o: CFLAGS += -foptimize-sibling-calls -fomit-frame-pointer -fno-stack-check -fno-stack-protector

# Clear the .DEFAULT_GOAL special variable, so that the following turns
# to the first target after .DEFAULT_GOAL is not set.
.DEFAULT_GOAL :=

WEB_FILES := $(BIN).js \
	     $(BIN).wasm \
	     $(BIN).worker.js
ifeq ("$(CC_IS_EMCC)", "1")
BIN := $(BIN).js
endif

all: config $(BIN)

OBJS := \
	map.o \
	utils.o \
	decode.o \
	io.o \
	syscall.o \
	emulate.o \
	riscv.o \
	elf.o \
	cache.o \
	mpool.o \
	$(OBJS_EXT) \
	main.o

OBJS := $(addprefix $(OUT)/, $(OBJS))
deps := $(OBJS:%.o=%.o.d)

include mk/external.mk

deps_emcc :=
ASSETS := assets
WEB_JS_RESOURCES := $(ASSETS)/js
EXPORTED_FUNCS := _main,_indirect_rv_halt
ifeq ("$(CC_IS_EMCC)", "1")
CFLAGS_emcc += -sINITIAL_MEMORY=2GB \
	       -sALLOW_MEMORY_GROWTH \
	       -s"EXPORTED_FUNCTIONS=$(EXPORTED_FUNCS)" \
	       -sSTACK_SIZE=4MB \
	       -sPTHREAD_POOL_SIZE=navigator.hardwareConcurrency \
	       --embed-file build@/ \
	       --embed-file build/timidity@/etc/timidity \
	       -DMEM_SIZE=0x40000000 \
	       -DCYCLE_PER_STEP=2000000 \
	       --pre-js $(WEB_JS_RESOURCES)/pre.js \
	       -O3 \
	       -w

# used to download all dependencies of elf executable and bundle into single wasm
deps_emcc += $(DOOM_DATA) $(QUAKE_DATA) $(TIMIDITY_DATA)

# check browser MAJOR version if supports TCO
CHROME_MAJOR :=
CHROME_MAJOR_VERSION_CHECK_CMD :=
CHROME_SUPPORT_TCO_AT_MAJOR := 112
CHROME_SUPPORT_TCO_INFO := Chrome supports TCO, you can use Chrome to request the wasm
CHROME_NO_SUPPORT_TCO_WARNING := Chrome not found or Chrome must have at least version $(CHROME_SUPPORT_TCO_AT_MAJOR) in MAJOR to serve wasm

FIREFOX_MAJOR :=
FIREFOX_MAJOR_VERSION_CHECK_CMD :=
FIREFOX_SUPPORT_TCO_AT_MAJOR := 121
FIREFOX_SUPPORT_TCO_INFO := Firefox supports TCO, you can use Firefox to request the wasm
FIREFOX_NO_SUPPORT_TCO_WARNING := Firefox not found or Firefox must have at least version $(FIREFOX_SUPPORT_TCO_AT_MAJOR) in MAJOR to serve wasm

# FIXME: for Windows
ifeq ($(UNAME_S),Darwin)
    CHROME_MAJOR_VERSION_CHECK_CMD := "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --version | awk '{print $$3}' | cut -f1 -d.
    FIREFOX_MAJOR_VERSION_CHECK_CMD := /Applications/Firefox.app/Contents/MacOS/firefox --version | awk '{print $$3}' | cut -f1 -d.
else ifeq ($(UNAME_S),Linux)
    CHROME_MAJOR_VERSION_CHECK_CMD := google-chrome --version | awk '{print $$3}' | cut -f1 -d.
    FIREFOX_MAJOR_VERSION_CHECK_CMD := firefox -v | awk '{print $$3}' | cut -f1 -d.
endif
CHROME_MAJOR := $(shell $(CHROME_MAJOR_VERSION_CHECK_CMD))
FIREFOX_MAJOR := $(shell $(FIREFOX_MAJOR_VERSION_CHECK_CMD))

# Chrome
ifeq ($(shell echo $(CHROME_MAJOR)\>=$(CHROME_SUPPORT_TCO_AT_MAJOR) | bc), 1)
    $(info $(shell echo "$(GREEN)$(CHROME_SUPPORT_TCO_INFO)$(NC)"))
else
    $(warning $(shell echo "$(YELLOW)$(CHROME_NO_SUPPORT_TCO_WARNING)$(NC)"))
endif

# Firefox
ifeq ($(shell echo $(FIREFOX_MAJOR)\>=$(FIREFOX_SUPPORT_TCO_AT_MAJOR) | bc), 1)
    $(info $(shell echo "$(GREEN)$(FIREFOX_SUPPORT_TCO_INFO)$(NC)"))
else
    $(warning $(shell echo "$(YELLOW)$(FIREFOX_NO_SUPPORT_TCO_WARNING)$(NC)"))
endif

# used to serve wasm locally
DEMO_DIR := demo
DEMO_IP := 127.0.0.1
DEMO_PORT := 8000

# check if demo root directory exists and create it if not
check-demo-dir-exist:
	$(Q)if [ ! -d "$(DEMO_DIR)" ]; then \
		mkdir -p "$(DEMO_DIR)"; \
	fi

# FIXME: without $(info) generates errors
define cp-web-file
    $(Q)cp $(1) $(DEMO_DIR)
    $(info)
endef

# WEB_FILES could be cleaned and recompiled, thus do not mix these two files into WEB_FILES
STATIC_WEB_FILES := assets/html/index.html assets/js/coi-serviceworker.min.js

serve-wasm: $(BIN) check-demo-dir-exist
	$(foreach T, $(WEB_FILES), $(call cp-web-file, $(T)))
	$(foreach T, $(STATIC_WEB_FILES), $(call cp-web-file, $(T)))
	$(Q)python3 -m http.server --bind $(DEMO_IP) $(DEMO_PORT) --directory $(DEMO_DIR)
endif

$(OUT)/%.o: src/%.c $(deps_emcc)
	$(VECHO) "  CC\t$@\n"
	$(Q)$(CC) -o $@ $(CFLAGS) $(CFLAGS_emcc) -c -MMD -MF $@.d $<

$(BIN): $(OBJS)
	$(VECHO) "  LD\t$@\n"
	$(Q)$(CC) -o $@ $(CFLAGS_emcc) $^ $(LDFLAGS)

config: $(CONFIG_FILE)
$(CONFIG_FILE):
	$(Q)echo "$(CFLAGS)" | xargs -n1 | sort | sed -n 's/^RV32_FEATURE/ENABLE/p' > $@
	$(VECHO) "Check the file $(OUT)/.config for configured items.\n"

# Tools
include mk/tools.mk
tool: $(TOOLS_BIN)

# RISC-V Architecture Tests
include mk/riscv-arch-test.mk
include mk/tests.mk

CHECK_ELF_FILES := \
	hello \
	puzzle \
	fcalc

ifeq ($(call has, EXT_M), 1)
CHECK_ELF_FILES += \
	pi
endif

EXPECTED_hello = Hello World!
EXPECTED_puzzle = success in 2005 trials
EXPECTED_fcalc = Performed 12 tests, 0 failures, 100% success rate.
EXPECTED_pi = 3.141592653589793238462643383279502884197169399375105820974944592307816406286208998628034825342117067982148086

check: $(BIN)
	$(Q)$(foreach e,$(CHECK_ELF_FILES),\
	    $(PRINTF) "Running $(e).elf ... "; \
	    if [ "$(shell $(BIN) $(OUT)/$(e).elf | uniq)" = "$(strip $(EXPECTED_$(e))) inferior exit code 0" ]; then \
	    $(call notice, [OK]); \
	    else \
	    $(PRINTF) "Failed.\n"; \
	    exit 1; \
	    fi; \
	)

EXPECTED_aes_sha1 = 1242a6757c8aef23e50b5264f5941a2f4b4a347e  -
misalign: $(BIN)
	$(Q)$(PRINTF) "Running aes.elf ... ";
	$(Q)if [ "$(shell $(BIN) -m $(OUT)/aes.elf | $(SHA1SUM))" = "$(EXPECTED_aes_sha1)" ]; then \
	    $(call notice, [OK]); \
	    else \
	    $(PRINTF) "Failed.\n"; \
	    fi

# Non-trivial demonstration programs
ifeq ($(call has, SDL), 1)
doom_action := (cd $(OUT); ../$(BIN) doom.elf)
ifeq ("$(CC_IS_EMCC)", "1")
# TODO: check Chrome or Firefox is available and serve python httpd and open the web page
# TODO: serve and open a web page, show warning if environment not support pthread runtime
doom_action :=
endif
doom_deps += $(DOOM_DATA) $(BIN)
doom: $(doom_deps)
	$(doom_action)

ifeq ($(call has, EXT_F), 1)
quake_action := (cd $(OUT); ../$(BIN) quake.elf)
ifeq ("$(CC_IS_EMCC)", "1")
# TODO: check Chrome or Firefox is available and serve python httpd and open the web page
# TODO: serve and open a web page, show warning if environment not support pthread runtime
quake_action :=
endif
quake_deps += $(QUAKE_DATA) $(BIN)
quake: $(quake_deps)
	$(quake_action)
endif
endif

clean:
	$(RM) $(BIN) $(OBJS) $(HIST_BIN) $(HIST_OBJS) $(deps) $(WEB_FILES) $(CACHE_OUT) src/rv32_jit.c
distclean: clean
	-$(RM) $(DOOM_DATA) $(QUAKE_DATA)
	$(RM) -r $(TIMIDITY_DATA)
	$(RM) -r $(OUT)/id1
	$(RM) -r $(DEMO_DIR)
	$(RM) *.zip
	$(RM) -r $(OUT)/mini-gdbstub
	-$(RM) $(OUT)/.config
	-$(RM) -r $(OUT)/softfloat

-include $(deps)
