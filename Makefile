.PHONY: test lint build dev run clean

test: lint
	swift test

# Catches assertions that cannot fail. See the script for the toolchain bug.
lint:
	./Scripts/lint-tests.sh

build:
	./Scripts/build-app.sh

# Build, install to /Applications, and restart the app.
dev: build
	- pkill -x Sizeup2 || true
	rm -rf /Applications/Sizeup2.app
	cp -R build/Sizeup2.app /Applications/
	open /Applications/Sizeup2.app

run: build
	- pkill -x Sizeup2 || true
	open build/Sizeup2.app

clean:
	swift package clean
	rm -rf build
