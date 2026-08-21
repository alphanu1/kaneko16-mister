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
# jt6295 and its dependencies, needed only by the OKI harness. Listed rather
# than wildcarded: the directory also holds jt6295_up4*.hex and a .m script.
JT51_SIM := $(wildcard third_party/jt51/hdl/*.v)
JT6295_SIM := third_party/jt6295/hdl/jt6295.v third_party/jt6295/hdl/jt6295_acc.v \
              third_party/jt6295/hdl/jt6295_adpcm.v third_party/jt6295/hdl/jt6295_ctrl.v \
              third_party/jt6295/hdl/jt6295_rom.v third_party/jt6295/hdl/jt6295_serial.v \
              third_party/jt6295/hdl/jt6295_sh_rst.v third_party/jt6295/hdl/jt6295_timing.v \
              third_party/jt6295/hdl/jt12_comb.v third_party/jt6295/hdl/jt12_interpol.v
JT49_SIM  := third_party/jt49/hdl/jt49.v third_party/jt49/hdl/jt49_cen.v \
             third_party/jt49/hdl/jt49_div.v third_party/jt49/hdl/jt49_eg.v \
             third_party/jt49/hdl/jt49_exp.v third_party/jt49/hdl/jt49_noise.v

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
             kaneko_irq:kaneko_irq:sim/cpu/tb_kaneko_irq.cpp \
             kaneko_eeprom:kaneko_eeprom93c46:sim/io/tb_kaneko_eeprom.cpp \
             kaneko_regs16:kaneko_regs16:sim/video/tb_kaneko_regs16.cpp \
             kaneko_tilerom:kaneko_tilerom_harness:sim/video/tb_kaneko_tilerom.cpp \
             kaneko_tmap_line:kaneko_tmap_line:sim/video/tb_kaneko_tmap_line.cpp \
             kaneko_spr_sys:kaneko_spr_sys_harness:sim/video/tb_kaneko_spr_sys.cpp \
             kaneko_z80snd:kaneko_z80snd:sim/sound/tb_kaneko_z80snd.cpp \
             kaneko_oki:kaneko_oki_harness:sim/sound/tb_kaneko_oki.cpp:JT6295 \
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
all: lint nports-check test

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
# EVERY RTL FILE MUST BE IN THE PROJECT
#
# The .qsf lists sources one by one, so a new module is invisible to Quartus
# until someone remembers to add it. kaneko_irq.sv was not, and the build died
# with "instantiates undefined entity" — nine seconds into a run that had
# already spent several minutes on lint and the simulation gate. Checked here
# instead, before any of that.
.PHONY: qsf-check
# ------------------------------------------------------- port-count check
# Kaneko16.sv's NPORTS and the harnesses' NP were independent constants that
# happened to match until a sixth port was added for the OKI. The SDRAM
# harness kept testing five, so the OKI's port was never arbitrated in a test —
# and it was also the port kaneko_sdram's per-port burst list forgot, which
# made the sound path silent while every link in it reported success.
#
# Nothing else catches two numbers drifting apart, so this does. Same shape as
# qsf-check, and for the same reason: the failure is invisible otherwise.
#
# It matched `NP = n` and NOT `NPORTS = n`, so the boot harness sat at six
# ports while the core ran eight and this rule reported "NPORTS=8 everywhere"
# the whole time. A boot was then verified in simulation against a
# configuration the core does not have, and reported as reassurance. A guard
# that names the thing it checks has to actually match the spelling used.
.PHONY: nports-check
nports-check:
	@core=$$(sed -n 's/^localparam int unsigned NPORTS *= *\([0-9]*\);.*/\1/p' Kaneko16.sv); \
	[ -n "$$core" ] || { echo "nports: could not read NPORTS from Kaneko16.sv"; exit 1; }; \
	bad=""; \
	for f in $$(grep -rlE '\bNP(ORTS)? *= *[0-9]' sim/ 2>/dev/null); do \
	  n=$$(sed -nE 's/.*\bNP(ORTS)? *= *([0-9]+).*/\2/p' "$$f" | head -1); \
	  [ "$$n" = "$$core" ] || bad="$$bad $$f:$$n"; done; \
	if [ -n "$$bad" ]; then \
	  echo "nports: Kaneko16.sv has NPORTS=$$core, but:"; \
	  for b in $$bad; do echo "        $${b%%:*} has NP=$${b##*:}"; done; \
	  echo "        a port the harness does not drive is a port nothing tests."; \
	  exit 1; fi
	@echo "nports: NPORTS=$$(sed -n 's/^localparam int unsigned NPORTS *= *\([0-9]*\);.*/\1/p' Kaneko16.sv) everywhere"

qsf-check:
	@miss=""; for f in $(RTL); do \
	  grep -qF "$$f" Kaneko16.qsf || miss="$$miss $$f"; done; \
	if [ -n "$$miss" ]; then \
	  echo "quartus: these RTL files are not in Kaneko16.qsf:"; \
	  for f in $$miss; do echo "         $$f"; done; \
	  echo "         add a SYSTEMVERILOG_FILE line for each."; exit 1; fi
	@echo "qsf: all $(words $(RTL)) RTL file(s) in the project"

quartus: qsf-check nports-check lint test quartus-check
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
	  case "$$rest2" in \
	    *:FX68K)  extra="$(FX68K_SIM)";; \
	    *:JT6295) extra="$(JT6295_SIM)";; \
	    *:JT51)   extra="$(JT51_SIM)";; \
	  esac; \
	  $(VERILATOR) $(VBUILD) $(VFLAGS) --top-module $$top \
	    --Mdir build/obj_$$name -o $$name $(RTL) $(SIM_SV) $$extra $$src >/dev/null 2>&1 || { \
	      echo "BUILD FAILED: $$name"; \
	      $(VERILATOR) $(VBUILD) $(VFLAGS) --top-module $$top \
	        --Mdir build/obj_$$name -o $$name $(RTL) $(SIM_SV) $$extra $$src; fail=1; continue; }; \
	  ./build/obj_$$name/$$name || fail=1; \
	done; \
	if [ $$fail -ne 0 ]; then echo "TESTS FAILED"; exit 1; fi

