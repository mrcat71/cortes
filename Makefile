APP := build/DerivedData/Build/Products/Debug/Cortes.app
IDENTITY ?= Cortes Local Signing

.PHONY: build run demo test signing-identity

# Builds ad-hoc, then re-signs with a stable local identity when one exists. A stable signature keeps the
# Accessibility grant across rebuilds; ad-hoc builds lose it every time.
build:
	xcodebuild -project Cortes.xcodeproj -scheme Cortes -configuration Debug -derivedDataPath build/DerivedData build -quiet
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
