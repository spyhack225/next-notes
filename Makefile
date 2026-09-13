EXEC     := NextNotes
CONFIG   := debug

## Build products live OUTSIDE this directory, for the same reason the .app does.
##
## ~/Desktop is iCloud/file-provider synced, and the provider mutates files inside
## .build while the compiler is using them — producing "input file was modified during
## the build" on random object files, and occasionally a wedged swift-frontend stuck at
## 0% CPU. Moving the scratch path to ~/Library/Caches (never synced) removes the race.
SCRATCH  := $(HOME)/Library/Caches/NextNotesBuild/scratch
TEST_SCRATCH := $(HOME)/Library/Caches/NextNotesBuild/test-scratch
## Recursive, not `:=`, so a target-specific `CONFIG := release` actually changes
## which binary and framework get copied. Immediate expansion would bake `debug`
## in at parse time and `make release` would ship yesterday's debug build.
BUILD    = $(SCRATCH)/$(CONFIG)/$(EXEC)
LLAMA_FRAMEWORK = $(SCRATCH)/$(CONFIG)/llama.framework

## The bundle is assembled and signed OUTSIDE this directory on purpose.
##
## This tree lives under ~/Desktop, which is iCloud/file-provider synced. The provider
## stamps com.apple.FinderInfo onto files inside an .app faster than we can strip them,
## and codesign hard-refuses anything carrying them ("resource fork, Finder information,
## or similar detritus not allowed"). `xattr -cr` immediately before signing is not enough
## — the provider re-stamps in between. Staging in ~/Library/Caches sidesteps it entirely.
STAGE    := $(HOME)/Library/Caches/NextNotesBuild
APPNAME  := Next Notes.app
BUNDLE   := $(STAGE)/$(APPNAME)
CONTENTS := $(BUNDLE)/Contents

## TCC keys the Accessibility grant to the code signature, so an ad-hoc signature — which
## changes on every build — makes the user re-grant after every `make`. Signing with a
## stable Developer ID keeps the identity constant and the grant sticky. Falls back to
## ad-hoc ("-") on a machine without the cert.
LOCAL_SIGN_CN := Next Notes Local Signing

SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
             | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')

## Second choice: a stable self-signed certificate, created once by `make signing-cert`.
##
## This exists because ad-hoc ("-") is not merely unsigned, it is a *different identity on
## every build*: the signature is a hash of the binary, TCC stores a code-signing
## requirement next to each grant, and so Accessibility, Audio Recording and Notifications
## are all silently invalidated by every `make install`. The symptom lies — the toggle in
## System Settings still reads as on while the app is untrusted — and toggling it does not
## repair it, because the stored requirement is what is stale. A self-signed certificate is
## no more trusted than ad-hoc by Gatekeeper, but it is *constant*, so the grants stick.
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
             | grep "$(LOCAL_SIGN_CN)" | head -1 | sed -E 's/.*"(.*)".*/\1/')
endif

ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

## What kind of identity we landed on. The release path uses this to decide whether a
## secure timestamp and the stricter entitlements file are legal: both assume a real
## Developer ID. A local or ad-hoc signature must keep `disable-library-validation`
## and `--timestamp=none`, or the bundled llama.framework will not load.
SIGN_KIND := adhoc
ifneq ($(findstring Developer ID Application,$(SIGN_ID)),)
SIGN_KIND := developer-id
else ifneq ($(SIGN_ID),-)
SIGN_KIND := local
endif

TIMESTAMP    := --timestamp=none
ENTITLEMENTS := Resources/$(EXEC).entitlements
STAMP_VERSION :=

## Disk image for GitHub Releases. The versioned name is what a human reads on the
## release page; `NextNotes.dmg` is the stable URL the website downloads from
## (`…/releases/latest/download/NextNotes.dmg`). Both are the same bytes.
## Do not use `$(...)` or `#` inside `$(shell ...)`. Make treats the first `)` as the
## end of the function and `#` as the start of a comment, which is how the first
## version of this line failed to parse.
VERSION ?= $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
ifeq ($(strip $(VERSION)),)
VERSION := 0.1.0
endif
BUILD_NUMBER ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
DMG_STAGE    := $(STAGE)/dmg-root
DMG          := $(STAGE)/NextNotes-$(VERSION).dmg
DMG_STABLE   := $(STAGE)/NextNotes.dmg

.PHONY: all build test app run install clean icon signing-cert release dmg

all: app

build:
	swift build -c $(CONFIG) --scratch-path "$(SCRATCH)"

## Two suites, named explicitly rather than matched by one regex.
##
## --filter takes a regex, and a single pattern loose enough to catch both would also catch
## whatever gets added next — or miss it. Worse, a suite accidentally named
## SpokenFormsVectorTests would be swept up by "VectorTests" alone and appear to run until
## the day somebody renamed it. Each suite gets its own flag; SwiftPM ORs them.
test:
	swift test --scratch-path "$(TEST_SCRATCH)" --filter VectorTests --filter SpokenFormsTests

## Regenerates AppIcon.icns from Tools/makeicon.swift. Not a dependency of `app` — the
## icon rarely changes and rendering 10 PNGs on every build is wasted time.
## Compiled with `OrbGeometry.swift` rather than run as a script, so the mark *is* the orb
## the app animates — same generator, same tuned constants — instead of a drawing of it that
## silently goes stale. `OrbGeometry` imports only CoreGraphics and Foundation and touches no
## `DS` token, which is what makes this possible.
icon:
	@swiftc -O -o "$(SCRATCH)/makeicon" \
		Tools/makeicon.swift \
		Sources/NextNotes/UI/Components/ThinkingOrbs/OrbGeometry.swift
	@"$(SCRATCH)/makeicon"
	@iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "wrote Resources/AppIcon.icns"

