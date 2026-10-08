APP     := ShotMark.app
BIN     := $(APP)/Contents/MacOS/ShotMark
SRC     := $(wildcard Sources/*.swift)
SDK     := $(shell xcrun --sdk macosx --show-sdk-path)
TARGET  := arm64-apple-macosx14.0
GENICON := build/gen-icon
ICNS    := build/AppIcon.icns
ICONSET := build/ShotMark.iconset

.PHONY: all run selftest install clean icon

all: $(APP)

$(ICNS): scripts/gen-icon.swift
	@mkdir -p build
	xcrun swiftc -O -sdk $(SDK) -target $(TARGET) -o $(GENICON) scripts/gen-icon.swift -framework AppKit
	@rm -rf $(ICONSET)
	@$(GENICON) $(ICONSET)
	iconutil -c icns $(ICONSET) -o $(ICNS)
	@[ "$$(stat -f%z $(ICNS))" -gt 0 ] || { echo "✗ iconutil 产出 0 字节（.iconset 少尺寸）"; exit 1; }
	@echo "✔ icon: $(ICNS)"

icon: $(ICNS)

$(BIN): $(SRC) Info.plist $(ICNS)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	xcrun swiftc -swift-version 5 -O -sdk $(SDK) -target $(TARGET) \
		-o $(BIN) $(SRC) \
		-framework AppKit -framework Carbon -framework ScreenCaptureKit
	@cp Info.plist $(APP)/Contents/Info.plist
	@cp $(ICNS) $(APP)/Contents/Resources/AppIcon.icns
	@codesign --force --sign "ShotMark Local Signing" --identifier dev.shotmark --timestamp=none $(APP) 2>/dev/null \
		&& echo "✔ signed: ShotMark Local Signing（TCC 授权跨重编保持有效）" \
		|| { codesign --force --sign - $(APP) >/dev/null 2>&1; echo "⚠ 无签名证书，退回 ad-hoc（重编后屏幕录制授权需重授）"; }
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
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/$(APP)
	@echo "✔ installed ~/Applications/$(APP)（已刷新 LaunchServices）"

clean:
	@rm -rf $(APP) build
