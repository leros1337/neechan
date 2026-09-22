# Neechan build tasks.
#
# `make gen` regenerates Neechan.xcodeproj from project.yml (the project file is
# not committed). Everything else assumes it exists.

SHELL := /bin/bash
# xcodebuild is piped through a formatter below, and a pipeline reports only
# its last command's status: without this a failed build would be hidden by a
# formatter that read it happily and exited 0.
.SHELLFLAGS := -o pipefail -c

# Recursively expanded: the App Store configuration has a scheme of its own,
# because its test action leaves out the unit bundle that needs testability.
SCHEME       = $(if $(filter $(APPSTORE),$(CONFIGURATION)),Neechan (App Store),Neechan)
SIMULATOR   := iPhone 17 Pro
# The baseline iPad, not a Pro: it is the narrowest of them, so a layout that
# only just fits shows its seams here first.
IPAD        := iPad (A16)
DUO         := iPhone Duo
DUO_OS      := 27.1
# Pinned to one runtime: several Xcode versions can be installed side by side,
# and a bare device name then matches one simulator per runtime, which
# xcodebuild refuses as ambiguous.
SIM_OS      := 26.5
# Recursively expanded on purpose: `make ipad` overrides SIMULATOR for its own
# targets, and an immediate assignment here would bake the iPhone in and build
# for the wrong device while installing on the right one.
# Set to a UDID to address one simulator exactly, which a name cannot always
# do: a runtime is allowed to carry two devices of the same name -- the iOS
# 27.1 runtime ships two called "iPhone Duo" -- and xcodebuild refuses that as
# ambiguous just as it refuses a name that spans runtimes. Empty by default, so
# every other target keeps naming its device and reads the same as before.
SIM_ID      ?=
comma       := ,
DESTINATION = platform=iOS Simulator$(comma)$(if $(SIM_ID),id=$(SIM_ID),name=$(SIMULATOR)$(comma)OS=$(SIM_OS))
# Debug by default; `make sim CONFIGURATION=Release` builds an optimised app,
# which is the only kind worth measuring: Debug SwiftUI re-renders more and
# unoptimised Swift distorts every CPU figure.
CONFIGURATION ?= Debug
# Recursively expanded, and only suffixed away from Debug, so the default paths
# are unchanged and a Release build does not fight the Debug one over the same
# module cache.
DERIVED      = .build/DerivedData$(if $(filter-out Debug,$(CONFIGURATION)),-$(CONFIGURATION),)
RESULTS     := .build/TestResults.xcresult
# Shared SwiftPM clone cache, so dependencies are not re-fetched every time
# DerivedData is wiped.
SPM_CACHE   := $(HOME)/Library/Caches/org.swift.swiftpm-neechan
# No -quiet: its output filter swallows a compile task's diagnostics and then
# reports the task as "failed with exit code 0 but produced no further output",
# which fails a build that succeeded -- a warning in a whole-module release
# build is enough to trigger it. xcbeautify reads the whole log instead and
# prints the warnings and nothing else. Empty when it is not installed, which
# leaves the raw log rather than a broken pipeline.
BEAUTIFY    := $(if $(shell command -v xcbeautify),| xcbeautify --quieter,)
# ONLY_ACTIVE_ARCH here and not in `ipa`: a simulator on this machine runs
# arm64 and nothing else, while the release configurations carry no such
# setting and would otherwise build x86_64 too -- half a build thrown away,
# and the source of the linker's complaints about FFmpeg's x86_64 slice. An
# archive, unlike this, really does need every device architecture.
XCB          = xcodebuild -scheme '$(SCHEME)' -destination '$(DESTINATION)' \
               -configuration $(CONFIGURATION) \
               -derivedDataPath $(DERIVED) \
               -clonedSourcePackagesDirPath $(SPM_CACHE) \
               -skipMacroValidation ONLY_ACTIVE_ARCH=YES