## Assemble a real .app bundle. TCC (microphone + Accessibility) keys on bundle identity
## and code signature, so the raw SwiftPM binary can't be used directly.
app: build
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources" "$(CONTENTS)/Frameworks"
	@cp $(BUILD) "$(CONTENTS)/MacOS/$(EXEC)"
	@cp -R "$(LLAMA_FRAMEWORK)" "$(CONTENTS)/Frameworks/"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"; fi
	@# The Workspace CLI installer the Settings tab opens in Terminal. A resource rather
	@# than a string in Swift so the commands the user is asked to run are reviewable as a
	@# script; the app falls back to a one-line equivalent when running outside a bundle.
	@cp Resources/install-gws.sh "$(CONTENTS)/Resources/"
	@chmod +x "$(CONTENTS)/Resources/install-gws.sh"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@# Belt and braces: the staging dir isn't synced, but the copied binary can still carry
	@# xattrs inherited from the synced .build directory.
	@xattr -cr "$(BUNDLE)"
	@install_name_tool -add_rpath "@executable_path/../Frameworks" "$(CONTENTS)/MacOS/$(EXEC)"
	@if [ "$(STAMP_VERSION)" = "1" ]; then \
		/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" "$(CONTENTS)/Info.plist"; \
		/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" "$(CONTENTS)/Info.plist"; \
		echo "stamped $(VERSION) ($(BUILD_NUMBER))"; \
	fi
	@codesign --force --sign "$(SIGN_ID)" --options runtime $(TIMESTAMP) \
		"$(CONTENTS)/Frameworks/llama.framework"
	@codesign --force --sign "$(SIGN_ID)" \
		--entitlements "$(ENTITLEMENTS)" \
		--options runtime \
		$(TIMESTAMP) \
		"$(BUNDLE)"
	@echo "built $(BUNDLE)  [signed: $(SIGN_ID)]"

## Only ever targets the Next Notes executable.
run: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@open "$(BUNDLE)"

## Ad-hoc signatures change on every rebuild, which resets the Accessibility grant.
## Installing to /Applications keeps the path stable and makes re-granting a one-click fix.
install: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@# $(BUNDLE) is an absolute staging path — the destination must use $(APPNAME) alone.
	@rm -rf "/Applications/$(APPNAME)"
	@cp -R "$(BUNDLE)" "/Applications/$(APPNAME)"
	@open "/Applications/$(APPNAME)"
	@echo "installed to /Applications/$(APPNAME)"

## Release configuration of the same bundle `make app` builds. Stamps the version from
## the current git tag (or 0.1.0 if there isn't one). Does not pass `-DPAID_BUILD` —
## that flag is the paid-product boundary in docs/PAID-RELEASE.md, and a source-built
## or GitHub-hosted DMG is still the free app.
##
## A Developer ID switches on a secure timestamp and drops `disable-library-validation`,
## because both halves are then signed with the same Team ID. Without one, this is a
## release-optimized binary that Gatekeeper will still refuse to open from a download.
release: CONFIG := release
release: STAMP_VERSION := 1
ifeq ($(SIGN_KIND),developer-id)
release: TIMESTAMP := --timestamp
release: ENTITLEMENTS := Resources/$(EXEC).release.entitlements
endif
release: app

## Wrap the release bundle in a drag-to-Applications disk image. The image lives under
## ~/Library/Caches, not in the repo — committing a 50 MB binary per tag would bloat
## git permanently; GitHub Releases is where it is published.
dmg: release
	@rm -rf "$(DMG_STAGE)"
	@mkdir -p "$(DMG_STAGE)"
	@cp -R "$(BUNDLE)" "$(DMG_STAGE)/"
	@ln -s /Applications "$(DMG_STAGE)/Applications"
	@rm -f "$(DMG)" "$(DMG_STABLE)"
	@hdiutil create \
		-srcfolder "$(DMG_STAGE)" \
		-volname "Next Notes" \
		-fs HFS+ \
		-format UDZO \
		-ov \
		"$(DMG)"
	@cp "$(DMG)" "$(DMG_STABLE)"
	@shasum -a 256 "$(DMG)" | awk '{print $$1 "  NextNotes-$(VERSION).dmg"}' > "$(DMG).sha256"
	@if [ "$(SIGN_KIND)" = "developer-id" ]; then \
		codesign --force --sign "$(SIGN_ID)" --timestamp "$(DMG)"; \
		codesign --force --sign "$(SIGN_ID)" --timestamp "$(DMG_STABLE)"; \
	fi
	@echo "built $(DMG)"
	@ls -lh "$(DMG)"
	@cat "$(DMG).sha256"

## Creates the stable self-signed certificate the signing block above looks for.
##
## Run once per machine. It is additive and reversible: delete "Next Notes Local Signing"
## from Keychain Access to undo it. Gatekeeper trusts it no more than ad-hoc — the point is
## only that it does not change between builds, so a TCC grant given once keeps applying.
signing-cert:
	@if security find-identity -v -p codesigning | grep -q "$(LOCAL_SIGN_CN)"; then \
		echo "already present: $(LOCAL_SIGN_CN)"; \
	else \
		echo "Creating a self-signed code-signing certificate."; \
		echo "Keychain Access will open. Choose:"; \
		echo "  Certificate Type: Code Signing"; \
		echo "  Name:             $(LOCAL_SIGN_CN)"; \
		echo "  Let me override defaults: not needed"; \
		open -a "Certificate Assistant" 2>/dev/null || \
		  open "/System/Library/CoreServices/Applications/Certificate Assistant.app" 2>/dev/null || \
		  echo "Open Keychain Access > Certificate Assistant > Create a Certificate."; \
	fi

clean:
	@rm -rf .build "$(STAGE)" "$(SCRATCH)"
