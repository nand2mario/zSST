# SPDX-License-Identifier: Apache-2.0

SHELL := /bin/bash
VERILATOR ?= verilator
PYTHON ?= python3
BUILD_DIR := build
VERILATOR_WARN := -Wall -Wno-fatal -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-PROCASSINIT

RTL := \
	sst1_pkg.sv \
	generated/sst1_regs_pkg.sv \
	generated/sst1_tmu_tables_pkg.sv \
	frontend/sst1_addr_decode.sv \
	frontend/sst1_float_to_fixed.sv \
	frontend/sst1_pci_fifo.sv \
	frontend/sst1_regfile.sv \
	frontend/sst1_frontend.sv \
	tmu/sst1_texture_layout.sv \
	tmu/sst1_tmu_front_staged.sv \
	tmu/sst1_texture_cache_ram.sv \
	tmu/sst1_texture_cache.sv \
	tmu/sst1_texture_address.sv \
	tmu/sst1_texel_decode.sv \
	tmu/sst1_texture_combine.sv \
	tmu/sst1_tmu.sv \
	fbi/sst1_pixel_pipeline.sv \
	fbi/sst1_fb_write_combine.sv \
	fbi/sst1_fb_read_cache.sv \
	fbi/sst1_fbi.sv \
	video/sst1_video_control.sv \
	sst1_perf_counters.sv \
	sst1_core.sv \
	sst1_device.sv

.PHONY: all test generate clean

all: test

test: generate $(BUILD_DIR)/unit/Vtb_sst1_core
	./$(BUILD_DIR)/unit/Vtb_sst1_core

generate:
	$(PYTHON) tools/registers/generate.py --check
	$(PYTHON) tools/tmu/generate_tables.py --check

$(BUILD_DIR)/unit/Vtb_sst1_core: $(RTL) sim/unit/tb_sst1_core.sv
	mkdir -p $(BUILD_DIR)/unit
	$(VERILATOR) --binary --timing --assert $(VERILATOR_WARN) \
		--Mdir $(BUILD_DIR)/unit --top-module tb_sst1_core $^ \
		-o Vtb_sst1_core

clean:
	$(RM) -r $(BUILD_DIR)
