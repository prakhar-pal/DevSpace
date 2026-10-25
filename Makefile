# DevSpace — native macOS/Linux build/test interface (pure SwiftPM).
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
export DEVSPACE_LINUX_TERMINAL ?= ghostty
LINUX_DEV_PREFIX ?= build/linux-dev
LINUX_DEV_BUNDLE ?= build/linux-dev-bundle
LINUX_SWIFT_SCRATCH ?= $(if $(filter vte,$(DEVSPACE_LINUX_TERMINAL)),.tmp/swift-linux-app,.tmp/ghostty-skia/app)
LINUX_GHOSTTY_SWIFT_SCRATCH ?= .tmp/ghostty-skia/app
LINUX_GHOSTTY_DEV_PREFIX ?= build/linux-ghostty-dev
LINUX_GHOSTTY_DEV_BUNDLE ?= build/linux-ghostty-dev-bundle
LINUX_SWIFT_RUNTIME ?= $(shell $(SWIFT) -print-target-info | python3 -c 'import json,sys; print(json.load(sys.stdin)["paths"]["runtimeLibraryPaths"][0])')
LINUX_RELEASE_SCRATCH ?= .tmp/swift-linux-release
LINUX_RELEASE_BUNDLE ?= build/linux-production
LINUX_PACKAGE_COPYRIGHT ?=
LINUX_PACKAGE_MAINTAINER ?=
LINUX_SWIFT_LICENSE ?= $(abspath $(LINUX_SWIFT_RUNTIME)/../../../share/swift/LICENSE.txt)
LINUX_ICU_LICENSE ?= $(abspath LICENSES/ICU-76.1.txt)
LINUX_PACKAGE_VERSION ?= $(shell python3 -c 'import plistlib; print(plistlib.load(open("Info.plist", "rb"))["CFBundleShortVersionString"])')
LINUX_PACKAGE_ARCH ?= $(shell dpkg --print-architecture)
LINUX_PACKAGE_OUTPUT ?= build/devspace_$(LINUX_PACKAGE_VERSION)_$(LINUX_PACKAGE_ARCH).deb
LINUX_INSTALL_PREFIX ?= $(HOME)/.local
LINUX_INSTALL_BUNDLE ?=
SWIFT ?= swift
SWIFTC ?= swiftc

# Each bundle receives an inventory generated from the native archives used
# by this renderer. Explicit VTE fallback bundles need no static native notices.
define linux-native-notices
notice_args=(); \
if [ "$(DEVSPACE_LINUX_TERMINAL)" = ghostty ]; then \
  python3 scripts/collect-linux-native-notices.py --fetch-missing --output "$$work/notices"; \
  notice_args=(--third-party-notices "$$work/notices"); \
fi
endef

.PHONY: linux-build-dev linux-ghostty-build-dev linux-ghostty-bundle-dev linux-ghostty-run linux-bundle-dev linux-bundle linux-run linux-package linux-install linux-test-core linux-test-ghostty linux-test-skia linux-test-protocol linux-test-gtk linux-test

install: linux-install
build: linux-bundle

