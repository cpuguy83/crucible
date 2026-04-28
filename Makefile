.PHONY: build test clean format lint project app run app-path

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
	xcodebuild -project Crucible.xcodeproj -scheme Crucible -configuration Debug \
	    -derivedDataPath build/DerivedData build

# Print the path to the built .app.
app-path:
	@echo build/DerivedData/Build/Products/Debug/Crucible.app

# Build then launch.
run: app
	open build/DerivedData/Build/Products/Debug/Crucible.app

clean:
	swift package clean
	rm -rf .build build

format:
	@command -v swift-format >/dev/null || { echo "swift-format not installed"; exit 1; }
	swift-format -i -r Sources Tests Apps

lint:
	@command -v swift-format >/dev/null || { echo "swift-format not installed"; exit 1; }
	swift-format lint -r Sources Tests Apps
