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
# fx68k's Verilator-compatible variant, needed only by the CPU harness.
# Building it into every harness cost ~2 MB of objects each and, at -j 32,
# exhausted a 16 GB tmpfs through GCC's temporaries.
FX68K_SIM := $(wildcard third_party/fx68k/hdl/verilator/*.sv)

# -Wno-DECLFILENAME: a file holds a group of related modules, not one module
#   named after the file.
# -Wno-MULTITOP: for the same reason — kaneko_vuspr.sv holds both the parser
#   and its pixel-address helper, which nothing in that file instantiates.
#   Harness builds always pass an explicit --top-module, so this only relaxes
#   the standalone lint sweep.
VFLAGS    := -Wall -Wno-DECLFILENAME -Wno-MULTITOP
VBUILD    := --cc --exe --build -j 0 -O2 -Wno-fatal

# One entry per harness: <name>:<top module>:<harness source>
# <name>:<top module>:<harness source>[:<extra sources>]
HARNESSES := kaneko_tmap:kaneko_tmap_layer:sim/video/tb_kaneko_tmap.cpp \
             kaneko_vuspr:kaneko_vuspr:sim/video/tb_kaneko_vuspr.cpp \
             kaneko_tmap_fetch:kaneko_tmap_fetch:sim/video/tb_kaneko_tmap_fetch.cpp \
             kaneko_vuspr_draw:kaneko_vuspr_draw:sim/video/tb_kaneko_vuspr_draw.cpp \
             kaneko_sdram:kaneko_sdram_harness:sim/mem/tb_kaneko_sdram.cpp \
             kaneko_romload:kaneko_romload_harness:sim/io/tb_kaneko_romload.cpp \
             kaneko_romstream:kaneko_romstream_harness:sim/io/tb_kaneko_romstream.cpp \
             kaneko_cpu:kaneko_cpu_harness:sim/cpu/tb_kaneko_cpu.cpp:FX68K

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
# GCC writes temporaries to $TMPDIR, which defaults to /tmp — a 16 GB tmpfs
# here. Parallel Verilator builds of fx68k filled it and every harness failed
# with "Disk quota exceeded", which reads like a permissions or code fault.
export TMPDIR := $(CURDIR)/build/tmp
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
# TMPDIR is exported at the top of this file, so Quartus's temporaries land in
# build/tmp rather than on /tmp. That is not optional here: /tmp is a 16 GB
# tmpfs shared with other work, and quartus_map died with "ended unexpectedly.
# Verify that you have sufficient memory available" when it filled — a message
# that points at RAM when the problem was a full tmpfs.
quartus: lint test quartus-check
	@mkdir -p build/tmp build/quartus build/db build/incremental_db
	@# Quartus creates db/ and incremental_db/ in the project root and has no
	@# assignment that moves them, so they are symlinked into build/. Rule 10.
	@[ -L db ] || { rm -rf db; ln -s build/db db; }
	@[ -L incremental_db ] || { rm -rf incremental_db; ln -s build/incremental_db incremental_db; }
	@# The four tools are run individually with --write_settings_files=off.
	@# `quartus_sh --flow compile` REWRITES Kaneko16.qsf, which silently reset
	@# PROJECT_OUTPUT_DIRECTORY back to output_files and put every report in the
	@# project root again — a build that obeys rule 10 once and then stops.
	@set -e; for t in quartus_map quartus_fit quartus_asm; do \
	  echo "== $$t"; \
	  $(QUARTUS_BIN)/$$t --read_settings_files=on --write_settings_files=off \
	    Kaneko16 -c Kaneko16 > build/$$t.log 2>&1 || { tail -20 build/$$t.log; exit 1; }; \
	done
	@# quartus_sta takes neither settings flag — it is a different front end.
	@echo "== quartus_sta"
	@$(QUARTUS_BIN)/quartus_sta Kaneko16 -c Kaneko16 > build/quartus_sta.log 2>&1 \
	  || { tail -20 build/quartus_sta.log; exit 1; }
	@echo "quartus: build/quartus/Kaneko16.rbf"
	@grep -E "Logic utilization|Total block memory bits" build/quartus/Kaneko16.fit.summary || true


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
	@mkdir -p build/tmp
	@fail=0; \
	for h in $(HARNESSES); do \
	  name=$${h%%:*}; rest=$${h#*:}; top=$${rest%%:*}; rest2=$${rest#*:}; \
	  src=$${rest2%%:*}; extra=""; \
	  case "$$rest2" in *:FX68K) extra="$(FX68K_SIM)";; esac; \
	  $(VERILATOR) $(VBUILD) $(VFLAGS) --top-module $$top \
	    --Mdir build/obj_$$name -o $$name $(RTL) $(SIM_SV) $$extra $$src >/dev/null 2>&1 || { \
	      echo "BUILD FAILED: $$name"; \
	      $(VERILATOR) $(VBUILD) $(VFLAGS) --top-module $$top \
	        --Mdir build/obj_$$name -o $$name $(RTL) $(SIM_SV) $$extra $$src; fail=1; continue; }; \
	  ./build/obj_$$name/$$name || fail=1; \
	done; \
	if [ $$fail -ne 0 ]; then echo "TESTS FAILED"; exit 1; fi

# ------------------------------------------------------------------ boot
# 68000 against the REAL memory system. Kept out of `make test` because it
# needs assembled ROM regions, which are not in the repo — same reason `frame`
# is separate. This is the gate sim/cpu could not be: that harness acks every
# ROM fetch in the same cycle and feeds big-endian words straight from the
# file, so it tested neither the arbiter nor the byte order the HPS actually
# delivers.
.PHONY: boot
boot: regions
	@mkdir -p build/tmp
	@$(VERILATOR) $(VBUILD) $(VFLAGS) --top-module kaneko_cpumem_harness \
	  --Mdir build/obj_kaneko_cpumem -o kaneko_cpumem \
	  $(RTL) $(SIM_SV) $(FX68K_SIM) sim/top/tb_kaneko_cpumem.cpp >/dev/null 2>&1 || { \
	    $(VERILATOR) $(VBUILD) $(VFLAGS) --top-module kaneko_cpumem_harness \
	      --Mdir build/obj_kaneko_cpumem -o kaneko_cpumem \
	      $(RTL) $(SIM_SV) $(FX68K_SIM) sim/top/tb_kaneko_cpumem.cpp; \
	    echo "BUILD FAILED: kaneko_cpumem"; exit 1; }
	@[ -f $(ROM_DIR)/$(SET)_maincpu.bin ] || { \
	  echo "boot: $(SET) has no maincpu region."; \
	  echo "      Only explbrkr's 68000 program is described in"; \
	  echo "      tools/build_rom_regions.py — the other sets carry graphics and"; \
	  echo "      sound only, because the frame gate never needed their code."; \
	  echo "      kaneko_bus also decodes bakubrkr_map alone, so booting another"; \
	  echo "      title needs its memory map too, not just its ROM."; exit 1; }
	@./build/obj_kaneko_cpumem/kaneko_cpumem $(ROM_DIR)/$(SET)_maincpu.bin

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
	  --Mdir build/obj_frame -o frame $(RTL) $(SIM_SV) sim/video/tb_kaneko_frame.cpp \
	  >/dev/null 2>&1 || { echo "BUILD FAILED"; \
	  $(VERILATOR) $(VBUILD) $(VFLAGS) --top-module kaneko_frame_top \
	  --Mdir build/obj_frame -o frame $(RTL) $(SIM_SV) sim/video/tb_kaneko_frame.cpp; exit 1; }
	@./build/obj_frame/frame $(DUMP_DIR) $(ROM_DIR) $(SET)

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
	  --Mdir build/obj_frame -o frame $(RTL) $(SIM_SV) sim/video/tb_kaneko_frame.cpp \
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
	  out=$$(./build/obj_frame/frame $$d $(ROM_DIR) $$g 2>&1); \
	  diff=$$(echo "$$out" | grep -oE 'diff=[0-9]+' | cut -d= -f2); \
	  match=$$(echo "$$out" | grep -oE 'match=[0-9.]+%' | cut -d= -f2); \
	  printf '%-10s %8s %8s %9s\n' $$g $$f "$$diff" "$$match"; \
	done

# ------------------------------------------------------------------- MRA
# D6: the MRA owns the SDRAM layout and the loader maps it as the identity, so
# the MRA and SDRAM_MAP are two descriptions of one thing. `mra` generates both
# from the same table and then CHECKS they agree — a region misplaced by the MRA
# loads without error and shows up much later as a game booting to garbage.
.PHONY: mra
mra:
	@mkdir -p mra $(ROM_DIR)
	@tools/build_rom_regions.py $(SET) $(ROMPATH) $(ROM_DIR) --stream --mra
	@# The MRA is named after the GAME, because that filename is what the
	@# MiSTer arcade menu displays. Find it rather than assuming the set name.
	@f=$$(ls -t mra/*.mra | head -1); tools/verify_mra.py "$$f" $(ROMPATH) $(ROM_DIR)/$(SET)_stream.bin

# Hard rule 10: one directory holds everything generated, so a clean is
# complete and git status stays readable.
clean:
	rm -rf build obj_* output_files db incremental_db yosys.log abc.history
