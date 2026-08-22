.PHONY: test lint build dev run clean

test: lint
	swift test

# Two invariants that reviews used to check by hand. See each script for why.
lint:
	./Scripts/lint-tests.py
	./Scripts/lint-layering.py

build:
	./Scripts/build-app.sh

# Build, install to /Applications, and restart the app.
dev: build
	- pkill -x ClipShot || true
	rm -rf /Applications/ClipShot.app
	cp -R build/ClipShot.app /Applications/
	open /Applications/ClipShot.app

run: build
	- pkill -x ClipShot || true
	open build/ClipShot.app

clean:
	swift package clean
	rm -rf build
