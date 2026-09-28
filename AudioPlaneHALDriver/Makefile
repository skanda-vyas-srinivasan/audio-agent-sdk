SHELL := /bin/bash

DRIVER_NAME := AudioPlaneInput
BUNDLE_NAME := AudioPlaneInput.driver
BUILD_DIR ?= .build
BUNDLE_DIR := $(BUILD_DIR)/$(BUNDLE_NAME)
CONTENTS_DIR := $(BUNDLE_DIR)/Contents
MACOS_DIR := $(CONTENTS_DIR)/MacOS
EXECUTABLE := $(MACOS_DIR)/$(DRIVER_NAME)
TEST_EXECUTABLE := $(BUILD_DIR)/AudioPlaneRingBufferTests
CONTRACT_EXECUTABLE := $(BUILD_DIR)/AudioPlaneDriverContractTests
SDK_PATH := $(shell xcrun --sdk macosx --show-sdk-path)
CLANG := $(shell xcrun --sdk macosx --find clang)
ARCHS ?= arm64 x86_64
ARCH_FLAGS := $(foreach arch,$(ARCHS),-arch $(arch))
SIGN_IDENTITY ?= -

COMMON_FLAGS := -isysroot $(SDK_PATH) -mmacosx-version-min=12.0 -std=gnu11 \
	-fblocks -fvisibility=hidden -Wall -Wextra -Wpedantic
DRIVER_FLAGS := $(COMMON_FLAGS) -O2 $(ARCH_FLAGS) -fPIC -bundle \
	-framework CoreAudio -framework CoreFoundation
TEST_FLAGS := $(COMMON_FLAGS) -O2 -pthread

.PHONY: all clean test test-tsan inspect

all: $(BUNDLE_DIR)

$(BUNDLE_DIR): Sources/AudioPlaneInput.c Sources/AudioPlaneRingBuffer.c \
		Sources/AudioPlaneRingBuffer.h Info.plist
	@rm -rf "$(BUNDLE_DIR)"
	@mkdir -p "$(MACOS_DIR)"
	$(CLANG) $(DRIVER_FLAGS) Sources/AudioPlaneInput.c Sources/AudioPlaneRingBuffer.c \
		-o "$(EXECUTABLE)"
	@cp Info.plist "$(CONTENTS_DIR)/Info.plist"
	@codesign --force --timestamp=none --sign "$(SIGN_IDENTITY)" "$(BUNDLE_DIR)"
	@touch "$(BUNDLE_DIR)"

$(TEST_EXECUTABLE): Sources/AudioPlaneRingBuffer.c Sources/AudioPlaneRingBuffer.h \
		Tests/AudioPlaneRingBufferTests.c
	@mkdir -p "$(BUILD_DIR)"
	$(CLANG) $(TEST_FLAGS) -I Sources Sources/AudioPlaneRingBuffer.c \
		Tests/AudioPlaneRingBufferTests.c -o "$(TEST_EXECUTABLE)"

$(CONTRACT_EXECUTABLE): Tests/AudioPlaneDriverContractTests.c
	@mkdir -p "$(BUILD_DIR)"
	$(CLANG) $(COMMON_FLAGS) -O2 Tests/AudioPlaneDriverContractTests.c \
		-framework CoreAudio -framework CoreFoundation -o "$(CONTRACT_EXECUTABLE)"

test: $(BUNDLE_DIR) $(TEST_EXECUTABLE) $(CONTRACT_EXECUTABLE)
	"$(TEST_EXECUTABLE)"
	"$(CONTRACT_EXECUTABLE)" "$(EXECUTABLE)"

test-tsan:
	@mkdir -p "$(BUILD_DIR)"
	$(CLANG) $(COMMON_FLAGS) -O1 -g -pthread -fsanitize=thread -I Sources \
		Sources/AudioPlaneRingBuffer.c Tests/AudioPlaneRingBufferTests.c \
		-o "$(BUILD_DIR)/AudioPlaneRingBufferTests-tsan"
	"$(BUILD_DIR)/AudioPlaneRingBufferTests-tsan"

inspect: $(BUNDLE_DIR)
	@plutil -lint "$(CONTENTS_DIR)/Info.plist"
	@test "$$(plutil -extract CFBundleIdentifier raw "$(CONTENTS_DIR)/Info.plist")" \
		= "com.audioplane.input.driver"
	@file "$(EXECUTABLE)"
	@nm -gj "$(EXECUTABLE)" | grep -qx '_AudioPlaneInput_Create'
	@codesign --verify --strict --verbose=2 "$(BUNDLE_DIR)"
	@codesign -dvv "$(BUNDLE_DIR)" 2>&1

clean:
	@rm -rf "$(BUILD_DIR)"
