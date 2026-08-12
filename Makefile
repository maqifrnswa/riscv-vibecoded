# up5k-rv top-level Makefile.
#
# Every target that invokes a tool sources scripts/env.sh first so the pinned
# toolchain (installed by M0 provisioning) is on PATH. env.sh is a safe no-op
# while the tools are still being installed.

SHELL := /bin/bash

# Scratch directory for build/simulation artifacts (gitignored).
BUILD_DIR := build

# Environment bootstrap (sources toolchain PATH + defines REPO_ROOT).
ENV_SH := scripts/env.sh

.PHONY: env lint sim-hello p2-tests formal formal-smoke formal-smoke-generate synth clean

## env -- print pinned tool versions (M0 provisioning must be complete).
env:
	@source $(ENV_SH); \
	echo "REPO_ROOT=$$REPO_ROOT"; \
	echo "yosys:         $$(command -v yosys >/dev/null 2>&1 && yosys --version || echo 'not found (M0 provisioning pending)')"; \
	echo "nextpnr-ice40: $$(command -v nextpnr-ice40 >/dev/null 2>&1 && nextpnr-ice40 --version 2>&1 || echo 'not found (M0 provisioning pending)')"; \
	echo "verilator:     $$(command -v verilator >/dev/null 2>&1 && verilator --version || echo 'not found (M0 provisioning pending)')"; \
	echo "iverilog:      $$(command -v iverilog >/dev/null 2>&1 && iverilog -V 2>&1 | head -1 || echo 'not found (M0 provisioning pending)')"; \
	echo "sby:           $$(command -v sby >/dev/null 2>&1 && sby --version 2>&1 || echo 'not found (M0 provisioning pending)')"; \
	echo "riscv gcc:     $$(command -v riscv-none-elf-gcc || command -v riscv32-unknown-elf-gcc || command -v riscv64-unknown-elf-gcc || echo 'not found (M0 provisioning pending)')"

## lint -- run the mandatory lint gate (yosys read_slang + verilator --lint-only).
lint:
	@source $(ENV_SH); \
	scripts/lint.sh

## sim-hello -- compile and run the hello smoke testbench with iverilog.
sim-hello:
	@source $(ENV_SH); \
	mkdir -p $(BUILD_DIR); \
	iverilog -g2012 -o $(BUILD_DIR)/tb_hello rtl/hello/hello.sv rtl/hello/tb_hello.sv; \
	vvp $(BUILD_DIR)/tb_hello

## p2-tests -- M1 P2 staged core tests (leaf modules + core integration).
p2-tests:
	@source $(ENV_SH); \
	scripts/p2_tests.sh

## formal -- placeholder until M1.
formal:
	@echo "formal: not yet implemented (M1)"

## formal-smoke -- M0 toolchain de-risk: run the green stock-picorv32 subset
## via riscv-formal + SymbiYosys (see scripts/formal_smoke.sh).
formal-smoke:
	@source $(ENV_SH); \
	scripts/formal_smoke.sh

## formal-smoke-generate -- explicit generation of the riscv-formal checks for
## the stock picorv32 binding (rv32imc). Copies the vendored core into the
## binding and runs genchecks.py to emit the .sby files.
formal-smoke-generate:
	@source $(ENV_SH); \
	cp -f third_party/picorv32.v formal/riscv-formal/cores/picorv32/picorv32.v; \
	cd formal/riscv-formal/cores/picorv32 && python3 ../../checks/genchecks.py

## synth -- placeholder until M5.
synth:
	@echo "synth: not yet implemented (M5)"

## clean -- remove build/simulation artifacts.
clean:
	@source $(ENV_SH); \
	rm -rf $(BUILD_DIR)
