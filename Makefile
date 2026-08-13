# TG WS Proxy — iOS 15+ Build
# On Windows: make go-lib (Go static library only)
# On Mac: make xcframework (creates XCFramework from .a files)

APP_NAME := TgWsProxy
LIB_NAME := libtgwsproxy
BUILD_DIR := build
MIN_IOS := 15.0

.PHONY: all go-lib xcframework clean

all: go-lib

go-lib:
	@echo "==> Building $(LIB_NAME).a for iOS device (arm64), minimum iOS $(MIN_IOS)"
	@mkdir -p $(BUILD_DIR)/ios
	CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
		CGO_CFLAGS="-mios-version-min=$(MIN_IOS)" \
		CGO_LDFLAGS="-mios-version-min=$(MIN_IOS)" \
		go build -buildmode=c-archive -o $(BUILD_DIR)/ios/$(LIB_NAME).a .

	@echo "==> Building $(LIB_NAME).a for iOS Simulator (arm64), minimum iOS $(MIN_IOS)"
	@mkdir -p $(BUILD_DIR)/sim
	CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
		CGO_CFLAGS="-mios-simulator-version-min=$(MIN_IOS)" \
		CGO_LDFLAGS="-mios-simulator-version-min=$(MIN_IOS)" \
		GOFLAGS="-tags=iossimulator" \
		go build -buildmode=c-archive -o $(BUILD_DIR)/sim/$(LIB_NAME).a .

	@echo "==> Done: $(BUILD_DIR)/ios/ and $(BUILD_DIR)/sim/"

xcframework: go-lib
	@echo "==> Creating XCFramework"
	xcodebuild -create-xcframework \
		-library $(BUILD_DIR)/ios/$(LIB_NAME).a -headers include \
		-library $(BUILD_DIR)/sim/$(LIB_NAME).a -headers include \
		-output $(BUILD_DIR)/$(APP_NAME).xcframework
	@echo "==> Done: $(BUILD_DIR)/$(APP_NAME).xcframework"

clean:
	@echo "==> Cleaning build artifacts"
	rm -rf $(BUILD_DIR)
