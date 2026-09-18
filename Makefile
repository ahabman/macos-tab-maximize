APP        := TabMaximize
BUNDLE_ID  := com.bamf.tabmaximize
SIGN_ID    ?= TabMaximizeSelfSigned
DEST       := /Applications/$(APP).app
BUILD      := build/$(APP).app

.PHONY: all build bundle sign install run debug dump logs clean cert uninstall

all: sign

build:
	swift build -c release

bundle: build
	rm -rf $(BUILD)
	mkdir -p $(BUILD)/Contents/MacOS $(BUILD)/Contents/Resources
	cp "$$(swift build -c release --show-bin-path)/$(APP)" $(BUILD)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(BUILD)/Contents/Info.plist
	printf 'APPL????' > $(BUILD)/Contents/PkgInfo
	plutil -lint $(BUILD)/Contents/Info.plist

sign: bundle
ifeq ($(SIGN_ID),-)
	@echo ""
	@echo "  WARNING: ad-hoc signing. The Accessibility grant is tied to this exact"
	@echo "  build's cdhash, so it will silently stop applying after every rebuild."
	@echo "  Run 'make cert' once, then build normally. See README.md."
	@echo ""
endif
	codesign --force --sign "$(SIGN_ID)" --identifier $(BUNDLE_ID) --timestamp=none $(BUILD)
	codesign --verify --strict --verbose=2 $(BUILD)
	@echo "--- designated requirement (want 'certificate leaf', not 'cdhash') ---"
	@codesign -d -r- $(BUILD) 2>&1 | tail -2

# One-time: create the self-signed code signing certificate the grant is anchored to.
cert:
	./scripts/make-signing-cert.sh

install: sign
	pkill -x $(APP) || true
	rm -rf $(DEST)
	cp -R $(BUILD) $(DEST)
	open $(DEST)
	@echo "Installed to $(DEST)"

uninstall:
	pkill -x $(APP) || true
	rm -rf $(DEST)

# Run the signed bundle in the foreground with stderr logging.
debug: sign
	$(BUILD)/Contents/MacOS/$(APP) --verbose

run: install

# make dump TARGET=TextEdit
dump: sign
	$(BUILD)/Contents/MacOS/$(APP) --dump-ax $(TARGET)

logs:
	log stream --predicate 'subsystem == "$(BUNDLE_ID)"' --level debug --style compact

clean:
	rm -rf .build build
