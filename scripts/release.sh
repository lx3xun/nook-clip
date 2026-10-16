#!/bin/zsh
# =============================================================================
# NookClip 一条命令发布脚本（双仓库：GitHub + Gitee，支持 --dry-run）
#
# 用法:
#   scripts/release.sh [--dry-run] <版本号> [发布说明]
#   例: scripts/release.sh 1.0.1 "修复若干问题"
#       scripts/release.sh --dry-run 1.0.1
# =============================================================================
set -euo pipefail
export NOOKCLIP_RELEASE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT/dist"
APP="$DIST_DIR/NookClip.app"
DMG="$DIST_DIR/NookClip.dmg"
PLIST="$ROOT/platform/macOS/Packaging/Info.plist"
CARGO_TOML="$ROOT/Cargo.toml"
SITE_INDEX="$ROOT/site/index.html"
GITHUB_TOKEN_FILE="$HOME/.nookclip/github-token"
[[ ! -f "$GITHUB_TOKEN_FILE" && -f "$HOME/.nook/github-token" ]] && GITHUB_TOKEN_FILE="$HOME/.nook/github-token"
EDDSA_KEY="$HOME/.nookclip/sparkle-eddsa.key"
[[ ! -f "$EDDSA_KEY" && -f "$HOME/.nook/sparkle-eddsa.key" ]] && EDDSA_KEY="$HOME/.nook/sparkle-eddsa.key"
GITEE_TOKEN_FILE="$HOME/.nookclip/gitee-token"
[[ ! -f "$GITEE_TOKEN_FILE" && -f "$HOME/.nook/gitee-token" ]] && GITEE_TOKEN_FILE="$HOME/.nook/gitee-token"
SPARKLE_VERSION="2.10.0"
SPARKLE_TOOLS="$HOME/.nookclip/sparkle-tools/$SPARKLE_VERSION"
[[ ! -d "$SPARKLE_TOOLS" && -d "$HOME/.nook/sparkle-tools/$SPARKLE_VERSION" ]] && SPARKLE_TOOLS="$HOME/.nook/sparkle-tools/$SPARKLE_VERSION"
GITHUB_OWNER_REPO="lx3xun/nook-clip"
GITEE_OWNER_REPO="lx3xun/nook-clip"
APPCAST_TAG="appcast"
STAGING="$ROOT/platform/macOS/.build/release-staging"

DRY_RUN=false
POSITIONAL_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=true
      ;;
    -h|--help)
      echo "用法: $0 [--dry-run] <版本号> [发布说明]"
      echo "选项:"
      echo "  --dry-run   执行测试门禁、打包 DMG 并生成签名清单，但不提交 Git 且不上传远端"
      exit 0
      ;;
    *)
      POSITIONAL_ARGS+=("$arg")
      ;;
  esac
done

