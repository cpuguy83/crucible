.PHONY: build test clean format lint project app run app-path dist release-archive release-zip notarize staple

APP_NAME := Crucible
SCHEME := Crucible
CONFIGURATION ?= Debug
DERIVED_DATA := build/DerivedData
APP_PATH := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app
DIST_DIR := build/dist
ZIP_PATH := $(DIST_DIR)/$(APP_NAME).zip

# Release signing knobs. Set these in the environment when producing a public
# build, for example:
#   DEVELOPER_ID_APPLICATION="Developer ID Application: Example (TEAMID)"
#   NOTARY_PROFILE="notarytool-keychain-profile"
DEVELOPER_ID_APPLICATION ?=
NOTARY_PROFILE ?=

# SwiftPM library + test build (no app).
build:
	swift build

test:
	swift test

# Regenerate Crucible.xcodeproj from project.yml.
project:
	@command -v xcodegen >/dev/null || { echo "xcodegen not installed: brew install xcodegen"; exit 1; }
	xcodegen generate

# Build the macOS app bundle via xcodebuild.
app: project
	xcodebuild -project Crucible.xcodeproj -scheme $(SCHEME) -configuration $(CONFIGURATION) \
	    -derivedDataPath $(DERIVED_DATA) build

# Print the path to the built .app.
app-path:
	@echo $(APP_PATH)

# Build a local distributable zip. This uses ad-hoc signing unless the Xcode
# project is configured with a real signing identity.
dist: app
	mkdir -p $(DIST_DIR)
	ditto -c -k --keepParent $(APP_PATH) $(ZIP_PATH)

release-archive: project
	@test -n "$(DEVELOPER_ID_APPLICATION)" || { echo "Set DEVELOPER_ID_APPLICATION"; exit 1; }
	xcodebuild -project Crucible.xcodeproj -scheme $(SCHEME) -configuration Release \
	    -derivedDataPath $(DERIVED_DATA) \
	    CODE_SIGN_IDENTITY="$(DEVELOPER_ID_APPLICATION)" \
	    build

release-zip: release-archive
	mkdir -p $(DIST_DIR)
	ditto -c -k --keepParent $(DERIVED_DATA)/Build/Products/Release/$(APP_NAME).app $(ZIP_PATH)

notarize: release-zip
	@test -n "$(NOTARY_PROFILE)" || { echo "Set NOTARY_PROFILE"; exit 1; }
	xcrun notarytool submit $(ZIP_PATH) --keychain-profile "$(NOTARY_PROFILE)" --wait

staple: notarize
	xcrun stapler staple $(DERIVED_DATA)/Build/Products/Release/$(APP_NAME).app

# Build then launch.
run: app
	open $(APP_PATH)

clean:
	swift package clean
	rm -rf .build build

format:
	@command -v swift-format >/dev/null || { echo "swift-format not installed"; exit 1; }
	swift-format -i -r Sources Tests Apps

lint:
	@command -v swift-format >/dev/null || { echo "swift-format not installed"; exit 1; }
	swift-format lint -r Sources Tests Apps
