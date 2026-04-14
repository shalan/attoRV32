# Makefile — AttoRV32 firmware build
#
# Configure to match your Verilog parameters:
#   ADDR_WIDTH : 8..12  (RAM size = 2^ADDR_WIDTH bytes)
#   RV32E      : 0 | 1  (must match core parameter)
#   HAVE_M     : 0 | 1  (must match `NRV_M` define in the core)
#
# Usage:
#   make ADDR_WIDTH=10 RV32E=1 HAVE_M=0
#   make clean
#
# Outputs:
#   firmware.elf  .hex  .bin  .lst

CROSS   ?= riscv32-unknown-elf-
CC       = $(CROSS)gcc
OBJCOPY  = $(CROSS)objcopy
OBJDUMP  = $(CROSS)objdump
SIZE     = $(CROSS)size

# ---- Config ---------------------------------------------------------------
ADDR_WIDTH ?= 12
RV32E      ?= 0
HAVE_M     ?= 0

# Sanity check on ADDR_WIDTH
ifeq ($(shell test $(ADDR_WIDTH) -ge 8 -a $(ADDR_WIDTH) -le 12 && echo ok),)
$(error ADDR_WIDTH must be in 8..12 (got $(ADDR_WIDTH)))
endif

RAM_SIZE := $(shell echo $$((1 << $(ADDR_WIDTH))))

# Derive -march / -mabi
ifeq ($(RV32E),1)
  ABI  := ilp32e
  ifeq ($(HAVE_M),1)
    ARCH := rv32emc_zicsr
  else
    ARCH := rv32ec_zicsr
  endif
else
  ABI  := ilp32
  ifeq ($(HAVE_M),1)
    ARCH := rv32imc_zicsr
  else
    ARCH := rv32ic_zicsr
  endif
endif

# ---- Flags ----------------------------------------------------------------
# -mcmodel=medlow : use lui+addi, no AUIPC for globals
# -fno-pic        : avoid position-independent codegen (no AUIPC pairs)
# -Wl,--no-relax  : keep call sequences fixed so linker doesn't invent AUIPC
# -Os             : optimize for size
# -ffreestanding  : no hosted assumptions
# -nostartfiles   : we provide crt0
CFLAGS  = -march=$(ARCH) -mabi=$(ABI) -mcmodel=medlow -fno-pic \
          -Os -ffreestanding -nostdlib -nostartfiles \
          -fno-builtin -Wall -Wextra \
          -fdata-sections -ffunction-sections

LDFLAGS = -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
          -Wl,--no-relax -Wl,--gc-sections -T link.ld

ASFLAGS = $(CFLAGS)

# ---- Sources --------------------------------------------------------------
# Build with SELFTEST=1 to link selftest.c instead of main.c. Selftest also
# receives HAVE_M (for compile-time gating of M-extension tests).
# BENCH_COMPUTE=1 or BENCH_SORT=1 builds the corresponding benchmark.
SELFTEST      ?= 0
BENCH_COMPUTE ?= 0
BENCH_SORT    ?= 0

ifeq ($(BENCH_COMPUTE),1)
  SRCS_C := bench_compute.c isr.c
  TARGET := bench_compute
else ifeq ($(BENCH_SORT),1)
  SRCS_C := bench_sort.c isr.c
  TARGET := bench_sort
else ifeq ($(SELFTEST),1)
  SRCS_C := selftest.c isr.c
  TARGET := selftest
  CFLAGS += -DHAVE_IRQ
  ifeq ($(HAVE_M),1)
    CFLAGS += -DHAVE_M
  endif
else
  SRCS_C := main.c isr.c
  TARGET := firmware
endif

SRCS_S := crt0.S
OBJS   := $(SRCS_C:.c=.o) $(SRCS_S:.S=.o)

# ---- Build rules ----------------------------------------------------------
.PHONY: all clean info

all: $(TARGET).hex $(TARGET).bin $(TARGET).lst check-nosra info

info:
	@echo "=== Build config ==="
	@echo "ADDR_WIDTH : $(ADDR_WIDTH)  (RAM = $(RAM_SIZE) bytes)"
	@echo "RV32E      : $(RV32E)"
	@echo "HAVE_M     : $(HAVE_M)"
	@echo "ARCH / ABI : $(ARCH) / $(ABI)"
	@echo
	@$(SIZE) $(TARGET).elf

link.ld: link.ld.in Makefile
	@sed 's/@RAM_SIZE@/$(RAM_SIZE)/g' $< > $@

$(TARGET).elf: $(OBJS) link.ld
	$(CC) $(LDFLAGS) $(OBJS) -o $@

$(TARGET).hex: $(TARGET).elf
	$(OBJCOPY) -O verilog $< $@

$(TARGET).bin: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@

$(TARGET).lst: $(TARGET).elf
	$(OBJDUMP) -d -S --source-comment $< > $@

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

%.o: %.S
	$(CC) $(ASFLAGS) -c $< -o $@

clean:
	rm -f *.o firmware.elf firmware.hex firmware.bin firmware.lst \
	      selftest.elf selftest.hex selftest.bin selftest.lst \
	      bench_compute.elf bench_compute.hex bench_compute.bin bench_compute.lst \
	      bench_sort.elf bench_sort.hex bench_sort.bin bench_sort.lst link.ld

# ---- Sanity check: no AUIPC in output (optional)  -------------------------
check-noauipc: $(TARGET).lst
	@if grep -q auipc $(TARGET).lst; then \
	   echo "WARNING: auipc found in firmware — check -mcmodel / -fno-pic"; \
	   grep auipc $(TARGET).lst | head; \
	else \
	   echo "OK: no auipc in firmware"; \
	fi

# ---- Sanity check: no SRA/SRAI when hardware omits them -------------------
# Fails the build if GCC emitted an arithmetic right shift. The core without
# NRV_SRA would silently execute SRA as SRL — this check prevents that.
check-nosra: $(TARGET).lst
	@if grep -Eq '\b(sra|srai)\b' $(TARGET).lst; then \
	   echo "ERROR: SRA/SRAI found in firmware (hardware does not support it)"; \
	   echo "Offending lines:"; \
	   grep -En '\b(sra|srai)\b' $(TARGET).lst | head; \
	   echo "Fix: use unsigned types for all right-shifts, or define NRV_SRA."; \
	   exit 1; \
	else \
	   echo "OK: no SRA/SRAI in firmware"; \
	fi
