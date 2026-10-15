#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT/dist"
APP="$DIST_DIR/NookClip.app"

# 默认日常开发使用 debug，秒级增量构建；正式打包使用 --release 或 --universal
CONFIG="debug"
UNIVERSAL=false
SKIP_RUST=false
FORCE_RUST=false
TARGET_ARCH="$(uname -m)"

for arg in "$@"; do
  case "$arg" in
    --debug)
      CONFIG="debug"
      ;;
    --release)
      CONFIG="release"
      ;;
    --universal)
      UNIVERSAL=true
      CONFIG="release"
      ;;
    --skip-rust)
      SKIP_RUST=true
      ;;
    --force-rust)
      FORCE_RUST=true
      ;;
    --arch=*)
      TARGET_ARCH="${arg#*=}"
      ;;
    -h|--help)
      echo "用法: $0 [选项]"
      echo "选项:"
      echo "  --debug         构建 Debug 配置（默认，极速增量开发）"
      echo "  --release       构建 Release 配置（生产优化）"
      echo "  --universal     构建 Universal Binary 双架构（arm64 + x86_64）"
      echo "  --skip-rust     强制跳过 Rust 构建"
      echo "  --force-rust    强制重新编译 Rust 模块"
      echo "  --arch=<arch>   指定单架构（默认本机架构: $TARGET_ARCH）"
      exit 0
      ;;
  esac
done

# 1. 智能 Rust 构建检查（自动检测变更，无改动时 0 秒跳过）
RUST_STAMP="$ROOT/target/.rust_build_stamp_${CONFIG}"
STAGED_LIB="$ROOT/crates/nookclip-ffi/lib/libnookclip_ffi.a"
SWIFT_BRIDGE="$ROOT/platform/macOS/Sources/NookClip/CoreBridge/NookClipCoreBridge.swift"

NEED_RUST=false
if [[ "$SKIP_RUST" = true ]]; then
  NEED_RUST=false
elif [[ "$FORCE_RUST" = true || ! -f "$RUST_STAMP" || ! -f "$STAGED_LIB" || ! -f "$SWIFT_BRIDGE" ]]; then
  NEED_RUST=true
elif [[ "$UNIVERSAL" = true ]] && ! lipo -info "$STAGED_LIB" 2>/dev/null | grep -q "x86_64"; then
  # 若要求 universal 构建，但现有静态库未包含 x86_64 切片，强制重新编译 Rust 模块
  NEED_RUST=true
else
  # 检查 crates 目录下是否有源码晚于上次 stamp
  if find "$ROOT/crates" -type f \( -name "*.rs" -o -name "*.toml" \) -newer "$RUST_STAMP" -print -quit | grep -q .; then
    NEED_RUST=true
  fi
fi

if [[ "$NEED_RUST" = true ]]; then
  RUST_ARGS=("--$CONFIG")
  if [[ "$UNIVERSAL" = true ]]; then
    RUST_ARGS+=(--universal)
  fi
  echo "==> [1/4] 编译 Rust 桥接模块 (${RUST_ARGS[*]})..."
  "$ROOT/scripts/build-rust.sh" "${RUST_ARGS[@]}"
else
  echo "==> [1/4] Rust 模块无改动，自动跳过编译 (0s)"
fi

