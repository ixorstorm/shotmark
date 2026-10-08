APP     := ShotMark.app
BIN     := $(APP)/Contents/MacOS/ShotMark
SRC     := $(wildcard Sources/*.swift)
SDK     := $(shell xcrun --sdk macosx --show-sdk-path)
TARGET  := arm64-apple-macosx14.0

.PHONY: all run selftest install clean

all: $(APP)

$(BIN): $(SRC) Info.plist
	@mkdir -p $(APP)/Contents/MacOS
	xcrun swiftc -swift-version 5 -O -sdk $(SDK) -target $(TARGET) \
		-o $(BIN) $(SRC) \
		-framework AppKit -framework Carbon -framework ScreenCaptureKit
	@cp Info.plist $(APP)/Contents/Info.plist
	@codesign --force --sign - $(APP) >/dev/null 2>&1 || true
	@echo "✔ built $(APP)"

$(APP): $(BIN)

run: all
	@open $(APP)

selftest: all
	@$(BIN) --selftest

install: all
	@mkdir -p ~/Applications
	@rm -rf ~/Applications/$(APP)
	@cp -R $(APP) ~/Applications/$(APP)
	@echo "✔ installed ~/Applications/$(APP)"

clean:
	@rm -rf $(APP)