# Assemble only: do not install, launch, or disturb the daily-driver bundle.
linux-bundle:
	@set -eu; \
	mkdir -p .tmp; \
	work=$$(mktemp -d .tmp/linux-build.XXXXXX); \
	had_lock=no; \
	if [ -f Package.resolved ]; then cp -p Package.resolved "$$work/Package.resolved"; had_lock=yes; fi; \
	restore() { \
	  if [ "$$had_lock" = yes ]; then cp -p "$$work/Package.resolved" Package.resolved; else rm -f Package.resolved; fi; \
	  rm -rf "$$work"; \
	}; \
	trap restore EXIT; \
	"$(SWIFT)" build -c release --product DevSpaceLinuxApp --scratch-path "$(LINUX_RELEASE_SCRATCH)"; \
	"$(SWIFT)" build -c release --product DevSpaceLinuxBackend --scratch-path "$(LINUX_RELEASE_SCRATCH)"; \
	mkdir -p "$$work/prefix/bin"; \
	install -m 755 "$(LINUX_RELEASE_SCRATCH)/release/DevSpaceLinuxApp" "$$work/prefix/bin/DevSpaceLinuxApp"; \
	install -m 755 "$(LINUX_RELEASE_SCRATCH)/release/DevSpaceLinuxBackend" "$$work/prefix/bin/DevSpaceLinuxBackend"; \
	$(linux-native-notices); \
	python3 scripts/assemble-linux.py --frontend "$$work/prefix" --backend "$$work/prefix/bin/DevSpaceLinuxBackend" \
	  --swift-runtime "$(LINUX_SWIFT_RUNTIME)" --swift-license "$(LINUX_SWIFT_LICENSE)" --icu-license "$(LINUX_ICU_LICENSE)" \
	  "$${notice_args[@]}" --channel production --output "$(LINUX_RELEASE_BUNDLE)" --replace

# An explicit bundle skips compilation. Otherwise build a fresh release in an
# isolated staging directory; installation itself refuses a running destination.
linux-install:
	@set -eu; \
	if [ -n "$(LINUX_INSTALL_BUNDLE)" ]; then \
	  python3 scripts/install-linux.py --bundle "$(LINUX_INSTALL_BUNDLE)" --prefix "$(LINUX_INSTALL_PREFIX)"; \
	else \
	  mkdir -p .tmp; \
	  work=$$(mktemp -d .tmp/linux-install.XXXXXX); \
	  had_lock=no; \
	  if [ -f Package.resolved ]; then cp -p Package.resolved "$$work/Package.resolved"; had_lock=yes; fi; \
	  restore() { \
	    if [ "$$had_lock" = yes ]; then cp -p "$$work/Package.resolved" Package.resolved; else rm -f Package.resolved; fi; \
	    rm -rf "$$work"; \
	  }; \
	  trap restore EXIT; \
	  "$(SWIFT)" build -c release --product DevSpaceLinuxApp --scratch-path "$(LINUX_RELEASE_SCRATCH)"; \
	  "$(SWIFT)" build -c release --product DevSpaceLinuxBackend --scratch-path "$(LINUX_RELEASE_SCRATCH)"; \
	  mkdir -p "$$work/prefix/bin"; \
	  install -m 755 "$(LINUX_RELEASE_SCRATCH)/release/DevSpaceLinuxApp" "$$work/prefix/bin/DevSpaceLinuxApp"; \
	  install -m 755 "$(LINUX_RELEASE_SCRATCH)/release/DevSpaceLinuxBackend" "$$work/prefix/bin/DevSpaceLinuxBackend"; \
	  $(linux-native-notices); \
	  python3 scripts/assemble-linux.py --frontend "$$work/prefix" --backend "$$work/prefix/bin/DevSpaceLinuxBackend" \
	    --swift-runtime "$(LINUX_SWIFT_RUNTIME)" --swift-license "$(LINUX_SWIFT_LICENSE)" --icu-license "$(LINUX_ICU_LICENSE)" "$${notice_args[@]}" --channel production --output "$$work/bundle"; \
	  python3 scripts/install-linux.py --bundle "$$work/bundle" --prefix "$(LINUX_INSTALL_PREFIX)"; \
	fi

linux-build-dev:
	$(SWIFT) build --product DevSpaceLinuxApp --scratch-path "$(LINUX_SWIFT_SCRATCH)"
	$(SWIFT) build --product DevSpaceLinuxBackend --scratch-path "$(LINUX_SWIFT_SCRATCH)"
	mkdir -p "$(LINUX_DEV_PREFIX)/bin"
	install -m 755 "$(LINUX_SWIFT_SCRATCH)/debug/DevSpaceLinuxApp" "$(LINUX_DEV_PREFIX)/bin/DevSpaceLinuxApp"
	install -m 755 "$(LINUX_SWIFT_SCRATCH)/debug/DevSpaceLinuxBackend" "$(LINUX_DEV_PREFIX)/bin/DevSpaceLinuxBackend"

