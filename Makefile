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
LINUX_DEV_PREFIX ?= build/linux-dev
LINUX_DEV_BUNDLE ?= build/linux-dev-bundle
LINUX_SWIFT_SCRATCH ?= .tmp/swift-linux-app
LINUX_SWIFT_RUNTIME ?= $(shell $(SWIFT) -print-target-info | python3 -c 'import json,sys; print(json.load(sys.stdin)["paths"]["runtimeLibraryPaths"][0])')
SWIFT ?= swift
SWIFTC ?= swiftc

.PHONY: linux-build-dev linux-bundle-dev linux-run linux-test-core linux-test-protocol linux-test-gtk linux-test

linux-build-dev:
	$(SWIFT) build --product DevSpaceLinuxApp --scratch-path "$(LINUX_SWIFT_SCRATCH)"
	$(SWIFT) build --product DevSpaceLinuxBackend --scratch-path "$(LINUX_SWIFT_SCRATCH)"
	mkdir -p "$(LINUX_DEV_PREFIX)/bin"
	install -m 755 "$(LINUX_SWIFT_SCRATCH)/debug/DevSpaceLinuxApp" "$(LINUX_DEV_PREFIX)/bin/DevSpaceLinuxApp"
	install -m 755 "$(LINUX_SWIFT_SCRATCH)/debug/DevSpaceLinuxBackend" "$(LINUX_DEV_PREFIX)/bin/DevSpaceLinuxBackend"

linux-bundle-dev: linux-build-dev
	python3 scripts/assemble-linux.py --frontend "$(LINUX_DEV_PREFIX)" --backend "$(LINUX_DEV_PREFIX)/bin/DevSpaceLinuxBackend" --swift-runtime "$(LINUX_SWIFT_RUNTIME)" --channel development --output "$(LINUX_DEV_BUNDLE)" --replace

linux-run: linux-bundle-dev
	"$(LINUX_DEV_BUNDLE)/bin/devspace-dev"

linux-test-core:
	$(SWIFT) test --scratch-path .tmp/swift-linux-tests

linux-test-protocol:
	DEVSPACE_SWIFTC="$(SWIFTC)" python3 -B -m unittest Tests.Linux.test_linux_backend_client -v

linux-test-gtk:
	env -u WAYLAND_DISPLAY GDK_BACKEND=x11 DEVSPACE_SWIFTC="$(SWIFTC)" \
	python3 -B -m unittest Tests.Linux.test_linux_workspace_window Tests.Linux.test_linux_gtk_app -v

linux-test: linux-build-dev
	DEVSPACE_TEST_BACKEND="$(LINUX_DEV_PREFIX)/bin/DevSpaceLinuxBackend" \
	DEVSPACE_TEST_FRONTEND_PREFIX="$(LINUX_DEV_PREFIX)" \
	DEVSPACE_TEST_SWIFT_RUNTIME="$(LINUX_SWIFT_RUNTIME)" \
	DEVSPACE_SWIFTC="$(SWIFTC)" python3 -B -m unittest discover -s Tests/Linux -v

endif

help:
	@echo "DevSpace native build targets:"
	@echo "  make build-dev  - Debug build + assemble \"DevSpaceDev.app\" (amber icon)"
	@echo "  make build      - Release build + assemble \"DevSpace.app\""
	@echo "  make test       - run unit tests (swift test)"
	@echo "  make run        - build-dev and launch the app"
	@echo "  make install    - release build + install to \$$APP_INSTALL_LOCATION (default /Applications)"
	@echo "  make clean      - remove build output"
	@echo "  make linux-build-dev     - build the Swift GTK/VTE frontend and backend"
	@echo "  make linux-bundle-dev    - assemble a relocatable development bundle"
	@echo "  make linux-run           - build, bundle, and launch DevSpaceDev on Linux"
	@echo "  make linux-test-core     - run the Swift Core XCTest target"
	@echo "  make linux-test-protocol - exercise the Swift backend protocol client"
	@echo "  make linux-test-gtk      - test the GTK/VTE window and terminal lifecycle"

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
