#!/bin/bash
# Build script for SAYses Core C++ library

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CORE_DIR="$PROJECT_ROOT/Core"
BUILD_DIR="$CORE_DIR/build"

# Configuration
IOS_DEPLOYMENT_TARGET="15.0"
ARCHS=("arm64")  # For device. Add "x86_64" for simulator

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check dependencies
check_dependencies() {
    log_info "Checking dependencies..."

    # Check for CMake
    if ! command -v cmake &> /dev/null; then
        log_error "CMake not found. Install with: brew install cmake"
        exit 1
    fi

    # Check for protoc
    if ! command -v protoc &> /dev/null; then
        log_error "protoc not found. Install with: brew install protobuf"
        exit 1
    fi

    # Check for OpenSSL
    if ! brew --prefix openssl@1.1 &> /dev/null; then
        log_warn "OpenSSL not found. Installing..."
        brew install openssl@1.1
    fi

    # Check for Opus
    if ! brew --prefix opus &> /dev/null; then
        log_warn "Opus not found. Installing..."
        brew install opus
    fi

    log_info "All dependencies found"
}

# Generate protobuf files
generate_protobuf() {
    log_info "Generating protobuf files..."

    PROTO_DIR="$CORE_DIR/proto"
    PROTO_OUT="$CORE_DIR/src/generated"

    mkdir -p "$PROTO_OUT"

    protoc \
        --proto_path="$PROTO_DIR" \
        --cpp_out="$PROTO_OUT" \
        "$PROTO_DIR/Mumble.proto"

    log_info "Protobuf files generated"
}

# Build for iOS device
build_ios_device() {
    log_info "Building for iOS device (arm64)..."

    local BUILD_TYPE="Release"
    local DEVICE_BUILD_DIR="$BUILD_DIR/ios-device"

    mkdir -p "$DEVICE_BUILD_DIR"
    cd "$DEVICE_BUILD_DIR"

    cmake "$CORE_DIR" \
        -G Xcode \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_DEPLOYMENT_TARGET \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DUSE_SYSTEM_OPUS=ON \
        -DUSE_SYSTEM_SPEEX=OFF \
        -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@1.1)" \
        -DProtobuf_DIR="$(brew --prefix protobuf)/lib/cmake/protobuf" \
        -DOPUS_INCLUDE_DIRS="$(brew --prefix opus)/include" \
        -DOPUS_LIBRARIES="$(brew --prefix opus)/lib/libopus.a"

    cmake --build . --config $BUILD_TYPE

    log_info "iOS device build complete"
}

# Build for iOS simulator
build_ios_simulator() {
    log_info "Building for iOS simulator (x86_64, arm64)..."

    local BUILD_TYPE="Release"
    local SIM_BUILD_DIR="$BUILD_DIR/ios-simulator"

    mkdir -p "$SIM_BUILD_DIR"
    cd "$SIM_BUILD_DIR"

    cmake "$CORE_DIR" \
        -G Xcode \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT=iphonesimulator \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_DEPLOYMENT_TARGET \
        -DCMAKE_OSX_ARCHITECTURES="x86_64;arm64" \
        -DUSE_SYSTEM_OPUS=ON \
        -DUSE_SYSTEM_SPEEX=OFF \
        -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@1.1)" \
        -DProtobuf_DIR="$(brew --prefix protobuf)/lib/cmake/protobuf" \
        -DOPUS_INCLUDE_DIRS="$(brew --prefix opus)/include" \
        -DOPUS_LIBRARIES="$(brew --prefix opus)/lib/libopus.a"

    cmake --build . --config $BUILD_TYPE

    log_info "iOS simulator build complete"
}

# Create XCFramework
create_xcframework() {
    log_info "Creating XCFramework..."

    local FRAMEWORK_DIR="$BUILD_DIR/SaysesCore.xcframework"
    rm -rf "$FRAMEWORK_DIR"

    xcodebuild -create-xcframework \
        -library "$BUILD_DIR/ios-device/Release/libSaysesCore.a" \
        -headers "$CORE_DIR/include" \
        -library "$BUILD_DIR/ios-simulator/Release/libSaysesCore.a" \
        -headers "$CORE_DIR/include" \
        -output "$FRAMEWORK_DIR"

    log_info "XCFramework created at: $FRAMEWORK_DIR"
}

# Clean build
clean() {
    log_info "Cleaning build directory..."
    rm -rf "$BUILD_DIR"
    log_info "Clean complete"
}

# Main
case "${1:-all}" in
    clean)
        clean
        ;;
    deps)
        check_dependencies
        ;;
    proto)
        generate_protobuf
        ;;
    device)
        check_dependencies
        generate_protobuf
        build_ios_device
        ;;
    simulator)
        check_dependencies
        generate_protobuf
        build_ios_simulator
        ;;
    all)
        check_dependencies
        generate_protobuf
        build_ios_device
        build_ios_simulator
        create_xcframework
        ;;
    *)
        echo "Usage: $0 {clean|deps|proto|device|simulator|all}"
        exit 1
        ;;
esac

log_info "Done!"
