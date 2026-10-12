# DevSpace — native macOS app build/test interface (pure SwiftPM).
#
# Builds with `swift build` and hand-assembles the .app bundle (Ronin-style),
# deliberately avoiding `xcodebuild` so no Xcode simulator components are needed.
# The Swift project lives at the repo root.

SHELL := /bin/bash
.DEFAULT_GOAL := help

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

ifeq ($(shell uname -s),Linux)
LINUX_UPSTREAM ?= .tmp/linux-migration/upstream/ghostty-1.3.1
# Content-addressed copies avoid stale patches without overwriting existing work.
LINUX_FRONTEND ?= .tmp/linux-migration/frontend-$(shell sha256sum Sources/Linux/ghostty-source.json Sources/Linux/patches/*.patch Sources/Linux/*.zig Tests/Linux/gtk_terminal_test.zig scripts/prepare-linux-frontend.py | sha256sum | cut -c1-16)
LINUX_DEV_PREFIX ?= build/linux-dev
LINUX_DEV_BUNDLE ?= build/linux-dev-bundle
LINUX_SWIFT_RUNTIME ?= $(shell $(SWIFT) -print-target-info | python3 -c 'import json,sys; print(json.load(sys.stdin)["paths"]["runtimeLibraryPaths"][0])')
LINUX_OPTIMIZE ?= Debug
SWIFT ?= swift
ZIG ?= zig

.PHONY: linux-prepare linux-build-dev linux-bundle-dev linux-run linux-test-core linux-test-protocol linux-test-gtk
linux-prepare:
	@test -d "$(LINUX_UPSTREAM)" || python3 scripts/prepare-linux-ghostty.py --output .tmp/linux-migration/upstream
	python3 scripts/prepare-linux-frontend.py --upstream "$(LINUX_UPSTREAM)" --output "$(LINUX_FRONTEND)"

$(LINUX_FRONTEND)/src/devspace_gtk_test.zig:
	$(MAKE) linux-prepare

linux-build-dev: $(LINUX_FRONTEND)/src/devspace_gtk_test.zig
	$(SWIFT) build --product DevSpaceLinuxBackend --scratch-path .tmp/swift-controller-test
	cd "$(LINUX_FRONTEND)" && $(if $(findstring /,$(ZIG)),$(abspath $(ZIG)),$(ZIG)) build -Doptimize=$(LINUX_OPTIMIZE) -Dcpu=baseline -Demit-docs=false -Demit-webdata=false -Di18n=false -fno-sys=gtk4-layer-shell -j2 --cache-dir "$(CURDIR)/.tmp/linux-migration/zig-local-cache" --global-cache-dir "$(CURDIR)/.tmp/linux-migration/zig-cache" --prefix "$(abspath $(LINUX_DEV_PREFIX))"
	install -m 755 .tmp/swift-controller-test/debug/DevSpaceLinuxBackend "$(LINUX_DEV_PREFIX)/bin/DevSpaceLinuxBackend"

linux-bundle-dev: linux-build-dev
	python3 scripts/assemble-linux.py --frontend "$(LINUX_DEV_PREFIX)" --backend "$(LINUX_DEV_PREFIX)/bin/DevSpaceLinuxBackend" --swift-runtime "$(LINUX_SWIFT_RUNTIME)" --channel development --output "$(LINUX_DEV_BUNDLE)" --replace

linux-run: linux-bundle-dev
	"$(LINUX_DEV_BUNDLE)/bin/devspace-dev"

linux-test-core:
	$(SWIFT) test --scratch-path .tmp/swift-controller-test

linux-test-protocol:
	$(ZIG) test --dep protocol -Mroot=Tests/Linux/backend_protocol_test.zig -Mprotocol=Sources/Linux/backend_protocol.zig --cache-dir .tmp/linux-migration/zig-local-cache --global-cache-dir .tmp/linux-migration/zig-cache

linux-test-gtk: $(LINUX_FRONTEND)/src/devspace_gtk_test.zig
	cd "$(LINUX_FRONTEND)" && $(if $(findstring /,$(ZIG)),$(abspath $(ZIG)),$(ZIG)) build test-devspace -Doptimize=$(LINUX_OPTIMIZE) -Dcpu=baseline -Demit-docs=false -Demit-webdata=false -Di18n=false -fno-sys=gtk4-layer-shell -j2 --cache-dir "$(CURDIR)/.tmp/linux-migration/zig-local-cache" --global-cache-dir "$(CURDIR)/.tmp/linux-migration/zig-cache"

endif

help:
	@echo "DevSpace native build targets:"
	@echo "  make build-dev  - Debug build + assemble \"DevSpaceDev.app\" (amber icon)"
	@echo "  make build      - Release build + assemble \"DevSpace.app\""
	@echo "  make test       - run unit tests (swift test)"
	@echo "  make run        - build-dev and launch the app"
	@echo "  make install    - release build + install to \$$APP_INSTALL_LOCATION (default /Applications)"
	@echo "  make clean      - remove build output"
	@echo "  make linux-prepare       - prepare patched GTK source"
	@echo "  make linux-build-dev     - build the GTK frontend and Swift backend"
	@echo "  make linux-bundle-dev    - assemble a relocatable development bundle"
	@echo "  make linux-run           - build, bundle, and launch DevSpaceDev on Linux"
	@echo "  make linux-test-core     - test the portable Swift controller"
	@echo "  make linux-test-protocol - test the Zig backend protocol"
	@echo "  make linux-test-gtk      - test the real GTK window and terminals"

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