# Compatibility aliases retaining the separate migration artifact paths.
linux-ghostty-build-dev:
	$(MAKE) linux-build-dev DEVSPACE_LINUX_TERMINAL=ghostty \
		LINUX_SWIFT_SCRATCH="$(LINUX_GHOSTTY_SWIFT_SCRATCH)" LINUX_DEV_PREFIX="$(LINUX_GHOSTTY_DEV_PREFIX)"

linux-ghostty-run: linux-ghostty-build-dev
	DEVSPACE_BUILD_CHANNEL=development DEVSPACE_BACKEND="$(abspath $(LINUX_GHOSTTY_DEV_PREFIX))/bin/DevSpaceLinuxBackend" \
		"$(LINUX_GHOSTTY_DEV_PREFIX)/bin/DevSpaceLinuxApp"

linux-ghostty-bundle-dev: linux-ghostty-build-dev
	@set -eu; \
	mkdir -p .tmp; \
	work=$$(mktemp -d .tmp/linux-ghostty-bundle.XXXXXX); \
	trap 'rm -rf "$$work"' EXIT; \
	python3 scripts/collect-linux-native-notices.py --fetch-missing --output "$$work/notices"; \
	python3 scripts/assemble-linux.py --frontend "$(LINUX_GHOSTTY_DEV_PREFIX)" \
	  --backend "$(LINUX_GHOSTTY_DEV_PREFIX)/bin/DevSpaceLinuxBackend" \
	  --swift-runtime "$(LINUX_SWIFT_RUNTIME)" --swift-license "$(LINUX_SWIFT_LICENSE)" \
	  --icu-license "$(LINUX_ICU_LICENSE)" --third-party-notices "$$work/notices" \
	  --channel development --output "$(LINUX_GHOSTTY_DEV_BUNDLE)" --replace

linux-bundle-dev: linux-build-dev
	@set -eu; mkdir -p .tmp; \
	work=$$(mktemp -d .tmp/linux-dev-bundle.XXXXXX); \
	trap 'rm -rf "$$work"' EXIT; \
	$(linux-native-notices); \
	python3 scripts/assemble-linux.py --frontend "$(LINUX_DEV_PREFIX)" --backend "$(LINUX_DEV_PREFIX)/bin/DevSpaceLinuxBackend" --swift-runtime "$(LINUX_SWIFT_RUNTIME)" --swift-license "$(LINUX_SWIFT_LICENSE)" --icu-license "$(LINUX_ICU_LICENSE)" "$${notice_args[@]}" --channel development --output "$(LINUX_DEV_BUNDLE)" --replace

linux-run: linux-bundle-dev
	"$(LINUX_DEV_BUNDLE)/bin/devspace-dev"

