# DevSpace — native macOS app build/test interface (pure SwiftPM).
#
# Builds with `swift build` and hand-assembles the .app bundle (Ronin-style),
# deliberately avoiding `xcodebuild` so no Xcode simulator components are needed.
# The Swift project lives at the repo root; the legacy Tauri tree is under tauri/.

SHELL := /bin/bash

LOG_PATH := $(CURDIR)/.tmp/devspace.log
APP_DEV  := build/DevSpace Dev.app
APP_REL  := build/DevSpace.app

.PHONY: bootstrap build-dev build test run clean help

help:
	@echo "DevSpace native build targets:"
	@echo "  make build-dev  - Debug build + assemble \"DevSpace Dev.app\" (amber icon)"
	@echo "  make build      - Release build + assemble \"DevSpace.app\""
	@echo "  make test       - run unit tests (swift test)"
	@echo "  make run        - build-dev and launch the app"
	@echo "  make clean      - remove build output"

bootstrap:
	@echo "Uses the Swift toolchain bundled with Xcode — nothing to install."

build-dev:
	swift build --product DevSpaceApp
	bash scripts/assemble-app.sh debug "DevSpace Dev" DevSpaceDev "$(LOG_PATH)"

build:
	swift build -c release --product DevSpaceApp
	bash scripts/assemble-app.sh release "DevSpace" DevSpace ""

test:
	swift test

run: build-dev
	@pkill -x DevSpace 2>/dev/null || true
	@sleep 0.3
	open "$(APP_DEV)"

clean:
	swift package clean
	rm -rf build
