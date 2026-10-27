#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export MACOSX_DEPLOYMENT_TARGET=14.0
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROFILE="release"
UNIVERSAL=false

for arg in "$@"; do
    case "$arg" in
        --debug)
            PROFILE="debug"
            ;;
        --release)
            PROFILE="release"
            ;;
        --universal)
            UNIVERSAL=true
            ;;
        -h|--help)
            echo "Usage: $0 [--debug|--release] [--universal]"
            echo "  --debug       Build debug artifacts (fast, unoptimized)"
            echo "  --release     Build release artifacts (optimized, default)"
            echo "  --universal   Cross-compile arm64 and x86_64 and lipo merge (release only)"
            exit 0
            ;;
    esac
done

echo "==> Building Rust crates (profile: $PROFILE, universal: $UNIVERSAL)..."
cd "$REPO_ROOT"

OUT_DIR="$REPO_ROOT/crates/nookclip-ffi/generated"
mkdir -p "$OUT_DIR"

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
    arm64) HOST_TARGET="aarch64-apple-darwin" ;;
    x86_64) HOST_TARGET="x86_64-apple-darwin" ;;
    *) echo "Unsupported host architecture: $HOST_ARCH" >&2; exit 1 ;;
esac

CARGO_FLAGS=(--package nookclip-ffi)
if [ "$PROFILE" = "release" ]; then
    CARGO_FLAGS+=(--release)
fi

if [ "$UNIVERSAL" = true ]; then
    if [ "$PROFILE" != "release" ]; then
        echo "WARNING: --universal requested with --debug; falling back to native architecture for debug" >&2
        UNIVERSAL=false
    fi
fi

if [ "$UNIVERSAL" = true ]; then
    echo "    Checking Rust targets..."
    for TARGET in aarch64-apple-darwin x86_64-apple-darwin; do
        if ! rustup target list --installed | grep -qx "$TARGET"; then
            echo "    Adding target $TARGET via rustup..."
            rustup target add "$TARGET"
        fi
    done

    echo "    Compiling aarch64-apple-darwin..."
    cargo build "${CARGO_FLAGS[@]}" --target aarch64-apple-darwin
    echo "    Compiling x86_64-apple-darwin..."
    cargo build "${CARGO_FLAGS[@]}" --target x86_64-apple-darwin

    mkdir -p "$REPO_ROOT/target/release"
    lipo -create \
        "$REPO_ROOT/target/aarch64-apple-darwin/release/libnookclip_ffi.a" \
        "$REPO_ROOT/target/x86_64-apple-darwin/release/libnookclip_ffi.a" \
        -output "$REPO_ROOT/target/release/libnookclip_ffi.a"

    DYLIB_PATH="$REPO_ROOT/target/$HOST_TARGET/release/libnookclip_ffi.dylib"
    STATIC_LIB_PATH="$REPO_ROOT/target/release/libnookclip_ffi.a"
else
    echo "    Compiling native host target ($HOST_ARCH)..."
    cargo build "${CARGO_FLAGS[@]}"
    DYLIB_PATH="$REPO_ROOT/target/$PROFILE/libnookclip_ffi.dylib"
    STATIC_LIB_PATH="$REPO_ROOT/target/$PROFILE/libnookclip_ffi.a"
fi

if [ ! -f "$DYLIB_PATH" ]; then
    echo "ERROR: Dynamic library not found at $DYLIB_PATH" >&2
    exit 1
fi

echo "==> Generating UniFFI Swift bindings..."
cargo run --package nookclip-ffi --bin uniffi-bindgen -- generate \
    --library "$DYLIB_PATH" \
    --crate nookclip_ffi \
    --language swift \
    --no-format \
    --metadata-no-deps \
    --out-dir "$OUT_DIR"

echo "==> Staging artifacts for Swift Package Manager..."
copy_if_changed() {
    local src="$1"
    local dst="$2"
    if [ ! -f "$dst" ] || ! cmp -s "$src" "$dst"; then
        cp "$src" "$dst"
    fi
}

STAGING_LIB_DIR="$REPO_ROOT/crates/nookclip-ffi/lib"
mkdir -p "$STAGING_LIB_DIR"
copy_if_changed "$STATIC_LIB_PATH" "$STAGING_LIB_DIR/libnookclip_ffi.a"

FFI_INCLUDE_DIR="$REPO_ROOT/platform/macOS/Sources/NookClipCoreBridgeFFI/include"
mkdir -p "$FFI_INCLUDE_DIR"
copy_if_changed "$OUT_DIR/NookClipCoreBridgeFFI.h" "$FFI_INCLUDE_DIR/NookClipCoreBridgeFFI.h"
copy_if_changed "$OUT_DIR/NookClipCoreBridgeFFI.modulemap" "$FFI_INCLUDE_DIR/module.modulemap"

SWIFT_BRIDGE_DIR="$REPO_ROOT/platform/macOS/Sources/NookClip/CoreBridge"
mkdir -p "$SWIFT_BRIDGE_DIR"
copy_if_changed "$OUT_DIR/NookClipCoreBridge.swift" "$SWIFT_BRIDGE_DIR/NookClipCoreBridge.swift"

mkdir -p "$REPO_ROOT/target"
touch "$REPO_ROOT/target/.rust_build_stamp_${PROFILE}"

echo "==> Rust build & SPM staging complete!"
lipo -info "$STAGING_LIB_DIR/libnookclip_ffi.a" || true
echo "    Staged lib: $STAGING_LIB_DIR/libnookclip_ffi.a"
echo "    Staged Swift wrapper: $SWIFT_BRIDGE_DIR/NookClipCoreBridge.swift"
