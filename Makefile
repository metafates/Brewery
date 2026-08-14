SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -ec

# Expanded at recipe time, so the target-specific CONFIG applies.
APP_DIR = $(shell xcodebuild -project Brewery.xcodeproj -scheme Brewery -configuration $(CONFIG) -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $$3}')

.PHONY: run install

run: CONFIG := Debug
run:
	xcodebuild -project Brewery.xcodeproj -scheme Brewery -configuration $(CONFIG) build | xcbeautify
	open "$(APP_DIR)/Brewery.app"

install: CONFIG := Release
install:
	xcodebuild -project Brewery.xcodeproj -scheme Brewery -configuration $(CONFIG) build | xcbeautify
	rm -rf /Applications/Brewery.app
	ditto "$(APP_DIR)/Brewery.app" /Applications/Brewery.app
