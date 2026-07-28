SHELL := /bin/zsh

.PHONY: generate build test install package clean

generate:
	xcodegen generate

build:
	./scripts/build.sh

test:
	./scripts/test.sh

install:
	./scripts/install-local.sh

package:
	./scripts/package-local.sh

clean:
	xcodebuild -project MojiPond.xcodeproj -scheme MojiPond -derivedDataPath DerivedData clean