# ------------------------------------------------------------ bus trace
# Rule 6: the CPU is settled against MAME, not against a waveform. Both sides
# emit the same four-column format so they diff directly.
#
# Every access crosses into Lua on the MAME side, so the oracle runs far slower
# than the core does; 100k accesses is about a minute and covers boot through
# the first clears of palette, sprite RAM and both VIEW2 tilemaps.
TRACE_N   ?= 100000
TRACE_DIR ?= build/bustrace
.PHONY: bustrace
bustrace: regions
	@mkdir -p $(TRACE_DIR) build/tmp
	@echo "== ours"
	@$(MAKE) --no-print-directory boot SET=$(SET) \
	  BOOT_ARGS="--trace $(CURDIR)/$(TRACE_DIR)/ours.txt --count $(TRACE_N)" \
	  | grep -E "bus trace|reset SSP|FAIL|PASS"
	@echo "== mame"
	@# MAME drops nvram/ and cfg/ wherever it starts, and explbrkr's EEPROM is
	@# one of them. A saved EEPROM makes the oracle boot a FORMATTED machine
	@# while the core boots a blank one, so the two take different paths through
	@# the setup code and the trace diverges for a reason that is nothing to do
	@# with the core. Cleared every run — the comparison is always first-boot.
	@rm -rf $(TRACE_DIR)/nvram $(TRACE_DIR)/cfg
	@cd $(TRACE_DIR) && BUS_TRACE_COUNT=$(TRACE_N) BUS_TRACE_OUT=mame.txt \
	  mame -rompath $(ROMPATH) $(SET) \
	    -autoboot_script $(CURDIR)/tools/mame_bus_trace.lua \
	    -skip_gameinfo -autoboot_delay 0 -seconds_to_run 120 \
	    -video none -sound none -nothrottle 2>&1 | grep "bus trace"
	@echo "== diff"
	@tools/diff_bus_trace.py $(TRACE_DIR)/ours.txt $(TRACE_DIR)/mame.txt

# ------------------------------------------------------- eeprom fidelity
# Replay MAME's own CLK/DI/CS sequence against kaneko_eeprom93c46 and check
# every value the game reads back. Separate from `make test` because the
# stimulus is extracted from a MAME trace of a real ROM, so it lives under
# build/ and is never committed (hard rule 2).
EE_N ?= 200000
.PHONY: eetest
eetest:
	@mkdir -p $(TRACE_DIR) build/tmp
	@rm -rf $(TRACE_DIR)/nvram $(TRACE_DIR)/cfg
	@cd $(TRACE_DIR) && EE_CAP_COUNT=$(EE_N) EE_CAP_OUT=ee_stim.txt \
	  mame -rompath $(ROMPATH) $(SET) \
	    -autoboot_script $(CURDIR)/tools/mame_eeprom_capture.lua \
	    -skip_gameinfo -autoboot_delay 0 -seconds_to_run 60 \
	    -video none -sound none -nothrottle 2>&1 | grep "eeprom capture"
	@$(VERILATOR) $(VBUILD) $(VFLAGS) --top-module kaneko_eeprom93c46 \
	  --Mdir build/obj_kaneko_eereplay -o kaneko_eereplay \
	  $(RTL) sim/io/tb_kaneko_eeprom_replay.cpp >/dev/null 2>&1 || { \
	    $(VERILATOR) $(VBUILD) $(VFLAGS) --top-module kaneko_eeprom93c46 \
	      --Mdir build/obj_kaneko_eereplay -o kaneko_eereplay \
	      $(RTL) sim/io/tb_kaneko_eeprom_replay.cpp; exit 1; }
	@./build/obj_kaneko_eereplay/kaneko_eereplay $(TRACE_DIR)/ee_stim.txt

