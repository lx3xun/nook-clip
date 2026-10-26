# 贡献指南 (Contributing)

感谢你关注 NookClip！

## 环境

- macOS 14.0+
- Xcode 15+ 或 Swift 6 工具链（需完整 Xcode 以交叉编译 x86_64）

## 快速开始

```bash
git clone https://github.com/lx3xun/nook-clip.git
cd nook-clip
swift build --package-path platform/macOS
swift test --package-path platform/macOS
```

## 提交规范

- 提交信息使用 Conventional Commits：`type(scope): 摘要`（中英文均可，描述清楚即可）。常用类型：`feat` / `fix` / `docs` / `refactor` / `test` / `chore` / `build` / `perf` / `ui`；其他合法 Conventional 类型（如 `style`）亦可。
- 一次提交聚焦一件事；重构与功能变更分开提交。

## PR 要求

1. **必须通过全部测试**：`swift test --package-path platform/macOS` 保持零失败。
2. **新功能附带测试**：覆盖行为、边界与回归场景；不测试纯接线代码。
3. **三语文案同步**：改动用户可见文案时，`platform/macOS/Sources/NookClip/Resources/{en,zh-Hans,zh-Hant}.lproj/Localizable.strings` 三份同步更新（中文用「剪贴板」）。
4. **更新 CHANGELOG**：在 `[未发布]` 段补充条目（Keep a Changelog 格式）。
5. **UI 改动**：遵循原生 macOS 视觉语言；布局令牌调整需在 PR 描述中说明理由。
6. **隐私红线**：任何改动不得引入网络上报、不得让敏感明文进入索引或云端。
7. **贡献者许可约定（CLA）**：提交 PR 即表示你同意将所贡献代码的版权非独占、不可撤销、全球免费地授权给项目维护者（`lx3xun`），使其可同时用于开源 GPLv3 版本以及官方签名/App Store 商业分发版本。

## 测试注意事项

- 测试使用进程私有命名剪贴板（`PasteboardAccess`），不会污染系统剪贴板与真实历史库；请勿在测试中直接使用 `NSPasteboard.general`。
- 涉及剪贴板的用例请包裹 `withPasteboardLock { }`。
- UserDefaults 一律用 `makeIsolatedDefaults()` 注入，不写共享域。例外：被测对象本身硬编码读取 `.standard`（单例如 `PasteService.shared`、SwiftUI `@AppStorage`），且注入改造代价过高时，允许「快照原值 → 修改 → teardown 恢复原值」的临时写入模式，必须在测试内注释说明原因。

## 目录速览

见 [README.md](README.md#-项目结构) 的项目结构一节。
