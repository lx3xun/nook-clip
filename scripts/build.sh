#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT/dist"

show_help() {
  cat <<EOF
NookClip 构建统一调度脚本

用法:
  scripts/build.sh <命令> [选项]

常用命令:
  dev             快速编译本机架构 Debug 版应用（日常开发最快）
  run             快速增量编译并启动本地应用（自动退出已运行实例）
  app             构建独立 .app 应用（默认 Release，支持 --universal / --skip-rust）
  dmg             构建可分发的 .dmg 安装包（含 SHA256 校验和）
  rust            单独编译 Rust 核心与生成 UniFFI Swift 绑定
  clean           清理 dist 目录与中间编译缓存

示例:
  scripts/build.sh dev               # 快速本地调试构建
  scripts/build.sh run               # 编译并立即打开 NookClip
  scripts/build.sh app --universal   # 构建发布级通用双架构 .app
  scripts/build.sh dmg --universal   # 构建发布级 Universal DMG
  scripts/build.sh clean             # 清理所有构建缓存
EOF
}

CMD="${1:-}"
if [[ -z "$CMD" || "$CMD" == "-h" || "$CMD" == "--help" ]]; then
  show_help
  exit 0
fi
shift

case "$CMD" in
  dev)
    echo "==> 执行开发模式构建 (Debug, 原生架构)..."
    zsh "$ROOT/scripts/build-app.sh" --debug "$@"
    ;;
  run)
    echo "==> 执行增量构建并运行..."
    zsh "$ROOT/scripts/build-app.sh" --debug "$@"
    APP_PATH="$DIST_DIR/NookClip.app"
    if [[ ! -d "$APP_PATH" ]]; then
      echo "error: 未找到构建产物 $APP_PATH" >&2
      exit 1
    fi
    echo "==> 启动应用..."
    pkill -x NookClip 2>/dev/null || true
    pkill -x Nook 2>/dev/null || true
    sleep 0.2
    open "$APP_PATH"
    echo "✅ NookClip 已启动 ($APP_PATH)"
    ;;
  app)
    zsh "$ROOT/scripts/build-app.sh" "$@"
    ;;
  dmg)
    zsh "$ROOT/scripts/build-dmg.sh" "$@"
    ;;
  rust)
    "$ROOT/scripts/build-rust.sh" "$@"
    ;;
  clean)
    echo "==> 清理产物与构建缓存..."
    rm -rf "$DIST_DIR"
    rm -rf "$ROOT/platform/macOS/.build"
    rm -rf "$ROOT/platform/macOS/.build-x86_64"
    rm -rf "$ROOT/platform/macOS/.build/dmg-staging"
    rm -rf "$ROOT/Nook.app" "$ROOT/Nook.dmg" "$ROOT/NookClip.app" "$ROOT/NookClip.dmg"
    echo "✅ 清理完成！"
    ;;
  *)
    echo "error: 未知命令 '$CMD'" >&2
    echo ""
    show_help
    exit 1
    ;;
esac
