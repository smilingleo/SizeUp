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