linux-package:
	@test -n "$(LINUX_PACKAGE_COPYRIGHT)" || { echo "Set LINUX_PACKAGE_COPYRIGHT to the project's Debian copyright manifest." >&2; exit 2; }
	@test -n "$(LINUX_PACKAGE_MAINTAINER)" || { echo "Set LINUX_PACKAGE_MAINTAINER to 'Name <email>'." >&2; exit 2; }
	@set -eu; \
	mkdir -p .tmp; \
	work=$$(mktemp -d .tmp/linux-package.XXXXXX); \
	lock_backup=$$(mktemp .tmp/linux-package-lock.XXXXXX); \
	had_lock=no; \
	if [ -f Package.resolved ]; then cp -p Package.resolved "$$lock_backup"; had_lock=yes; fi; \
	restore() { \
		if [ "$$had_lock" = yes ]; then cp -p "$$lock_backup" Package.resolved; \
		else rm -f Package.resolved; fi; \
		rm -f "$$lock_backup"; rm -rf "$$work"; \
	}; \
	trap restore EXIT; \
	"$(SWIFT)" build -c release --product DevSpaceLinuxApp --scratch-path "$(LINUX_RELEASE_SCRATCH)"; \
	"$(SWIFT)" build -c release --product DevSpaceLinuxBackend --scratch-path "$(LINUX_RELEASE_SCRATCH)"; \
	mkdir -p "$$work/prefix/bin"; \
	install -m 755 "$(LINUX_RELEASE_SCRATCH)/release/DevSpaceLinuxApp" "$$work/prefix/bin/DevSpaceLinuxApp"; \
	install -m 755 "$(LINUX_RELEASE_SCRATCH)/release/DevSpaceLinuxBackend" "$$work/prefix/bin/DevSpaceLinuxBackend"; \
	$(linux-native-notices); \
	python3 scripts/assemble-linux.py --frontend "$$work/prefix" --backend "$$work/prefix/bin/DevSpaceLinuxBackend" \
		--swift-runtime "$(LINUX_SWIFT_RUNTIME)" --swift-license "$(LINUX_SWIFT_LICENSE)" --icu-license "$(LINUX_ICU_LICENSE)" "$${notice_args[@]}" --channel production --output "$$work/bundle"; \
	python3 scripts/package-linux.py --bundle "$$work/bundle" --copyright-file "$(LINUX_PACKAGE_COPYRIGHT)" \
		--swift-license "$(LINUX_SWIFT_LICENSE)" --maintainer "$(LINUX_PACKAGE_MAINTAINER)" \
		--output "$(LINUX_PACKAGE_OUTPUT)"

linux-test-core:
	$(SWIFT) test --scratch-path .tmp/swift-linux-tests

linux-test-ghostty:
	SWIFTC="$(SWIFTC)" bash scripts/test-ghostty-engine.sh

linux-test-skia:
	SWIFTC="$(SWIFTC)" bash scripts/test-skia-renderer.sh

linux-test-protocol:
	DEVSPACE_SWIFTC="$(SWIFTC)" python3 -B -m unittest Tests.Linux.test_linux_backend_client -v

ifeq ($(DEVSPACE_LINUX_TERMINAL),ghostty)
linux-test-gtk:
	GTK_A11Y=test GTK_IM_MODULE=simple GDK_BACKEND=x11 DEVSPACE_PRIVATE_KEY_TEST=1 \
	dbus-run-session -- xvfb-run -a $(SWIFT) test --scratch-path "$(LINUX_SWIFT_SCRATCH)" \
	--filter 'AccessibilityTests|AccessibilityBusTests|HerdrClipboardTests|TerminalPaneTests'
else
linux-test-gtk:
	env -u WAYLAND_DISPLAY GDK_BACKEND=x11 DEVSPACE_SWIFTC="$(SWIFTC)" \
	dbus-run-session -- python3 -B -m unittest Tests.Linux.test_linux_workspace_window Tests.Linux.test_linux_gtk_app -v
endif

linux-test: linux-bundle-dev
	DEVSPACE_TEST_BACKEND="$(LINUX_DEV_PREFIX)/bin/DevSpaceLinuxBackend" \
	DEVSPACE_TEST_FRONTEND_PREFIX="$(LINUX_DEV_PREFIX)" \
	DEVSPACE_TEST_SWIFT_RUNTIME="$(LINUX_SWIFT_RUNTIME)" \
	DEVSPACE_TEST_TERMINAL_RENDERER="$(DEVSPACE_LINUX_TERMINAL)" \
	DEVSPACE_TEST_NATIVE_NOTICES="$(if $(filter ghostty,$(DEVSPACE_LINUX_TERMINAL)),$(abspath $(LINUX_DEV_BUNDLE))/share/doc/devspace/third-party)" \
	DEVSPACE_SWIFTC="$(SWIFTC)" dbus-run-session -- python3 -B -m unittest discover -s Tests/Linux -v