PACKAGES    := NeechanTestSupport NeechanAPI NeechanSettings NeechanCore NeechanMedia NeechanUI
# The configuration that starts cautious and cannot post.
APPSTORE    := AppStore
# What the submitted build must call itself. Permanent once published, so both
# checks below read it from here rather than spelling it out twice.
APPSTORE_BUNDLE_ID := pro.neechan.app
# Recursively expanded and derived from the configuration: the App Store build
# installs beside the ordinary one under its own identifier, so `simctl launch`
# has to be told which of the two was just put there. Keeping this tied to the
# configuration is what stops the two drifting apart.
#
# The bare identifier is the App Store one, because that is the one that ships
# and the one that is permanent; the sideloaded build wears the suffix.
BUNDLE_ID    = pro.neechan.app$(if $(filter $(APPSTORE),$(CONFIGURATION)),,-dev)
# The configuration an archive is cut from. `ipa` stays on Release, which is
# what the release workflow builds and names.
ARCHIVE_CONFIG ?= Release
# Both keyed by it, so two variants archived in turn cannot overwrite each
# other, and a release build does not fight the debug one over a module cache.
DERIVED_REL  = .build/DerivedDataArchive-$(ARCHIVE_CONFIG)
ARCHIVE      = .build/Neechan-$(ARCHIVE_CONFIG).xcarchive
# The version the built app reports. The release workflow passes the tag.
VERSION     := $(shell awk '/MARKETING_VERSION:/ { gsub(/["[:space:]]/, "", $$2); print $$2; exit }' project.yml)
# Infixed only away from Release: `.github/workflows/release.yml` names
# `.build/Neechan-$(VERSION).ipa` literally and fails the job if it is absent.
IPA          = .build/Neechan$(if $(filter-out Release,$(ARCHIVE_CONFIG)),-appstore,)-$(VERSION).ipa

.PHONY: all gen build ipa appstore ipa-appstore check-appstore check-ipa-appstore test test-packages test-pkg test-app test-one test-report sim ipad duo screenshot fixtures clean clean-all

all: gen test

## Regenerate the Xcode project from project.yml.
gen:
	@command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }
	xcodegen generate --spec project.yml

## Build the app for the simulator. `make build CONFIGURATION=Release` to measure.
build:
	$(XCB) build $(BEAUTIFY)

## Build an unsigned .ipa for a device, the way the release workflow does.
##
## Unsigned on purpose: there is no certificate in the repo and none should be.
## That also rules out `xcodebuild -exportArchive`, which refuses without a
## signing method, so the archive's app is wrapped in a Payload/ folder by hand,
## which is all an .ipa is.
ipa: gen
	xcodebuild -scheme '$(SCHEME)' -configuration $(ARCHIVE_CONFIG) \
		-destination 'generic/platform=iOS' \
		-archivePath $(ARCHIVE) \
		-derivedDataPath $(DERIVED_REL) \
		-clonedSourcePackagesDirPath $(SPM_CACHE) \
		-skipMacroValidation -quiet \
		CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
		MARKETING_VERSION=$(VERSION) \
		archive
	@rm -rf .build/Payload $(IPA)
	@mkdir -p .build/Payload
	@cp -R $(ARCHIVE)/Products/Applications/Neechan.app .build/Payload/
	@cd .build && zip -qry9 $(notdir $(IPA)) Payload && rm -rf Payload
	@ls -lh $(IPA) | awk '{ print "built $(IPA) (" $$5 ")" }'

## Run every package test suite, then the app test bundles.
test: test-packages test-app