# --------------------------------------------------------------- release
# The layout MiSTer expects, and what a tester copies to the SD card:
#
#   releases/Kaneko16_YYYYMMDD.rbf        the bitstream, dated
#   releases/<Game> (Region).mra          one primary MRA per game
#   releases/_alternatives/_<Game>/...    regional variants, opt-in
#
# The primary MRA is what appears in /_Arcade/ on a stock install; variants are
# copied by hand. Convention for "primary" is World or USA if one exists,
# otherwise Japan — so Blaze On's only dumped set here is the Japan one and it
# sits under _alternatives until a World set turns up.
#
# releases/ is gitignored for now: the .rbf changes every build and this core is
# not ready to publish. Un-ignore it when there is a version worth tagging.
.PHONY: release
release:
	@test -f build/quartus/Kaneko16.rbf || { \
	  echo "release: no bitstream — run 'make quartus' first"; exit 1; }
	@mkdir -p releases/_alternatives
	@d=$$(date +%Y%m%d); cp build/quartus/Kaneko16.rbf releases/Kaneko16_$$d.rbf; \
	  echo "  releases/Kaneko16_$$d.rbf"
	@for gf in $(GATE_GAMES); do g=$${gf%%:*}; \
	  $(MAKE) --no-print-directory mra SET=$$g >/dev/null 2>&1 || true; done
	@tools/stage_release.py build/mra releases
	@find releases -type f | sort | sed 's/^/  /'

# ---------------------------------------------------------------- deploy
# Copy the core and its MRAs to a MiSTer and verify the checksum. Override the
# address with MISTER=<ip>. See tools/deploy.sh for why this is a script and
# not a line of ssh — `setsid` wedged a whole session.
.PHONY: deploy
deploy:
	@tools/deploy.sh $(DEPLOY_ARGS)

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
	  $(RTL) $(SIM_SV) $(FX68K_SIM) $(JT49_SIM) $(JT6295_SIM) sim/top/tb_kaneko_cpumem.cpp >/dev/null 2>&1 || { \
	    $(VERILATOR) $(VBUILD) $(VFLAGS) --top-module kaneko_cpumem_harness \
	      --Mdir build/obj_kaneko_cpumem -o kaneko_cpumem \
	      $(RTL) $(SIM_SV) $(FX68K_SIM) $(JT49_SIM) $(JT6295_SIM) sim/top/tb_kaneko_cpumem.cpp; \
	    echo "BUILD FAILED: kaneko_cpumem"; exit 1; }
	@[ -f $(ROM_DIR)/$(SET)_maincpu.bin ] || { \
	  echo "boot: $(SET) has no maincpu region."; \
	  echo "      Only explbrkr's 68000 program is described in"; \
	  echo "      tools/build_rom_regions.py — the other sets carry graphics and"; \
	  echo "      sound only, because the frame gate never needed their code."; \
	  echo "      kaneko_bus also decodes bakubrkr_map alone, so booting another"; \
	  echo "      title needs its memory map too, not just its ROM."; exit 1; }
	@./build/obj_kaneko_cpumem/kaneko_cpumem $(ROM_DIR)/$(SET)_maincpu.bin $(BOOT_ARGS)

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
	@mkdir -p build/mra $(ROM_DIR)
	@tools/build_rom_regions.py $(SET) $(ROMPATH) $(ROM_DIR) --stream --mra
	@# The MRA is named after the GAME, because that filename is what the
	@# MiSTer arcade menu displays. Find it rather than assuming the set name.
	@f=$$(ls -t build/mra/*.mra | head -1); tools/verify_mra.py "$$f" $(ROMPATH) $(ROM_DIR)/$(SET)_stream.bin

# Hard rule 10: one directory holds everything generated, so a clean is
# complete and git status stays readable.
clean:
	rm -rf build obj_* output_files db incremental_db yosys.log abc.history