if [[ ${#POSITIONAL_ARGS[@]} -lt 1 ]]; then
  echo "error: 缺少版本号参数。用法: $0 [--dry-run] <版本号> [发布说明]" >&2
  exit 1
fi

VER="${POSITIONAL_ARGS[1]}"
CUSTOM_NOTES="${POSITIONAL_ARGS[2]:-}"

# 自动提取或推导更新日志（防呆机制）
CHANGELOG_FILE="$ROOT/CHANGELOG.md"
EXTRACTED_NOTES=""
FROM_UNRELEASED=false

if [[ -f "$CHANGELOG_FILE" ]]; then
  # 1. 优先提取当前版本 [VER]
  EXTRACTED_NOTES="$(python3 -c '
import re, sys
try:
    changelog_path, ver = sys.argv[1], sys.argv[2]
    content = open(changelog_path, "r", encoding="utf-8").read()
    pattern = rf"##\s*\[{re.escape(ver)}\][^\n]*\n(.*?)(?=\n##\s*\[|\Z)"
    m = re.search(pattern, content, re.DOTALL)
    if m and m.group(1).strip():
        print(m.group(1).strip())
except Exception:
    pass
' "$CHANGELOG_FILE" "$VER" 2>/dev/null || true)"

  # 2. 如果未找到对应版本，但 [Unreleased] 下有内容，则自动采用 [Unreleased]
  if [[ -z "$EXTRACTED_NOTES" ]]; then
    UNRELEASED_NOTES="$(python3 -c '
import re, sys
try:
    changelog_path = sys.argv[1]
    content = open(changelog_path, "r", encoding="utf-8").read()
    pattern = r"##\s*\[Unreleased\][^\n]*\n(.*?)(?=\n##\s*\[|\Z)"
    m = re.search(pattern, content, re.DOTALL)
    if m and m.group(1).strip():
        print(m.group(1).strip())
except Exception:
    pass
' "$CHANGELOG_FILE" 2>/dev/null || true)"
    if [[ -n "$UNRELEASED_NOTES" ]]; then
      EXTRACTED_NOTES="$UNRELEASED_NOTES"
      FROM_UNRELEASED=true
      echo "ℹ️  CHANGELOG.md 中未找到 [$VER]，但检测到 [Unreleased] 内容，已自动采用作为本次发版说明。"
    fi
  fi
fi

# 3. 严格门禁防呆：既没有参数，也没有 CHANGELOG 内容，直接报错拦截，防止空白发版
if [[ -z "$CUSTOM_NOTES" && -z "$EXTRACTED_NOTES" ]]; then
  echo "❌ 发布被拦截：CHANGELOG.md 中未找到 [${VER}] 或 [Unreleased] 的更新说明，且未传入发布说明参数！" >&2
  echo "   请按以下任一方式提供：" >&2
  echo "   1. 在 CHANGELOG.md 中添加 ## [${VER}] 或将内容写在 ## [Unreleased] 下" >&2
  echo "   2. 命令行直接指定说明: scripts/release.sh ${VER} \"本次更新内容说明...\"" >&2
  exit 1
fi

GATEKEEPER_TIPS="### 首次打开遇到安全提示说明 / Security Notice for First Launch

由于当前版本尚未接入 Apple 开发者证书公证，首次打开可能提示 **“无法打开，因为无法验证开发者”** 或 **“已被阻止”**：

1. **推荐方法**：在访达（Finder）中找到 **NookClip.app**，**按住 Control 键点按（或右键）** 点击「打开」，并在弹窗中选择「打开」。
2. **备选方法**：打开 macOS **系统设置 -> 隐私与安全性**，向下滚动找到安全性提示，点击 **「仍要打开」**。
3. **终端解决（若提示已损坏）**：在终端执行 \`xattr -cr /Applications/NookClip.app\` 即可清除隔离标记正常启动。

---

Because NookClip is currently distributed without an Apple Developer notarization certificate, macOS Gatekeeper may show **\"cannot be opened because the developer cannot be verified\"** or **\"is blocked\"** on first launch:

1. **Recommended**: Locate **NookClip.app** in Finder, **press and hold the Control key while clicking (or right-click)**, select \"Open\", and click \"Open\" in the confirmation dialog.
2. **Alternative**: Open **System Settings -> Privacy & Security**, scroll down to the Security section, and click **\"Open Anyway\"**.
3. **Terminal fix (if marked damaged)**: Run \`xattr -cr /Applications/NookClip.app\` in Terminal to clear the quarantine flag.
"

if [[ -n "$CUSTOM_NOTES" ]]; then
  NOTES="${CUSTOM_NOTES}

${GATEKEEPER_TIPS}"
else
  NOTES="## NookClip v${VER}

${EXTRACTED_NOTES}

${GATEKEEPER_TIPS}"
fi
TAG="v$VER"

# 1. 版本号格式校验
if [[ ! "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "error: 版本号 '$VER' 不符合语义化版本格式（如 1.0.1）" >&2
  exit 1
fi

# 2. Sparkle 依赖版本校验
if ! grep -q "exact: \"$SPARKLE_VERSION\"" "$ROOT/platform/macOS/Package.swift"; then
  echo "error: Package.swift 中 Sparkle 版本与脚本 SPARKLE_VERSION=$SPARKLE_VERSION 不一致" >&2
  exit 1
fi

# 3. 分支与工作区校验
CURRENT_BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
if [[ "$DRY_RUN" = false ]]; then
  if [[ "$CURRENT_BRANCH" != "main" ]]; then
    echo "error: 正式发布必须在 'main' 分支执行（当前处于: $CURRENT_BRANCH）" >&2
    exit 1
  fi
  if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
    echo "error: 工作区存在未提交代码，请先提交或暂存后再发布" >&2
    git -C "$ROOT" status --short
    exit 1
  fi
else
  echo "==> [Dry-Run 模式] 当前分支: $CURRENT_BRANCH"
fi

# 4. 凭证检查
if [[ "$DRY_RUN" = false ]]; then
  [[ -f "$GITHUB_TOKEN_FILE" ]] || { echo "error: 缺少 GitHub 令牌 $GITHUB_TOKEN_FILE" >&2; exit 1; }
  GITHUB_TOKEN="$(<"$GITHUB_TOKEN_FILE")"
  [[ -f "$GITEE_TOKEN_FILE" ]] || { echo "error: 缺少 Gitee 令牌 $GITEE_TOKEN_FILE" >&2; exit 1; }
  GITEE_TOKEN="$(<"$GITEE_TOKEN_FILE")"
fi

[[ -f "$EDDSA_KEY" ]] || { echo "error: 缺少 Sparkle EdDSA 私钥 $EDDSA_KEY" >&2; exit 1; }

# Sparkle 工具（按需下载并缓存）
if [[ ! -x "$SPARKLE_TOOLS/bin/generate_appcast" ]]; then
  echo "==> 下载 Sparkle $SPARKLE_VERSION 工具到 $SPARKLE_TOOLS ..."
  mkdir -p "$SPARKLE_TOOLS"
  curl -fSL -o "$SPARKLE_TOOLS/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  tar -xf "$SPARKLE_TOOLS/sparkle.tar.xz" -C "$SPARKLE_TOOLS"
  rm -f "$SPARKLE_TOOLS/sparkle.tar.xz"
fi

# 5. 双端测试门禁
echo "==> [门禁 1/2] 运行 Rust 单元测试..."
cargo test --workspace --quiet

echo "==> [门禁 2/2] 运行 Swift 单元测试..."
pkill -x NookClip 2>/dev/null || true
pkill -x Nook 2>/dev/null || true
pkill -f "swift-test" 2>/dev/null || true
swift test --package-path platform/macOS

# 6. 版本号同步更新 (Info.plist + Cargo.toml + site/index.html)
echo "==> 更新版本号为 $VER..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VER" "$PLIST"

python3 - "$CARGO_TOML" "$VER" <<'PYEOF'
import re, sys
path, ver = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()
new_content = re.sub(
    r'(\[workspace\.package\][^\[]*?version\s*=\s*)"[^"]+"',
    rf'\g<1>"{ver}"',
    content,
    count=1
)
with open(path, "w", encoding="utf-8") as f:
    f.write(new_content)
PYEOF

if [[ -f "$SITE_INDEX" ]]; then
  python3 - "$SITE_INDEX" "$VER" <<'PYEOF'
import re, sys
path, ver = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()
new_content = re.sub(
    r'(<span class="brand-badge">)v[^<]+(</span>)',
    rf'\g<1>v{ver}\g<2>',
    content,
    count=1
)
with open(path, "w", encoding="utf-8") as f:
    f.write(new_content)
PYEOF
  echo "    已同步更新落地页 $SITE_INDEX 徽标版本号"
fi

# 如果发版说明直接从 [Unreleased] 提取，自动将 CHANGELOG.md 中的 [Unreleased] 归档为 [VER] - YYYY-MM-DD
if [[ "$FROM_UNRELEASED" = true ]]; then
  TODAY="$(date +%Y-%m-%d)"
  python3 - "$CHANGELOG_FILE" "$VER" "$TODAY" <<'PYEOF'
import re, sys
path, ver, today = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()
replacement = rf"## [Unreleased]\n\n---\n\n## [{ver}] - {today}"
new_content = re.sub(r'##\s*\[Unreleased\]', replacement, content, count=1)
with open(path, "w", encoding="utf-8") as f:
    f.write(new_content)
PYEOF
  echo "    已自动将 CHANGELOG.md 中的 [Unreleased] 归档为 [$VER] - $TODAY"
fi
# 7. 构建 Universal DMG
echo "==> 构建 Universal 双架构 DMG 产物..."
zsh "$ROOT/scripts/build-dmg.sh" --universal

DMG_ASSET="NookClip-$VER.dmg"

# 8. 生成 GitHub 与 Gitee 两套 Appcast 清单（带 EdDSA 签名）
echo "==> 生成并签名 Sparkle 更新清单 (Appcast)..."
rm -rf "$STAGING"
for SRC in github gitee; do
  DIR="$STAGING/$SRC"
  mkdir -p "$DIR"
  cp "$DMG" "$DIR/$DMG_ASSET"
  cp "$DMG" "$DIR/NookClip.dmg"
  if [[ "$SRC" == github ]]; then
    PREFIX="https://github.com/$GITHUB_OWNER_REPO/releases/download/$TAG"
  else
    PREFIX="https://gitee.com/$GITEE_OWNER_REPO/releases/download/$TAG"
  fi
  "$SPARKLE_TOOLS/bin/generate_appcast" \
    --ed-key-file "$EDDSA_KEY" \
    --download-url-prefix "$PREFIX/" \
    --link "https://github.com/$GITHUB_OWNER_REPO" \
    -o "$DIR/appcast.xml" \
    "$DIR"
  echo "    $SRC appcast 生成完毕"
done

# 如果是 Dry-Run 模式，在此正常退出并恢复版本文件
if [[ "$DRY_RUN" = true ]]; then
  echo ""
  echo "=========================================="
  echo "🎉 [Dry-Run 演练成功完成]"
  echo "1. 测试门禁通过 (Rust + Swift)"
  echo "2. DMG 产物已生成: $DMG"
  echo "3. SHA256 校验和: $(cat "$DMG.sha256")"
  echo "4. Appcast 已生成并完成 EdDSA 签名"
  echo "注意: 未执行 Git 提交、未打 Tag、未上传远程资产。"
  echo "=========================================="
  # 恢复被修改的版本号文件，保持工作区干净
  git -C "$ROOT" checkout "$PLIST" "$CARGO_TOML"
  [[ -f "$SITE_INDEX" ]] && git -C "$ROOT" checkout "$SITE_INDEX"
  [[ "$FROM_UNRELEASED" = true ]] && git -C "$ROOT" checkout "$CHANGELOG_FILE"
  exit 0
fi

# 9. Git 提交与打 Tag
echo "==> 提交版本与创建 Git Tag: $TAG..."
git -C "$ROOT" add "$PLIST" "$CARGO_TOML"
[[ -f "$SITE_INDEX" ]] && git -C "$ROOT" add "$SITE_INDEX"
[[ "$FROM_UNRELEASED" = true ]] && git -C "$ROOT" add "$CHANGELOG_FILE"
if ! git -C "$ROOT" diff --cached --quiet; then
  git -C "$ROOT" commit -m "release: $TAG" --quiet
fi
git -C "$ROOT" tag -f "$TAG"
# 10. 推送代码与远端发布
echo "==> GitHub 发布 $TAG ..."
git -C "$ROOT" push origin main
git -C "$ROOT" push -f origin "$TAG"

github_api() {
  local method="$1" endpoint="$2"; shift 2
  curl -fsSL -X "$method" "https://api.github.com$endpoint" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" "$@"
}

github_release_id() {
  github_api GET "/repos/$GITHUB_OWNER_REPO/releases/tags/$1" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true
}

github_upload_asset() {
  local rid="$1" file="$2" name asset_id
  name="$(basename "$file")"
  asset_id="$(github_api GET "/repos/$GITHUB_OWNER_REPO/releases/$rid" \
    | python3 -c "
import json,sys
for a in json.load(sys.stdin).get('assets', []):
    if a.get('name') == '$name':
        print(a.get('id')); break
")"
  if [[ -n "$asset_id" ]]; then
    github_api DELETE "/repos/$GITHUB_OWNER_REPO/releases/assets/$asset_id" >/dev/null
  fi
  curl -fsSL -X POST \
    "https://uploads.github.com/repos/$GITHUB_OWNER_REPO/releases/$rid/assets?name=$name" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@$file" >/dev/null
}

GH_RELEASE_JSON="$(python3 - "$TAG" "$VER" "$NOTES" <<'PYEOF'
import json, sys
tag, ver, notes = sys.argv[1:4]
print(json.dumps({"tag_name": tag, "name": tag, "body": notes, "make_latest": "true"}))
PYEOF
)"

VREL_ID="$(github_release_id "$TAG")"
if [[ -z "$VREL_ID" ]]; then
  VREL_ID="$(github_api POST "/repos/$GITHUB_OWNER_REPO/releases" \
    -H 'Content-Type: application/json' -d "$GH_RELEASE_JSON" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
else
  github_api PATCH "/repos/$GITHUB_OWNER_REPO/releases/$VREL_ID" \
    -H 'Content-Type: application/json' -d "$GH_RELEASE_JSON" >/dev/null
fi
github_upload_asset "$VREL_ID" "$STAGING/github/$DMG_ASSET"
github_upload_asset "$VREL_ID" "$STAGING/github/NookClip.dmg"

# 固定 appcast release
git -C "$ROOT" push -f origin "$APPCAST_TAG" 2>/dev/null || true
APPCAST_REL_ID="$(github_release_id "$APPCAST_TAG")"
if [[ -z "$APPCAST_REL_ID" ]]; then
  APPCAST_REL_ID="$(github_api POST "/repos/$GITHUB_OWNER_REPO/releases" \
    -H 'Content-Type: application/json' \
    -d "{\"tag_name\": \"$APPCAST_TAG\", \"name\": \"appcast\", \"body\": \"Sparkle 更新清单（自动覆盖）\", \"make_latest\": \"false\"}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
else
  github_api PATCH "/repos/$GITHUB_OWNER_REPO/releases/$APPCAST_REL_ID" \
    -H 'Content-Type: application/json' \
    -d "{\"make_latest\": \"false\"}" >/dev/null || true
fi
github_upload_asset "$APPCAST_REL_ID" "$STAGING/github/appcast.xml"
echo "==> GitHub 发布完成"

# 11. Gitee 发布
if ! git -C "$ROOT" remote | grep -qx gitee; then
  git -C "$ROOT" remote add gitee "https://gitee.com/${GITEE_OWNER_REPO}.git"
fi

echo "==> Gitee 发布 $TAG ..."
git -C "$ROOT" push gitee main
git -C "$ROOT" push gitee -f "$TAG"

gitee_api() {
  local method="$1" endpoint="$2"; shift 2
  curl -fsSL -X "$method" "https://gitee.com/api/v5$endpoint" "$@"
}

gitee_release_id() {
  gitee_api GET "/repos/$GITEE_OWNER_REPO/releases/tags/$1?access_token=$GITEE_TOKEN" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true
}

RELEASE_JSON="$(python3 - "$TAG" "$VER" "$NOTES" <<'PYEOF'
import json, sys
tag, ver, notes = sys.argv[1:4]
print(json.dumps({"tag_name": tag, "name": tag, "body": notes,
                  "prerelease": False, "secret_release": False,
                  "target_commitish": "main"}))
PYEOF
)"

VREL_ID="$(gitee_release_id "$TAG")"
if [[ -z "$VREL_ID" ]]; then
  VREL_ID="$(gitee_api POST "/repos/$GITEE_OWNER_REPO/releases?access_token=$GITEE_TOKEN" \
    -H 'Content-Type: application/json' -d "$RELEASE_JSON" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
else
  gitee_api PATCH "/repos/$GITEE_OWNER_REPO/releases/$VREL_ID?access_token=$GITEE_TOKEN" \
    -H 'Content-Type: application/json' -d "$RELEASE_JSON" >/dev/null
fi
OLD_DMG_IDS="$(gitee_api GET "/repos/$GITEE_OWNER_REPO/releases/$VREL_ID?access_token=$GITEE_TOKEN" 2>/dev/null \
  | python3 -c '
import json,sys
r=json.load(sys.stdin)
for f in r.get("attach_files") or []:
    if f.get("name") in ("'"$DMG_ASSET"'", "NookClip.dmg"):
        print(f.get("id"))
' 2>/dev/null || true)"
for AID in ${(f)OLD_DMG_IDS}; do
  [[ -n "$AID" ]] && gitee_api DELETE "/repos/$GITEE_OWNER_REPO/releases/$VREL_ID/attach_files/$AID?access_token=$GITEE_TOKEN" >/dev/null || true
done
gitee_api POST "/repos/$GITEE_OWNER_REPO/releases/$VREL_ID/attach_files?access_token=$GITEE_TOKEN" \
  -F "file=@$STAGING/gitee/$DMG_ASSET" >/dev/null
gitee_api POST "/repos/$GITEE_OWNER_REPO/releases/$VREL_ID/attach_files?access_token=$GITEE_TOKEN" \
  -F "file=@$STAGING/gitee/NookClip.dmg" >/dev/null

git -C "$ROOT" push gitee -f "$APPCAST_TAG" 2>/dev/null || true
APPCAST_REL_ID="$(gitee_release_id "$APPCAST_TAG")"
if [[ -z "$APPCAST_REL_ID" ]]; then
  APPCAST_REL_ID="$(gitee_api POST "/repos/$GITEE_OWNER_REPO/releases?access_token=$GITEE_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "{\"tag_name\": \"$APPCAST_TAG\", \"name\": \"appcast\", \"body\": \"Sparkle 更新清单（自动覆盖）\", \"target_commitish\": \"main\"}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
fi

OLD_ATTACH_IDS="$(gitee_api GET "/repos/$GITEE_OWNER_REPO/releases/$APPCAST_REL_ID?access_token=$GITEE_TOKEN" 2>/dev/null \
  | python3 -c '
import json,sys
r=json.load(sys.stdin)
for f in r.get("attach_files") or []:
    if f.get("name") == "appcast.xml":
        print(f.get("id"))
' 2>/dev/null || true)"
for AID in ${(f)OLD_ATTACH_IDS}; do
  [[ -n "$AID" ]] && gitee_api DELETE "/repos/$GITEE_OWNER_REPO/releases/$APPCAST_REL_ID/attach_files/$AID?access_token=$GITEE_TOKEN" >/dev/null || true
done
gitee_api POST "/repos/$GITEE_OWNER_REPO/releases/$APPCAST_REL_ID/attach_files?access_token=$GITEE_TOKEN" \
  -F "file=@$STAGING/gitee/appcast.xml" >/dev/null

rm -rf "$STAGING"
echo ""
echo "=========================================="
echo "✅ 发布完成: NookClip $VER"
echo "   GitHub: https://github.com/$GITHUB_OWNER_REPO/releases/tag/$TAG"
echo "   Gitee:  https://gitee.com/$GITEE_OWNER_REPO/releases/tag/$TAG"
echo "=========================================="
