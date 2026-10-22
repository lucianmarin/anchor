APP_NAME = Anchor
BUNDLE_DIR = $(APP_NAME).app
CONTENTS_DIR = $(BUNDLE_DIR)/Contents
MACOS_DIR = $(CONTENTS_DIR)/MacOS
RESOURCES_DIR = $(CONTENTS_DIR)/Resources

.PHONY: build app run test clean

build:
	swift build -c release

app: build
	mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)"
	cp ".build/release/$(APP_NAME)" "$(MACOS_DIR)/$(APP_NAME)"
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'    <key>CFBundleExecutable</key>' \
		'    <string>Anchor</string>' \
		'    <key>CFBundleIdentifier</key>' \
		'    <string>com.lucianmarin.Anchor</string>' \
		'    <key>CFBundleName</key>' \
		'    <string>Anchor</string>' \
		'    <key>CFBundlePackageType</key>' \
		'    <string>APPL</string>' \
		'    <key>CFBundleShortVersionString</key>' \
		'    <string>1.0.0</string>' \
		'    <key>CFBundleVersion</key>' \
		'    <string>1</string>' \
		'    <key>LSMinimumSystemVersion</key>' \
		'    <string>13.0</string>' \
		'    <key>LSUIElement</key>' \
		'    <true/>' \
		'    <key>NSHighResolutionCapable</key>' \
		'    <true/>' \
		'</dict>' \
		'</plist>' > "$(CONTENTS_DIR)/Info.plist"
	codesign --force --deep --sign - "$(BUNDLE_DIR)"

run: app
	open "$(BUNDLE_DIR)"

test:
	swift test

clean:
	swift package clean
	rm -rf "$(BUNDLE_DIR)"
