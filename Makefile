# AirFocus: see README.md
BUNDLE_ID := com.gshimoon.airfocus
APP       := build/AirFocus.app
APP_BIN   := $(APP)/Contents/MacOS/AirFocus
INSTALL   := $(HOME)/Applications/AirFocus.app
SOURCES   := $(shell find Sources -name '*.swift') $(shell find Support -type f) Package.swift scripts/build-app.sh

.PHONY: build test app run install clean reset-tcc

build:
	swift build

test:
	swift test

# Rebuilds and re-signs only when a source changed (each codesign may ask for keychain access).
app: $(APP_BIN)

$(APP_BIN): $(SOURCES)
	./scripts/build-app.sh

# Launch through LaunchServices so TCC attributes permissions to the app, not the terminal.
run: app
	-pkill -x AirFocus
	open "$(APP)"

install: app
	-pkill -x AirFocus
	mkdir -p "$(HOME)/Applications"
	rm -rf "$(INSTALL)"
	ditto "$(APP)" "$(INSTALL)"
	@echo "installed $(INSTALL)"

clean:
	rm -rf .build build

# Forget the Accessibility and Motion grants for this bundle id (after switching signing identity,
# or when System Settings shows the app enabled but it is not trusted). Only run this yourself.
reset-tcc:
	tccutil reset Accessibility $(BUNDLE_ID)
	tccutil reset Motion $(BUNDLE_ID)
