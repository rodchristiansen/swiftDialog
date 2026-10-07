#!/usr/bin/make -f
#
# Managed Notifications Dialog build
# Builds the app bundle and an installer package. With SIGNING_IDENTITY_APP and
# SIGNING_IDENTITY_PKG set it signs both; without them it builds unsigned, as the
# public release does. The app runs the installed `dialog` as the signed-in
# user, so there is no privileged helper to install.
#

-include .env
export

# One build stamp, YYYY.MM.DD.HHMM, split for the About box as 2026.10.06 (1342).
VERSION := $(or $(VERSION),$(shell date '+%Y.%m.%d.%H%M'))
MARKETING_VERSION := $(shell echo $(VERSION) | sed 's/\.[^.]*$$//')
BUILD_NUMBER := $(shell echo $(VERSION) | sed 's/.*\.//')

BUILD_DIR = build
PKG_ROOT = $(BUILD_DIR)/pkg-root
APP_BUNDLE_PATH = Applications/Utilities/Managed Notifications Dialog.app
APP_CONTENTS = $(PKG_ROOT)/$(APP_BUNDLE_PATH)/Contents
GUI_BINARY_NAME = ManagedNotificationsDialog
APP_IDENTIFIER = au.csiro.dialog.gui

# The output path differs between toolchains, so ask SwiftPM for it.
SWIFT_BUILD_DIR = $(shell swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
ICON_SOURCE = ../dialog/Assets.xcassets/AppIcon.appiconset
ICONSET = $(BUILD_DIR)/ManagedNotificationsDialog.iconset

PKG_ID = au.csiro.dialog.gui
PKG_OUTPUT = $(BUILD_DIR)/ManagedNotificationsDialog-$(VERSION).pkg

.PHONY: all build test app pkg notarize verify clean

all: pkg

# Record the SDK the binaries are linked against. Some toolchains write the
# deployment target as the SDK version, and AppKit then keeps the pre-macOS 26
# window chrome (a title bar plus a small tab strip) instead of the toolbar tabs.
SDK_VERSION := $(shell xcrun --show-sdk-version)
# The version is stamped after linking with vtool, because linker flags passed
# through a universal SwiftPM build reach clang without -Xlinker on some Xcodes.
DEPLOYMENT_TARGET = 14.0

build:
	swift build -c release --arch arm64 --arch x86_64

test:
	swift test

app: build
	@rm -rf "$(PKG_ROOT)" "$(ICONSET)"
	@mkdir -p "$(APP_CONTENTS)/MacOS" "$(APP_CONTENTS)/Resources" "$(ICONSET)"
	@cp "$(SWIFT_BUILD_DIR)/ManagedNotificationsDialogApp" "$(APP_CONTENTS)/MacOS/$(GUI_BINARY_NAME)"
	@chmod 755 "$(APP_CONTENTS)/MacOS/"*
	@for bin in "$(APP_CONTENTS)/MacOS/"*; do \
		vtool -set-build-version macos $(DEPLOYMENT_TARGET) $(SDK_VERSION) -replace -output "$$bin.stamped" "$$bin" && \
		mv "$$bin.stamped" "$$bin" && codesign --force --sign - "$$bin" 2>/dev/null; \
	done
	@sed -e 's/{{MARKETING_VERSION}}/$(MARKETING_VERSION)/g' \
	     -e 's/{{BUILD_NUMBER}}/$(BUILD_NUMBER)/g' \
	     packaging/resources/Info.plist.template > "$(APP_CONTENTS)/Info.plist"
	@for png in "$(ICON_SOURCE)"/swiftDialog-macOS-Default-*.png; do \
		size=$$(basename "$$png" | sed -E 's/.*-([0-9]+x[0-9]+)@([12])x\.png/\1 \2/'); \
		set -- $$size; \
		if [ "$$2" = "2" ]; then name="icon_$$1@2x.png"; else name="icon_$$1.png"; fi; \
		[ "$$1" = "1024x1024" ] && name="icon_512x512@2x.png"; \
		cp "$$png" "$(ICONSET)/$$name"; \
	done
	@iconutil -c icns "$(ICONSET)" -o "$(APP_CONTENTS)/Resources/ManagedNotificationsDialog.icns"
ifneq ($(SIGNING_IDENTITY_APP),)
	@codesign --force --sign "$(SIGNING_IDENTITY_APP)" --options runtime --timestamp \
		--identifier $(APP_IDENTIFIER) "$(PKG_ROOT)/$(APP_BUNDLE_PATH)"
	@echo "Signed app bundle"
else
	@echo "SIGNING_IDENTITY_APP not set: app bundle left unsigned"
endif

pkg: app
	@pkgbuild --analyze --root "$(PKG_ROOT)" "$(BUILD_DIR)/component.plist"
	@/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$(BUILD_DIR)/component.plist" 2>/dev/null \
		|| /usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$(BUILD_DIR)/component.plist"
	@/usr/libexec/PlistBuddy -c "Set :0:BundleIsVersionChecked false" "$(BUILD_DIR)/component.plist"
	@pkgbuild --root "$(PKG_ROOT)" --component-plist "$(BUILD_DIR)/component.plist" \
		--identifier $(PKG_ID) --version $(VERSION) --scripts packaging/scripts \
		"$(BUILD_DIR)/component.pkg"
ifneq ($(SIGNING_IDENTITY_PKG),)
	@productbuild --package "$(BUILD_DIR)/component.pkg" --identifier $(PKG_ID) --version $(VERSION) \
		--sign "$(SIGNING_IDENTITY_PKG)" --timestamp "$(PKG_OUTPUT)"
else
	@productbuild --package "$(BUILD_DIR)/component.pkg" --identifier $(PKG_ID) --version $(VERSION) "$(PKG_OUTPUT)"
endif
	@rm -f "$(BUILD_DIR)/component.pkg"
	@echo "Built $(PKG_OUTPUT)"

# Notarize and staple the signed package. Needs a notarytool keychain profile
# in NOTARIZATION_PROFILE.
notarize: pkg
ifeq ($(NOTARIZATION_PROFILE),)
	@echo "NOTARIZATION_PROFILE not set: cannot notarize" && exit 1
endif
	@xcrun notarytool submit "$(PKG_OUTPUT)" --keychain-profile "$(NOTARIZATION_PROFILE)" --wait
	@xcrun stapler staple "$(PKG_OUTPUT)"
	@echo "Notarized and stapled $(PKG_OUTPUT)"

verify:
	@pkgutil --check-signature "$(PKG_OUTPUT)"
	@spctl --assess --type install --verbose "$(PKG_OUTPUT)"
	@codesign --verify --strict --verbose=2 "$(PKG_ROOT)/$(APP_BUNDLE_PATH)"

clean:
	@rm -rf $(BUILD_DIR) .build
