APP_NAME  := MAUMuzzle
BUNDLE_ID := com.camurphy.mau-muzzle
BUILD     := build
BIN       := $(BUILD)/$(APP_NAME)
APP_BUILT := $(BUILD)/$(APP_NAME).app
APP       := $(HOME)/Applications/$(APP_NAME).app
PLIST     := $(HOME)/Library/LaunchAgents/$(BUNDLE_ID).plist
UID_N     := $(shell id -u)
NOTARY_PROFILE ?= mau-muzzle

# Marketing version comes from the latest tag (v0.0.1 -> 0.0.1); build number is
# the commit count, which is monotonic and numeric as CFBundleVersion wants.
# CI must check out with fetch-depth: 0 or neither is visible.
SHORT_VERSION ?= $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
ifeq ($(strip $(SHORT_VERSION)),)
SHORT_VERSION := 0.0.0
endif
BUILD_VERSION ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

# Prefer a Developer ID identity; it is required to notarize a downloadable build.
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $$2; exit}')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

# Hardened runtime + secure timestamp are required for notarization, but are
# not valid for ad-hoc signing.
ifeq ($(SIGN_ID),-)
CODESIGN_EXTRA :=
else
CODESIGN_EXTRA := --options runtime --timestamp
endif

INFO_PLIST := <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleName</key><string>$(APP_NAME)</string><key>CFBundleDisplayName</key><string>$(APP_NAME)</string><key>CFBundleIdentifier</key><string>$(BUNDLE_ID)</string><key>CFBundleExecutable</key><string>$(APP_NAME)</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>$(BUILD_VERSION)</string><key>CFBundleShortVersionString</key><string>$(SHORT_VERSION)</string><key>LSUIElement</key><true/></dict></plist>

.PHONY: all build app sign-info install status selftest uninstall notarize clean

all: app

sign-info:
	@echo "signing identity: $(SIGN_ID)"
	@echo "version: $(SHORT_VERSION) (build $(BUILD_VERSION))"

build: $(BIN)

$(BIN): $(APP_NAME).swift
	@mkdir -p $(BUILD)
	swiftc -O -o $(BIN) $(APP_NAME).swift -framework AppKit
	@echo "built $(BIN)"

## Assemble and sign the bundle under build/. Does not touch ~/Applications.
app: build
	@rm -rf "$(APP_BUILT)"
	@mkdir -p "$(APP_BUILT)/Contents/MacOS"
	@cp $(BIN) "$(APP_BUILT)/Contents/MacOS/$(APP_NAME)"
	@chmod +x "$(APP_BUILT)/Contents/MacOS/$(APP_NAME)"
	@printf '%s' '$(INFO_PLIST)' > "$(APP_BUILT)/Contents/Info.plist"
	@plutil -lint "$(APP_BUILT)/Contents/Info.plist" >/dev/null
	codesign --force --sign "$(SIGN_ID)" $(CODESIGN_EXTRA) "$(APP_BUILT)"
	@codesign -dv "$(APP_BUILT)" 2>&1 | grep -E "Identifier|Authority|Signature" || true
	@echo "assembled $(APP_BUILT)"

## Zip, submit to Apple, staple the ticket. Only needed if the app will be
## downloaded (a download gets quarantined; a local build does not).
## Set up once with: xcrun notarytool store-credentials $(NOTARY_PROFILE)
notarize: app
	@ditto -c -k --keepParent "$(APP_BUILT)" "$(BUILD)/$(APP_NAME).zip"
	xcrun notarytool submit "$(BUILD)/$(APP_NAME).zip" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(APP_BUILT)"
	@echo "notarized and stapled"

## The app installs itself: it copies to ~/Applications and loads the
## LaunchAgent. Equivalent to just double-clicking the .app.
install: app
	@"$(APP_BUILT)/Contents/MacOS/$(APP_NAME)" --install

selftest: build
	@$(BIN) --selftest

status:
	@"$(APP)/Contents/MacOS/$(APP_NAME)" --status 2>/dev/null || echo "app not installed"
	@launchctl print gui/$(UID_N)/$(BUNDLE_ID) 2>/dev/null | grep -E "state =|program =" | head -2 || echo "agent not loaded"
	@tail -5 "$(HOME)/Library/Application Support/mau-muzzle/muzzle.log" 2>/dev/null || true

uninstall:
	@launchctl bootout gui/$(UID_N) "$(PLIST)" 2>/dev/null || true
	@rm -f "$(PLIST)"
	@rm -rf "$(APP)"
	@echo "removed app and LaunchAgent"

clean:
	@rm -rf $(BUILD)
