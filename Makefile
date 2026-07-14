# Makefile for TDC project - ISE 14.7 command-line flow
# Usage: make [target]

SHELL := /bin/bash

.PHONY: all synth translate map route bitgen timing clean summary check help

# Default target
all:
	@bash scripts/build.sh all

# Individual stages
synth:
	@bash scripts/build.sh synth

translate:
	@bash scripts/build.sh translate

map:
	@bash scripts/build.sh map

route:
	@bash scripts/build.sh par

bitgen:
	@bash scripts/build.sh bitgen

timing:
	@bash scripts/build.sh timing

clean:
	@bash scripts/build.sh clean

summary:
	@bash scripts/build.sh summary

# Quick check: synth only, show errors and first 20 warnings
check:
	@bash scripts/build.sh synth
	@echo ""
	@echo "========== ERRORS =========="
	@grep "^ERROR:" logs/1_synth.log 2>/dev/null || echo "  None"
	@echo ""
	@echo "========== WARNINGS (first 20) =========="
	@grep "^WARNING:" logs/1_synth.log 2>/dev/null | head -20 || echo "  None"

# Show all errors from all stages
errors:
	@echo "========== ALL ERRORS =========="
	@grep -n "^ERROR:" logs/*.log 2>/dev/null || echo "  None"

# Show all warnings from all stages
warnings:
	@echo "========== ALL WARNINGS =========="
	@grep -n "^WARNING:" logs/*.log 2>/dev/null || echo "  None"

help:
	@echo "Available targets:"
	@echo "  make all       - Full build (synth through bitstream + timing)"
	@echo "  make synth     - Synthesis only (fastest, catches VHDL errors)"
	@echo "  make check     - Synth + show errors and warnings"
	@echo "  make translate - Synth + translate (catches UCF errors)"
	@echo "  make map       - Through map (catches resource issues)"
	@echo "  make route     - Through place and route"
	@echo "  make bitgen    - Through bitstream generation"
	@echo "  make timing    - Run timing analysis (after route)"
	@echo "  make clean     - Remove all build artifacts"
	@echo "  make errors    - Show all errors from build logs"
	@echo "  make warnings  - Show all warnings from build logs"
	@echo "  make summary   - Show build summary"
	@echo "  make help      - This message"