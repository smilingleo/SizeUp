.PHONY: test build dev run clean

test:
	swift test

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
