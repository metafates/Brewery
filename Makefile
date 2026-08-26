SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -ec

# Expanded at recipe time, so the target-specific CONFIG applies.
APP_DIR = $(shell xcodebuild -project Brewery.xcodeproj -scheme Brewery -configuration $(CONFIG) -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $$3}')

# Distribution builds go here, not into DerivedData: they sign ad-hoc, and that
# identity must not leak into the everyday build, which signs with the dev cert.
DIST := dist
DIST_APP := $(DIST)/Brewery.app
VERSION = $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $(DIST_APP)/Contents/Info.plist)

.PHONY: run install test test-ui app dmg clean

test:
	xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests | xcbeautify

# Launches the app repeatedly and needs automation permission; the perf pins want a rested machine.
test-ui:
	xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryUITests | xcbeautify

run: CONFIG := Debug
run:
	xcodebuild -project Brewery.xcodeproj -scheme Brewery -configuration $(CONFIG) build | xcbeautify
	open "$(APP_DIR)/Brewery.app"

install: CONFIG := Release
install:
	xcodebuild -project Brewery.xcodeproj -scheme Brewery -configuration $(CONFIG) build | xcbeautify
	rm -rf /Applications/Brewery.app
	ditto "$(APP_DIR)/Brewery.app" /Applications/Brewery.app

# Universal (arm64 + x86_64), signed ad-hoc: valid on any Mac, but there is no
# Developer ID certificate to notarize with, so Gatekeeper still sends the first
# launch through System Settings > Privacy & Security > Open Anyway.
app:
	xcodebuild -project Brewery.xcodeproj -scheme Brewery -configuration Release \
		-destination 'generic/platform=macOS' -derivedDataPath build \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
		CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
		build | xcbeautify
	mkdir -p $(DIST)
	rm -rf $(DIST_APP)
	ditto build/Build/Products/Release/Brewery.app $(DIST_APP)

# Plain drag-to-install disk image: the app beside a symlink to /Applications.
dmg: app
	rm -rf $(DIST)/stage
	mkdir -p $(DIST)/stage
	ditto $(DIST_APP) $(DIST)/stage/Brewery.app
	ln -s /Applications $(DIST)/stage/Applications
	hdiutil create -volname 'Brewery $(VERSION)' -srcfolder $(DIST)/stage -ov -format UDZO $(DIST)/Brewery-$(VERSION).dmg
	rm -rf $(DIST)/stage

clean:
	rm -rf build $(DIST)
