# Vesper — make targets. `make smoke` is the definition of done.
GODOT ?= $(shell command -v godot 2>/dev/null || (test -x /Applications/Godot.app/Contents/MacOS/Godot && echo /Applications/Godot.app/Contents/MacOS/Godot) || echo /usr/local/bin/godot)
SMOKE_SECONDS ?= 600
# coreutils timeout (Linux) bounds a smoke whose Godot never exits, e.g. after a script load failure; absent on macOS
TIMEOUT := $(shell command -v timeout >/dev/null 2>&1 && echo "timeout $$(( $(SMOKE_SECONDS) + 600 ))")
SHA256 := $(shell command -v sha256sum 2>/dev/null || echo "shasum -a 256")
XVFB := $(shell command -v xvfb-run >/dev/null 2>&1 && echo "xvfb-run -a")
WS ?= ws://127.0.0.1:9002
OUT ?= state/screenshot.png

.PHONY: smoke smoke-quick run dev viewer viewer-dev screenshot export-web deploy overseer kernel-hash import check verify art art-eval season-cycle visitor-check

## headless boot + fast run + determinism replay + checkpoint round-trip + $(SMOKE_SECONDS)s real-time run
smoke:
	SMOKE_SECONDS=$(SMOKE_SECONDS) $(TIMEOUT) $(GODOT) --headless --path . -s kernel/smoke.gd

smoke-quick:
	$(MAKE) -s smoke SMOKE_SECONDS=15

## the canonical world server (what systemd runs)
run:
	$(GODOT) --headless --path . -- --server

## a throwaway world on port 9002 with a stubbed model, for local development
dev:
	$(GODOT) --headless --path . -- --server --dev

viewer:
	$(GODOT) --path . -- --ws=ws://127.0.0.1:9001

viewer-dev:
	$(GODOT) --path . -- --ws=ws://127.0.0.1:9002

## save one PNG of the viewer connected to WS (default: the throwaway world), then quit; under xvfb on a server. Used by overseer sessions and the Judge.
screenshot:
	$(XVFB) $(GODOT) --path . -- --ws=$(WS) --screenshot=$(OUT)

export-web:
	mkdir -p build/web
	$(GODOT) --headless --path . --import >/dev/null 2>&1 || true
	$(GODOT) --headless --path . --export-release Web build/web/index.html
	@test -f build/web/index.wasm && echo "web export ok: build/web" || (echo "web export failed (are the export templates installed?)" && exit 1)

## pull, re-export the viewer, restart the world (run on the VPS as any sudoer; git runs as the vesper user)
deploy:
	sudo -u vesper -H git -C /opt/vesper pull --rebase --autostash -X ours origin main
	sudo -u vesper -H $(MAKE) -s -C /opt/vesper export-web
	sudo systemctl restart vesper
	sudo systemctl --no-pager --lines=3 status vesper

overseer:
	python3 overseers/run.py $(ARGS)

## PixelLab: generate whatever the world has and viewer/art/manifest.json lacks (idempotent; spend goes to the art category)
art:
	python3 overseers/pixellab.py --batch $(ARGS)

## art-eval: coverage (no magenta), shared-palette check, size limit, web export boots. The pairwise Judge runs in the gate.
art-eval:
	python3 overseers/pixellab.py --eval

## give every due hypothesis (24-72 h after its merge) a verdict: journal/verdicts.md + state/verdicts.json
verify:
	python3 overseers/run.py --verify

## HUMAN ONLY. Regenerates the kernel manifest after a deliberate kernel edit; then tag last-known-good.
kernel-hash:
	$(SHA256) kernel/*.gd kernel/*.py kernel/*.sh kernel/*.json > kernel/KERNEL.sha256
	@cat kernel/KERNEL.sha256

## build the .godot import cache once (needed before the first export on a fresh clone)
import:
	$(GODOT) --headless --path . --import || true

## one sim year of seasons + three days of weather in seconds (world/season_cycle.gd); part of `make check`
season-cycle:
	$(GODOT) --headless --path . -s world/season_cycle.gd

## a visitor joins, walks, talks (stub Tier 2), gives a gift, is remembered, expires (world/visitor_check.gd)
visitor-check:
	$(GODOT) --headless --path . -s world/visitor_check.gd

check: season-cycle visitor-check
	python3 kernel/rails.py
	python3 overseers/run.py --check
