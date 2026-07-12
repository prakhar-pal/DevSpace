# DevSpace — native macOS app build/test interface (pure SwiftPM).
#
# Builds with `swift build` and hand-assembles the .app bundle (Ronin-style),
# deliberately avoiding `xcodebuild` so no Xcode simulator components are needed.
# The Swift project lives at the repo root.

SHELL := /bin/bash

# The debug log lives OUTSIDE the repo: the repo sits under ~/Documents, which
# is TCC-gated — the ad-hoc-signed dev build's code identity changes on every
# rebuild, so macOS re-prompts for Documents access and the app's very first
# Log.write blocks on the consent dialog (observed as a hang at launch).
# ~/Library/Logs needs no consent; .tmp/devspace.log stays a symlink to it so
# existing tail workflows keep working.
LOG_PATH := $(HOME)/Library/Logs/DevSpaceDev.log
APP_DEV  := build/DevSpaceDev.app
APP_REL  := build/DevSpace.app

# Where `make install` puts the release app (override: make install APP_INSTALL_LOCATION=~/Apps).
APP_INSTALL_LOCATION ?= /Applications

.PHONY: bootstrap build-dev build test run clean install help

help:
	@echo "DevSpace native build targets:"
	@echo "  make build-dev  - Debug build + assemble \"DevSpaceDev.app\" (amber icon)"
	@echo "  make build      - Release build + assemble \"DevSpace.app\""
	@echo "  make test       - run unit tests (swift test)"
	@echo "  make run        - build-dev and launch the app"
	@echo "  make install    - release build + install to \$$APP_INSTALL_LOCATION (default /Applications)"
	@echo "  make clean      - remove build output"

bootstrap:
	@echo "Uses the Swift toolchain bundled with Xcode — nothing to install."

build-dev:
	swift build --product DevSpaceApp
	bash scripts/assemble-app.sh debug "DevSpaceDev" DevSpaceDev "$(LOG_PATH)"
	@mkdir -p .tmp && ln -sfn "$(LOG_PATH)" .tmp/devspace.log

build:
	swift build -c release --product DevSpaceApp
	bash scripts/assemble-app.sh release "DevSpace" DevSpace ""

test:
	swift test

run: build-dev
	@# Match by bundle path — `pkill -x DevSpace` would also kill the installed
	@# production app (both bundles share the executable name).
	@pkill -f "$(CURDIR)/$(APP_DEV)/Contents/MacOS/DevSpace" 2>/dev/null || true
	@sleep 0.3
	open "$(APP_DEV)"

install: build
	@if pgrep -fq "$(APP_INSTALL_LOCATION)/DevSpace.app/Contents/MacOS/DevSpace"; then \
	  echo "error: DevSpace.app at $(APP_INSTALL_LOCATION) is running — quit it first."; exit 1; \
	fi
	mkdir -p "$(APP_INSTALL_LOCATION)"
	rm -rf "$(APP_INSTALL_LOCATION)/DevSpace.app"
	ditto "$(APP_REL)" "$(APP_INSTALL_LOCATION)/DevSpace.app"
	@echo "✓ installed $(APP_INSTALL_LOCATION)/DevSpace.app"

clean:
	swift package clean
	rm -rf build
