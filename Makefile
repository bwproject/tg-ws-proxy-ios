# TG WS Proxy — iOS Build
# Device target: iOS 15.0+

APP_NAME := TgWsProxy
LIB_NAME := libtgwsproxy
BUILD_DIR := build

.PHONY: all go-lib xcframework clean

all: go-lib

# Go -> iOS static libraries. Exact SDK deployment flags are supplied by Xcode/CI.
go-lib:
	@echo "==> Building $(LIB_NAME).a for iOS device (arm64, iOS 15+)"
	@mkdir -p $(BUILD_DIR)/ios
	GOOS=ios GOARCH=arm64 CGO_ENABLED=1 \
		CGO_CFLAGS="-mios-version-min=15.0" \
		CGO_LDFLAGS="-mios-version-min=15.0" \
		go build -buildmode=c-archive -o $(BUILD_DIR)/ios/$(LIB_NAME).a .

	@echo "==> Building $(LIB_NAME).a for iOS Simulator (arm64, iOS 15+)"
	@mkdir -p $(BUILD_DIR)/sim
	GOOS=ios GOARCH=arm64 CGO_ENABLED=1 \
		GOFLAGS="-tags=iossimulator" \
		CGO_CFLAGS="-mios-simulator-version-min=15.0" \
		CGO_LDFLAGS="-mios-simulator-version-min=15.0" \
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
