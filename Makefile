.PHONY: project open test clean

# Xcode projesini project.yml'den üretir (XcodeGen yoksa Homebrew ile kurar).
project:
	@command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
	xcodegen generate

open: project
	open PadTrack.xcodeproj

# Jest motoru ve protokol testleri (Xcode gerekli).
test:
	swift test --package-path Packages/PadTrackCore

clean:
	rm -rf PadTrack.xcodeproj Packages/PadTrackCore/.build