ifeq ($(DEVSPACE_LINUX_TERMINAL),ghostty)
linux-test: linux-test-gtk
endif

endif

help:
	@echo "DevSpace native build targets:"
	@echo "  make build-dev  - Debug build + assemble \"DevSpaceDev.app\" (amber icon)"
	@echo "  make build      - Release bundle ($(if $(filter Linux,$(shell uname -s)),$(LINUX_RELEASE_BUNDLE),DevSpace.app)); does not install or launch"
	@echo "  make test       - run unit tests (swift test)"
	@echo "  make run        - build-dev and launch the app"
	@echo "  make install    - release build + install ($(if $(filter Linux,$(shell uname -s)),default ~/.local; LINUX_INSTALL_PREFIX overrides,default /Applications; APP_INSTALL_LOCATION overrides))"
	@echo "  make clean      - remove build output"
	@echo "  make linux-build-dev     - build the Swift GTK/libghostty/Skia frontend and backend"
	@echo "  make linux-bundle-dev    - assemble a relocatable development bundle"
	@echo "  make linux-ghostty-bundle-dev - compatibility alias using the migration artifact path"
	@echo "  make linux-bundle        - assemble a relocatable production bundle (same as make build on Linux)"
	@echo "  make linux-run           - build, bundle, and launch DevSpaceDev on Linux"
	@echo "  make linux-package       - build a production Ubuntu .deb (requires copyright and maintainer metadata)"
	@echo "  make linux-test-core     - run the Swift Core XCTest target"
	@echo "  make linux-test-ghostty  - test the Swift libghostty-vt engine"
	@echo "  make linux-test-skia     - test the portable Swift/Skia renderer"
	@echo "  make linux-test-protocol - exercise the Swift backend protocol client"
	@echo "  make linux-test-gtk      - test GTK terminal interaction and PTY lifecycle"

bootstrap:
ifeq ($(shell uname -s),Linux)
	@echo "Install the global Swift/native dependencies and build the pinned libraries; see docs/linux-development.md and Tests/SkiaInterop/README.md."
else
	@echo "Uses the Swift toolchain bundled with Xcode — nothing to install."
endif

ifeq ($(shell uname -s),Linux)
build-dev: linux-bundle-dev
run: linux-run
test:
	$(SWIFT) test --scratch-path "$(LINUX_SWIFT_SCRATCH)"
else
build-dev:
	swift build --product DevSpaceApp
	bash scripts/assemble-app.sh debug "DevSpaceDev" DevSpaceDev "$(LOG_PATH)"
	@mkdir -p .tmp && ln -sfn "$(LOG_PATH)" .tmp/devspace.log

ifneq ($(shell uname -s),Linux)
build:
	swift build -c release --product DevSpaceApp
	bash scripts/assemble-app.sh release "DevSpace" DevSpace ""
endif

test:
	swift test

run: build-dev
	@# Match by bundle path — `pkill -x DevSpace` would also kill the installed
	@# production app (both bundles share the executable name).
	@pkill -f "$(CURDIR)/$(APP_DEV)/Contents/MacOS/DevSpace" 2>/dev/null || true
	@sleep 0.3
	open "$(APP_DEV)"
endif

ifneq ($(shell uname -s),Linux)
install: build
	@if pgrep -fq "$(APP_INSTALL_LOCATION)/DevSpace.app/Contents/MacOS/DevSpace"; then \
	  echo "error: DevSpace.app at $(APP_INSTALL_LOCATION) is running — quit it first."; exit 1; \
	fi
	mkdir -p "$(APP_INSTALL_LOCATION)"
	rm -rf "$(APP_INSTALL_LOCATION)/DevSpace.app"
	ditto "$(APP_REL)" "$(APP_INSTALL_LOCATION)/DevSpace.app"
	@echo "✓ installed $(APP_INSTALL_LOCATION)/DevSpace.app"
endif

clean:
	swift package clean
	rm -rf build
