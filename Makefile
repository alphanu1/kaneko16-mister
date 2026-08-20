# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
#   make lint     verilator --lint-only over all RTL
#   make test     build and run every simulation harness
#   make area     yosys area estimate for a module (MOD=kaneko_tmap_layer)
#   make clean
#
# Hard rule 4: `make lint && make test` must pass, with zero fails and zero
# uncovered_*, before any Quartus build is started or hardware is programmed.

VERILATOR ?= verilator
YOSYS     ?= yosys

# ------------------------------------------------------------------ quartus
# Hard rule 7: 17.0 only. Pinned by absolute path rather than taken from PATH,
# because 24.1std is also installed on this machine and it does NOT fail on a
# Cyclone V — it ships cyclonev device data and will build a subtly different
# core against different IP. Nothing downstream catches that, so the guard has
# to be here.
QUARTUS_ROOT ?= /home/ben/intelFPGA_lite/17.0/quartus
QUARTUS_BIN  := $(QUARTUS_ROOT)/bin
QUARTUS_WANT := 17.0

RTL_DIRS  := rtl/video rtl/cpu rtl/sound rtl/mem rtl/io rtl/pll
RTL       := $(wildcard $(patsubst %,%/*.sv,$(RTL_DIRS)))
# Simulation-only SystemVerilog (harness wrappers). Compiled into harnesses but
# never linted as core RTL and never instantiated from rtl/.
SIM_SV    := $(wildcard sim/*/*.sv)

# -Wno-DECLFILENAME: a file holds a group of related modules, not one module
#   named after the file.
# -Wno-MULTITOP: for the same reason — kaneko_vuspr.sv holds both the parser
#   and its pixel-address helper, which nothing in that file instantiates.
#   Harness builds always pass an explicit --top-module, so this only relaxes
#   the standalone lint sweep.
VFLAGS    := -Wall -Wno-DECLFILENAME -Wno-MULTITOP
VBUILD    := --cc --exe --build -j 0 -O2 -Wno-fatal

# One entry per harness: <name>:<top module>:<harness source>
HARNESSES := kaneko_tmap:kaneko_tmap_layer:sim/video/tb_kaneko_tmap.cpp \
             kaneko_vuspr:kaneko_vuspr:sim/video/tb_kaneko_vuspr.cpp \
             kaneko_tmap_fetch:kaneko_tmap_fetch:sim/video/tb_kaneko_tmap_fetch.cpp \
             kaneko_vuspr_draw:kaneko_vuspr_draw:sim/video/tb_kaneko_vuspr_draw.cpp \
             kaneko_sdram:kaneko_sdram_harness:sim/mem/tb_kaneko_sdram.cpp

# The frame gate is separate from `make test`: it needs a MAME dump and
# assembled ROM regions, neither of which is in the repo. `make frame` builds
# both prerequisites if they are missing.
DUMP_DIR ?= build/m0dump
ROM_DIR  ?= build/roms
ROMPATH  ?= /home/ben/roms/Kaneko16
SET      ?= mgcrystl
DUMP_FRAME ?= 600
DUMP_AT    ?= vblank

.PHONY: all lint test clean area quartus quartus-check
all: lint test

# --------------------------------------------------------------- quartus 17
# Refuses to proceed on any version but 17.0, and refuses to fall back to
# whatever is on PATH.
quartus-check:
	@if [ ! -x "$(QUARTUS_BIN)/quartus_map" ]; then \
	  echo "quartus: $(QUARTUS_BIN)/quartus_map not found."; \
	  echo "         Set QUARTUS_ROOT to a 17.0 install. Hard rule 7."; exit 1; fi
	@v=$$("$(QUARTUS_BIN)/quartus_map" --version 2>/dev/null | \
	      grep -oE 'Version [0-9]+\.[0-9]+' | head -1 | cut -d' ' -f2); \
	if [ "$$v" != "$(QUARTUS_WANT)" ]; then \
	  echo "quartus: REFUSING TO BUILD — found $$v, hard rule 7 requires $(QUARTUS_WANT)."; \
	  echo "         24.1std accepts Cyclone V and will produce a working-looking"; \
	  echo "         bitstream built against different IP. That is the failure this"; \
	  echo "         guard exists to prevent. Do not raise QUARTUS_WANT to pass."; \
	  exit 1; fi; \
	echo "quartus: $$v ok ($(QUARTUS_BIN))"

# Hard rule 4: the simulation gate runs before any synthesis.
quartus: lint test quartus-check
	@echo "quartus: no project yet — nothing to build."
	@echo "         When one exists, build it with $(QUARTUS_BIN)/quartus_sh."


# ------------------------------------------------------------------- lint
lint:
	@$(VERILATOR) --lint-only $(VFLAGS) $(RTL) >/dev/null 2>&1 || { \
	  $(VERILATOR) --lint-only $(VFLAGS) $(RTL); echo "LINT FAILED"; exit 1; }
	@echo "lint: $(words $(RTL)) file(s) clean"
# Linted as one set rather than file by file. Modules now span files —
# kaneko_tmap_fetch instantiates the address blocks that live in
# kaneko_tmap.sv — and a per-file lint cannot resolve those. Verilator still
# checks every module it parses, so nothing is lost.

# ------------------------------------------------------------------- test
# Each harness builds into its own obj_<name>/ tree, which .gitignore covers
# with /obj_*/ rather than a per-name list — a narrower pattern stops covering
# new harnesses the moment one is named differently.
test:
	@fail=0; \
	for h in $(HARNESSES); do \
	  name=$${h%%:*}; rest=$${h#*:}; top=$${rest%%:*}; src=$${rest#*:}; \
	  $(VERILATOR) $(VBUILD) $(VFLAGS) --top-module $$top \
	    --Mdir obj_$$name -o $$name $(RTL) $(SIM_SV) $$src >/dev/null 2>&1 || { \
	      echo "BUILD FAILED: $$name"; \
	      $(VERILATOR) $(VBUILD) $(VFLAGS) --top-module $$top \
	        --Mdir obj_$$name -o $$name $(RTL) $(SIM_SV) $$src; fail=1; continue; }; \
	  ./obj_$$name/$$name || fail=1; \
	done; \
	if [ $$fail -ne 0 ]; then echo "TESTS FAILED"; exit 1; fi

# ------------------------------------------------------------------- area
MOD ?= kaneko_tmap_fetch
area:
	@$(YOSYS) -p "read_verilog -sv $(RTL); synth -top $(MOD); stat" 2>&1 | \
	  awk '/=== design hierarchy ===/,0' | head -40

# ---------------------------------------------------------------- M0 gate
.PHONY: frame dump regions
regions:
	@mkdir -p $(ROM_DIR)
	@tools/build_rom_regions.py $(SET) $(ROMPATH) $(ROM_DIR)

# The dump MUST start from a clean directory. MAME writes nvram/ and cfg/
# wherever it runs, mgcrystl has a 93C46 EEPROM, and a second run boots from
# the first run's saved state — landing at a different point in the attract
# loop and silently changing the reference frame. Two identical `make frame`
# runs disagreed by 642 vs 256 pixels before this was cleared.
dump:
	@rm -rf $(DUMP_DIR)
	@mkdir -p $(DUMP_DIR)
	@cd $(DUMP_DIR) && DUMP_DIR=$(CURDIR)/$(DUMP_DIR) DUMP_FRAME=$(DUMP_FRAME) DUMP_SET=$(SET) DUMP_AT=$(DUMP_AT) \
	  mame -rompath $(ROMPATH) $(SET) \
	    -autoboot_script $(CURDIR)/tools/mame_dump_frame.lua \
	    -skip_gameinfo -autoboot_delay 0 -video none -sound none \
	    -nothrottle -seconds_to_run 20 >/dev/null 2>&1 || true
	@test -f $(DUMP_DIR)/frame.raw || { echo "dump failed: no frame.raw"; exit 1; }
	@echo "dump: $(DUMP_DIR) ok"

frame: regions dump
	@$(VERILATOR) $(VBUILD) $(VFLAGS) --top-module kaneko_frame_top \
	  --Mdir obj_frame -o frame $(RTL) $(SIM_SV) sim/video/tb_kaneko_frame.cpp \
	  >/dev/null 2>&1 || { echo "BUILD FAILED"; \
	  $(VERILATOR) $(VBUILD) $(VFLAGS) --top-module kaneko_frame_top \
	  --Mdir obj_frame -o frame $(RTL) $(SIM_SV) sim/video/tb_kaneko_frame.cpp; exit 1; }
	@./obj_frame/frame $(DUMP_DIR) $(ROM_DIR) $(SET)

# ------------------------------------------------------------ multi-game gate
# Hard rule 9: a change to shared video code must be checked against every
# configured game, not just the one being worked on. Games differ in chip
# count, sprite list size, priorities, offsets, ROM layout and geometry, and a
# constant tuned until one game matches will silently break another.
#
# GATE_GAMES entries are <set>:<frame>.
GATE_GAMES ?= mgcrystl:600 explbrkr:900 blazeonj:600 wingforc:600

# MAME looks up a set by name, but blazeon.zip holds the blazeonj set. Alias it
# here rather than renaming anything in the user's ROM folder.
ROM_ALIAS := build/roms_alias
$(ROM_ALIAS)/blazeonj.zip:
	@mkdir -p $(ROM_ALIAS)
	@ln -sf $(ROMPATH)/blazeon.zip $(ROM_ALIAS)/blazeonj.zip

.PHONY: gate
gate: $(ROM_ALIAS)/blazeonj.zip
	@$(VERILATOR) $(VBUILD) $(VFLAGS) --top-module kaneko_frame_top \
	  --Mdir obj_frame -o frame $(RTL) $(SIM_SV) sim/video/tb_kaneko_frame.cpp \
	  >/dev/null 2>&1 || { echo "BUILD FAILED"; exit 1; }
	@printf '%-10s %8s %8s %9s   %s\n' GAME FRAME DIFF MATCH NOTE
	@for gf in $(GATE_GAMES); do \
	  g=$${gf%%:*}; f=$${gf#*:}; d=build/gate_$$g; \
	  mkdir -p $(ROM_DIR); \
	  tools/build_rom_regions.py $$g $(ROMPATH) $(ROM_DIR) >/dev/null 2>&1 || \
	    { printf '%-10s %8s %8s %9s   %s\n' $$g $$f - - "ROM BUILD FAILED"; continue; }; \
	  rm -rf $$d; mkdir -p $$d; \
	  ( cd $$d && DUMP_DIR=$(CURDIR)/$$d DUMP_FRAME=$$f DUMP_SET=$$g DUMP_AT=$(DUMP_AT) \
	    mame -rompath "$(ROMPATH);$(CURDIR)/$(ROM_ALIAS)" $$g \
	      -autoboot_script $(CURDIR)/tools/mame_dump_frame.lua \
	      -skip_gameinfo -autoboot_delay 0 -video none -sound none \
	      -nothrottle -seconds_to_run 30 >/dev/null 2>&1 ) || true; \
	  if [ ! -f $$d/frame.raw ]; then \
	    printf '%-10s %8s %8s %9s   %s\n' $$g $$f - - "DUMP FAILED"; continue; fi; \
	  out=$$(./obj_frame/frame $$d $(ROM_DIR) $$g 2>&1); \
	  diff=$$(echo "$$out" | grep -oE 'diff=[0-9]+' | cut -d= -f2); \
	  match=$$(echo "$$out" | grep -oE 'match=[0-9.]+%' | cut -d= -f2); \
	  printf '%-10s %8s %8s %9s\n' $$g $$f "$$diff" "$$match"; \
	done

clean:
	rm -rf obj_* yosys.log abc.history
