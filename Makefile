.PHONY: build test test-planning package clean

build:
	swift build

test:
	swift test

test-planning:
	swift test --filter "EncodePlanner|BloatGuard|CRFLadder|AudioRules|ContainerRules|PathSupport|ProgressParser"

package:
	./package.sh

clean:
	rm -rf .build dist
