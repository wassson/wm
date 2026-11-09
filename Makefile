.PHONY: build app run install test clean

# Command Line Tools (without Xcode) ships the swift-testing macro plugin in a
# subdirectory SwiftPM doesn't search, so point the compiler at it.
CLT_TESTING_PLUGINS := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
ifneq ($(wildcard $(CLT_TESTING_PLUGINS)),)
ifeq ($(findstring CommandLineTools,$(shell xcode-select -p)),CommandLineTools)
TEST_FLAGS := -Xswiftc -plugin-path -Xswiftc $(CLT_TESTING_PLUGINS)
endif
endif

build:
	swift build

app:
	./scripts/bundle.sh release

run: app
	open build/wm.app

# Build, copy to /Applications and relaunch. Use this while iterating.
install:
	./scripts/install.sh

test:
	swift test $(TEST_FLAGS)

clean:
	rm -rf .build build
