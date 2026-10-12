.PHONY: project open test clean

# Xcode projesini project.yml'den üretir (XcodeGen yoksa Homebrew ile kurar).
project:
	@command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
	xcodegen generate

open: project
	open PadTrack.xcodeproj

# Jest motoru, protokol ve web sunucusu testleri (Xcode gerekli) + Safari sayfası testleri (Node varsa).
test:
	swift test --package-path Packages/PadTrackCore
	@if command -v node >/dev/null 2>&1; then node --test WebClientTests/*.test.mjs; \
	else echo "Node.js yok: Safari sayfası testleri atlandı (brew install node)"; fi

clean:
	rm -rf PadTrack.xcodeproj Packages/PadTrackCore/.build build
