APP := build/DerivedData/Build/Products/Debug/Cortes.app
IDENTITY ?= Cortes Local Signing
VERSION ?= 0.1.0
SPARKLE_PUBLIC_KEY ?=
RELEASE_APP := build/Release/Build/Products/Release/Cortes.app
SPARKLE_TOOLS := build/Release/SourcePackages/artifacts/sparkle/Sparkle/bin
DMGBUILD ?= build/dmg-tools/bin/dmgbuild

.PHONY: build run demo test release-build dmg-tools package appcast signing-identity

# Builds ad-hoc, then re-signs with a stable local identity when one exists. A stable signature keeps the
# Accessibility grant across rebuilds; ad-hoc builds lose it every time.
build:
	xcodebuild -project Cortes.xcodeproj -scheme Cortes -configuration Debug -derivedDataPath build/DerivedData build -quiet SPARKLE_PUBLIC_KEY="$(SPARKLE_PUBLIC_KEY)"
	@if security find-certificate -c "$(IDENTITY)" >/dev/null 2>&1; then \
		for lib in "$(APP)"/Contents/MacOS/*.dylib; do codesign --force --sign "$(IDENTITY)" "$$lib" || exit 1; done; \
		codesign --force --entitlements App/Cortes.entitlements --sign "$(IDENTITY)" "$(APP)" && echo "signed with $(IDENTITY)"; \
	else \
		echo "warning: no '$(IDENTITY)' identity, so the build stays ad-hoc signed and loses Accessibility on every rebuild (run: make signing-identity)"; \
	fi

run: build
	-pkill -x Cortes
	open "$(APP)"

demo: build
	-pkill -x Cortes
	open "$(APP)" --args --demo

test:
	swift test --package-path Packages/CortesKit

# Distribution builds never use the developer's local signing identity.
release-build:
	xcodebuild -project Cortes.xcodeproj -scheme Cortes -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/Release build -quiet ARCHS=arm64 ONLY_ACTIVE_ARCH=NO DEAD_CODE_STRIPPING=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS=CORTES_DISTRIBUTION CODE_SIGN_IDENTITY=- MARKETING_VERSION="$(VERSION)" CURRENT_PROJECT_VERSION="$(VERSION)" SPARKLE_PUBLIC_KEY="$(SPARKLE_PUBLIC_KEY)"
	swift scripts/prepare-release.swift "$(RELEASE_APP)"
	codesign --force --sign - "$(RELEASE_APP)/Contents/Resources/CortesKit_CortesKit.bundle"
	codesign --force --entitlements App/Cortes.entitlements --sign - "$(RELEASE_APP)"

build/dmg-tools/bin/dmgbuild: .github/dmg-requirements.txt
	python3 -m venv build/dmg-tools
	build/dmg-tools/bin/python -m pip install --disable-pip-version-check -r .github/dmg-requirements.txt

dmg-tools: build/dmg-tools/bin/dmgbuild

package: release-build dmg-tools
	build/dmg-tools/bin/python scripts/test_dmg.py
	DMGBUILD="$(DMGBUILD)" bash scripts/package-app.sh "$(VERSION)" "$(RELEASE_APP)"
	build/dmg-tools/bin/python scripts/verify-dmg.py "dist/cortes-$(VERSION)-macos-arm64.dmg" "$(VERSION)"

appcast:
	bash scripts/make-appcast.sh "$(VERSION)" "$(RELEASE_APP)" "$(SPARKLE_TOOLS)"

# One-time: a self-signed code signing certificate in the login keychain, used only on this Mac.
# Remove it with: security delete-identity -c "Cortes Local Signing"
signing-identity:
	@if security find-certificate -c "$(IDENTITY)" >/dev/null 2>&1; then echo "'$(IDENTITY)' already exists"; exit 0; fi; \
	dir=$$(mktemp -d) && trap 'rm -rf "$$dir"' EXIT && \
	openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -keyout "$$dir/key.pem" -out "$$dir/cert.pem" \
		-subj "/CN=$(IDENTITY)" -addext "basicConstraints=critical,CA:false" \
		-addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" && \
	openssl pkcs12 -export -inkey "$$dir/key.pem" -in "$$dir/cert.pem" -name "$(IDENTITY)" \
		-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -out "$$dir/id.p12" -passout pass:transient && \
	security import "$$dir/id.p12" -k "$$HOME/Library/Keychains/login.keychain-db" -P transient -T /usr/bin/codesign
