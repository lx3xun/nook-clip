#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT/dist"
APP="$DIST_DIR/NookClip.app"
DMG_NAME="NookClip.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
TEMP_DMG_DIR="$ROOT/platform/macOS/.build/dmg-staging"

SKIP_APP=false
APP_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --skip-app)
      SKIP_APP=true
      ;;
    -h|--help)
      echo "用法: $0 [选项]"
      echo "选项:"
      echo "  --universal     构建 Universal Binary 双架构 DMG"
      echo "  --skip-rust     跳过 Rust 构建"
      echo "  --skip-app      跳过 .app 构建，直接使用现有的 dist/NookClip.app"
      exit 0
      ;;
    *)
      APP_ARGS+=("$arg")
      ;;
  esac
done

# 1. 确保构建 Release .app
if [[ "$SKIP_APP" = false ]]; then
  echo "==> [DMG 1/4] 触发应用打包 (Release)..."
  zsh "$ROOT/scripts/build-app.sh" --release "${APP_ARGS[@]}"
else
  echo "==> [DMG 1/4] 跳过应用编译 (--skip-app)"
fi

if [[ ! -d "$APP" ]]; then
  echo "error: 未找到待打包应用: $APP" >&2
  exit 1
fi

# 2. 准备 DMG 内容
echo "==> [DMG 2/4] 准备 DMG 挂载内容..."
rm -rf "$TEMP_DMG_DIR" "$DMG_PATH" "$DMG_PATH.sha256"
mkdir -p "$TEMP_DMG_DIR" "$DIST_DIR"

cp -R "$APP" "$TEMP_DMG_DIR/"
ln -s /Applications "$TEMP_DMG_DIR/Applications"

# 放入首次安装与运行说明文档，帮助用户了解如何打开与呼出
cat << 'EOF' > "$TEMP_DMG_DIR/首次安装使用说明.txt"
==============================================
  欢迎使用 NookClip 剪贴板管理工具
==============================================

【1. 安装方法】
将左侧的 NookClip 图标拖拽到右侧 Applications 文件夹即可。

【2. 如何打开】
NookClip 为开源免公证版本，首次打开时：
• 若提示“无法打开，因为无法验证开发者”：
  请在访达（Finder）的「应用程序」中找到 NookClip，
  按住 Control 键点按（或右键点击），并在弹窗中选择「打开」。
• 若提示“已损坏，移到废纸篓”：
  打开系统「终端（Terminal）」执行如下命令即可：
  xattr -cr /Applications/NookClip.app

【3. 运行后在哪里？】
NookClip 是一款极轻量的常驻工具（不在 Dock 栏显示图标）：
• 启动后会自动在屏幕正上方【顶部菜单栏】常驻小图标。
• 默认随时在任何地方按下快捷键唤出主面板：
  【 ⌘ ⇧ V 】（Command + Shift + V）
• 在面板中：按 ↑ / ↓ 选择，按回车（Enter）直接粘贴。

【4. 自动粘贴权限提示】
按回车直接将历史记录粘贴到当前窗口需要辅助功能权限：
打开 macOS「系统设置 -> 隐私与安全性 -> 辅助功能」，允许 NookClip 即可。

项目主页与反馈：https://github.com/lx3xun/nook-clip
==============================================
EOF

# 3. 生成 DMG
echo "==> [DMG 3/4] 使用原生 hdiutil 生成 UDZO DMG..."
hdiutil create \
  -volname "NookClip" \
  -srcfolder "$TEMP_DMG_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$TEMP_DMG_DIR"

# 4. 签名、公证与校验和
echo "==> [DMG 4/4] 签名、公证与生成校验和..."
SIGNING_ENV="$HOME/.nook/signing.env"
if [[ -f "$SIGNING_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$SIGNING_ENV"
fi

SIGN_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "    为 DMG 进行 Developer ID 签名..."
  /usr/bin/codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
  
  if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "    提交 Apple 官方公证 (Profile: $NOTARY_PROFILE)..."
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "    装订公证票据 (Stapling)..."
    xcrun stapler staple "$DMG_PATH"
  else
    echo "    提示: 未配置 NOTARY_KEYCHAIN_PROFILE，跳过公证提交。"
  fi
else
  echo "    提示: 未配置 APPLE_SIGNING_IDENTITY，保持基础 DMG 镜像。"
fi

# 生成 SHA256 校验和
cd "$DIST_DIR"
shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256"

echo "=========================================="
echo "✅ DMG 打包完成: $DMG_PATH"
echo "大小: $(du -sh "$DMG_PATH" | cut -f1)"
echo "SHA256: $(cat "$DMG_NAME.sha256")"
echo "=========================================="