# 2. 编译 SwiftPM 工程
echo "==> [2/4] 构建 Swift 可执行文件 (配置: $CONFIG, universal: $UNIVERSAL)..."
SDK_VER="$(xcrun --sdk macosx --show-sdk-version)"
LINKER_FLAGS=(-Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VER")
BUILD_DIR="$ROOT/platform/macOS/.build/$CONFIG"

cd "$ROOT"
# 当静态库 libnookclip_ffi.a 比已生成的二进制更新时，强制移除旧二进制以触发重链接
if [[ -f "$STAGED_LIB" && -f "$BUILD_DIR/NookClip" && "$STAGED_LIB" -nt "$BUILD_DIR/NookClip" ]]; then
  rm -f "$BUILD_DIR/NookClip"
fi

if [[ "$UNIVERSAL" = true ]]; then
  X86_BUILD="$ROOT/platform/macOS/.build-x86_64"
  echo "    Compiling arm64 slice..."
  swift build --package-path platform/macOS -c release --arch arm64 "${LINKER_FLAGS[@]}"
  echo "    Compiling x86_64 slice..."
  swift build --package-path platform/macOS -c release --triple x86_64-apple-macos14.0 \
    --scratch-path "$X86_BUILD" "${LINKER_FLAGS[@]}"
  
  mkdir -p "$BUILD_DIR"
  lipo -create "$BUILD_DIR/NookClip" "$X86_BUILD/release/NookClip" -output "$BUILD_DIR/NookClip"
else
  swift build --package-path platform/macOS -c "$CONFIG" --arch "$TARGET_ARCH" "${LINKER_FLAGS[@]}"
fi

SRC_BIN="$BUILD_DIR/NookClip"
if [[ ! -f "$SRC_BIN" ]]; then
  echo "error: 找不到编译产物 $SRC_BIN" >&2
  exit 1
fi

# 3. 增量组装 .app Bundle（避免反复删除重拷大文件）
echo "==> [3/4] 增量组装应用 Bundle 到 $APP..."
mkdir -p "$DIST_DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# 仅在二进制有变动时复制，保留时间戳与缓存；清除旧二进制
rm -f "$APP/Contents/MacOS/Nook"
DST_BIN="$APP/Contents/MacOS/NookClip"
if [[ ! -f "$DST_BIN" ]] || ! cmp -s "$SRC_BIN" "$DST_BIN"; then
  cp "$SRC_BIN" "$DST_BIN.tmp"
  mv -f "$DST_BIN.tmp" "$DST_BIN"
fi

# 校验架构
ARCHS="$(/usr/bin/lipo -archs "$DST_BIN")"
if [[ "$UNIVERSAL" = true && ("$ARCHS" != *arm64* || "$ARCHS" != *x86_64*) ]]; then
  echo "error: 期望 Universal Binary (arm64 + x86_64)，实际得到: $ARCHS" >&2
  exit 1
fi

# 元数据与资源同步
cp "$ROOT/platform/macOS/Packaging/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/platform/macOS/Sources/NookClip/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/platform/macOS/Sources/NookClip/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
rsync -a --update "$ROOT/platform/macOS/Sources/NookClip/Resources/" "$APP/Contents/Resources/" 2>/dev/null || true

if ls "$BUILD_DIR"/*.bundle 1> /dev/null 2>&1; then
  rsync -a --update "$BUILD_DIR"/*.bundle "$APP/Contents/Resources/" 2>/dev/null || true
  find -L "$BUILD_DIR" -name "*.lproj" -maxdepth 5 -exec cp -R {} "$APP/Contents/Resources/" \; 2>/dev/null || true
fi

# Sparkle 2 framework：Release / Universal 构建强制刷新，确保不混入旧 Debug 框架
DST_SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ "$CONFIG" = "release" || "$UNIVERSAL" = true || ! -d "$DST_SPARKLE" ]]; then
  SPARKLE_FW="$(find "$ROOT/platform/macOS/.build" -type d -name 'Sparkle.framework' -path "*/$CONFIG/*" -not -path '*artifacts*' | head -1 || true)"
  if [[ -z "$SPARKLE_FW" ]]; then
    SPARKLE_FW="$(find "$ROOT/platform/macOS/.build" -type d -name 'Sparkle.framework' -not -path '*artifacts*' | head -1 || true)"
  fi
  if [[ -n "$SPARKLE_FW" ]]; then
    rm -rf "$DST_SPARKLE"
    cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
  fi
fi

# 清理构建期残留的本机绝对路径 LC_RPATH，仅保留系统与 @executable_path/../Frameworks
for rpath in $(/usr/bin/otool -l "$DST_BIN" | awk '/cmd LC_RPATH/{getline; getline; print $2}'); do
  if [[ "$rpath" == "$ROOT"* || "$rpath" == /Applications/Xcode* ]]; then
    /usr/bin/install_name_tool -delete_rpath "$rpath" "$DST_BIN" 2>/dev/null || true
  fi
done
/usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$DST_BIN" 2>/dev/null || true

# 4. 代码签名（分层签名 Sparkle 内部组件与主应用）
SIGNING_ENV="$HOME/.nookclip/signing.env"
if [[ ! -f "$SIGNING_ENV" && -f "$HOME/.nook/signing.env" ]]; then
  SIGNING_ENV="$HOME/.nook/signing.env"
fi
if [[ -f "$SIGNING_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$SIGNING_ENV"
fi

SIGN_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
ENTITLEMENTS="$ROOT/platform/macOS/Packaging/NookClip.entitlements"

if [[ -n "$SIGN_IDENTITY" ]]; then
  if [[ -d "$DST_SPARKLE" ]]; then
    /usr/bin/codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$DST_SPARKLE"
  fi
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP"
else
  if [[ -d "$DST_SPARKLE" ]]; then
    /usr/bin/codesign --force --deep --sign - "$DST_SPARKLE"
  fi
  /usr/bin/codesign --force --sign - -r='designated => identifier "com.lx3xun.nookclip"' --entitlements "$ENTITLEMENTS" "$APP"
fi

echo "✅ 构建完成: $APP (架构: $ARCHS, 配置: $CONFIG)"