## Fast loop: pure Swift packages, no simulator, no Xcode project needed.
test-packages:
	@set -e; for pkg in $(PACKAGES); do \
		if ls Packages/$$pkg/Tests/*/*.swift >/dev/null 2>&1; then \
			echo "==> $$pkg"; \
			swift test --package-path Packages/$$pkg --cache-path $(SPM_CACHE); \
		else \
			echo "==> $$pkg (no tests yet)"; \
		fi; \
	done

## Run the app-level unit and UI test bundles on the simulator.
## xcodebuild's own summary is unreadable however it is printed, so the result
## bundle is parsed afterwards for a one-line verdict.
test-app:
	@rm -rf $(RESULTS)
	$(XCB) -resultBundlePath $(RESULTS) test $(BEAUTIFY)
	@./Tools/test-summary.py $(RESULTS)

## Run one package's tests: `make test-pkg PKG=NeechanAPI`
## Optionally narrow further: `make test-pkg PKG=NeechanAPI FILTER=Captcha`
test-pkg:
	@test -n "$(PKG)" || { echo "usage: make test-pkg PKG=NeechanAPI [FILTER=Suite]"; exit 1; }
	swift test --package-path Packages/$(PKG) --cache-path $(SPM_CACHE) \
		$(if $(FILTER),--filter "$(FILTER)",)

## Run one app or UI test class or method:
## `make test-one ONLY=NeechanUITests/PostingUITests`
test-one:
	@test -n "$(ONLY)" || { echo "usage: make test-one ONLY=Target/Class[/method]"; exit 1; }
	@rm -rf $(RESULTS)
	$(XCB) -resultBundlePath $(RESULTS) -only-testing:$(ONLY) test $(BEAUTIFY)
	@./Tools/test-summary.py $(RESULTS)

## Re-print the verdict and failures from the last app test run.
test-report:
	@./Tools/test-summary.py $(RESULTS)

## Build, install and launch on the simulator.
##
## The device is resolved to a UDID rather than addressed as `booted`: more than
## one simulator is usually running, and several runtimes offer a device of the
## same name, so both of the obvious ways to name it are ambiguous.
sim: build
	@set -e; \
	udid='$(SIM_ID)'; \
	if [ -z "$$udid" ]; then \
	  udid=$$(xcrun simctl list devices available -j | python3 -c "import json,sys; \
	    devices = json.load(sys.stdin)['devices']; \
	    runtime = 'iOS-$(subst .,-,$(SIM_OS))'; \
	    print(next((d['udid'] for k, v in devices.items() if k.endswith(runtime) \
	      for d in v if d['name'] == '$(SIMULATOR)'), ''))"); \
	fi; \
	test -n "$$udid" || { echo "no '$(SIMULATOR)' on iOS $(SIM_OS)"; exit 1; }; \
	xcrun simctl boot $$udid 2>/dev/null || true; \
	: "Xcode 27 ships no Simulator.app: booting a device raises its window"; \
	: "through CoreSimulator. Still opened where it exists, for older Xcodes."; \
	open -a Simulator >/dev/null 2>&1 || true; \
	app=$$(find $(DERIVED)/Build/Products -name 'Neechan.app' -maxdepth 3 | head -1); \
	xcrun simctl install $$udid "$$app"; \
	xcrun simctl launch $$udid $(BUNDLE_ID)

## Same, on iPad.
ipad: SIMULATOR := $(IPAD)
ipad: sim

## Same, on iPhone Duo.
##
## Resolved to a UDID before handing over, unlike the others: the runtime ships
## two devices called "iPhone Duo", so the name alone picks neither. The
## runtime is pinned separately from SIM_OS because the device type's
## minRuntimeVersion is 27.1 and it simply does not exist on 26.5. Needs Xcode
## 27.1 selected -- earlier Xcodes ship neither the device type nor the runtime.
duo:
	@set -e; \
	udid=$$(xcrun simctl list devices available -j | python3 -c "import json,sys; \
	  devices = json.load(sys.stdin)['devices']; \
	  runtime = 'iOS-$(subst .,-,$(DUO_OS))'; \
	  print(next((d['udid'] for k, v in devices.items() if k.endswith(runtime) \
	    for d in v if d['name'] == '$(DUO)'), ''))"); \
	test -n "$$udid" || { echo "no '$(DUO)' on iOS $(DUO_OS): needs Xcode 27.1"; exit 1; }; \
	$(MAKE) --no-print-directory sim \
	  SIMULATOR='$(DUO)' SIM_OS=$(DUO_OS) SIM_ID=$$udid

## Build, install and launch the App Store variant on the simulator.
##
## It carries its own bundle identifier, so it sits beside the ordinary build
## rather than replacing it.
appstore: CONFIGURATION := $(APPSTORE)
appstore: check-appstore sim

## An unsigned .ipa of the App Store variant.
ipa-appstore: ARCHIVE_CONFIG := $(APPSTORE)
ipa-appstore: ipa
	@$(MAKE) --no-print-directory check-ipa-appstore ARCHIVE_CONFIG=$(APPSTORE)

## Fails unless the built app really is the restricted one.
##
## `Neechan/Info.plist` is generated and gitignored, and `build` does not depend
## on `gen` — so editing project.yml and building without regenerating produces
## an app with no such key at all, which reads as the ordinary build and posts
## freely while wearing the App Store identifier. A typo between the setting
## name and the $(...) in the plist does the same, expanding to nothing. This
## turns either of those from a silent unlock into a failed build.
check-appstore: build
	@set -e; \
	app=$$(find $(DERIVED)/Build/Products -name 'Neechan.app' -maxdepth 3 | head -1); \
	plist=$$app/Info.plist; \
	test -f "$$plist" || { echo "no built app to check"; exit 1; }; \
	locked=$$(plutil -extract NeechanIsAppStoreBuild raw -o - "$$plist" 2>/dev/null || echo MISSING); \
	id=$$(plutil -extract CFBundleIdentifier raw -o - "$$plist"); \
	test "$$locked" = "YES" || { echo "NOT the App Store build: NeechanIsAppStoreBuild=$$locked. Run 'make gen'."; exit 1; }; \
	test "$$id" = "$(APPSTORE_BUNDLE_ID)" || { echo "wrong bundle id: $$id (expected $(APPSTORE_BUNDLE_ID))"; exit 1; }; \
	name=$$(plutil -extract CFBundleDisplayName raw -o - "$$plist"); \
	test "$$name" = "Neechan" || { echo "wrong display name: $$name (expected Neechan)"; exit 1; }; \
	plutil -extract CFBundleIcons.CFBundleAlternateIcons json -o - "$$plist" 2>/dev/null | grep -q '"AppIcon3"' && { echo "AppIcon3 (the nude artwork) is in the App Store build. Run 'make gen'."; exit 1; } || true; \
	test ! -e "$$app/NeechanUI_NeechanUI.bundle/app-icon-neechan.png" || { echo "the nude icon preview is in the App Store build"; exit 1; }; \
	echo "App Store build confirmed: $$id, posting off, no AppIcon3"

## Checks the archive `ipa-appstore` just cut. Given ARCHIVE_CONFIG explicitly,
## because a target-specific variable does not reach a sub-make and this would
## otherwise inspect the ordinary Release archive and pass on the wrong file.
check-ipa-appstore:
	@set -e; \
	app=$(ARCHIVE)/Products/Applications/Neechan.app; \
	plist=$$app/Info.plist; \
	locked=$$(plutil -extract NeechanIsAppStoreBuild raw -o - "$$plist" 2>/dev/null || echo MISSING); \
	id=$$(plutil -extract CFBundleIdentifier raw -o - "$$plist"); \
	name=$$(plutil -extract CFBundleDisplayName raw -o - "$$plist"); \
	test "$$locked" = "YES" || { echo "NOT the App Store build: NeechanIsAppStoreBuild=$$locked"; exit 1; }; \
	test "$$id" = "$(APPSTORE_BUNDLE_ID)" || { echo "wrong bundle id: $$id (expected $(APPSTORE_BUNDLE_ID))"; exit 1; }; \
	test "$$name" = "Neechan" || { echo "wrong display name: $$name (expected Neechan)"; exit 1; }; \
	plutil -extract CFBundleIcons.CFBundleAlternateIcons json -o - "$$plist" 2>/dev/null | grep -q '"AppIcon3"' && { echo "AppIcon3 (the nude artwork) is in the App Store build. Run 'make gen'."; exit 1; } || true; \
	test ! -e "$$app/NeechanUI_NeechanUI.bundle/app-icon-neechan.png" || { echo "the nude icon preview is in the App Store build"; exit 1; }; \
	echo "App Store .ipa confirmed: $$id, posting off, no AppIcon3"

## Capture the booted simulator screen.
screenshot:
	@mkdir -p .build/screenshots
	xcrun simctl io booted screenshot .build/screenshots/$$(date +%Y%m%d-%H%M%S).png
	@ls -t .build/screenshots | head -1

## Re-record API fixtures from the live site.
fixtures:
	./Tools/record-fixtures.sh
	./Tools/record-4chan-fixtures.sh

clean:
	rm -rf $(DERIVED) $(RESULTS) .build/DerivedData-$(APPSTORE) .build/DerivedDataArchive-*
	@for pkg in $(PACKAGES); do rm -rf Packages/$$pkg/.build; done

## Also drops the shared SwiftPM clone cache.
clean-all: clean
	rm -rf $(SPM_CACHE)
