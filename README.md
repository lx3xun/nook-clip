# <img src="assets/logo-kit/exports/nookclip-appicon-128.png" width="36" height="36" alt="NookClip App Icon" style="vertical-align: middle; margin-right: 8px;"> NookClip

**轻量、快速、注重隐私的剪贴板管理工具。**

[介绍页](https://lx3xun.github.io/nook-clip/) · [简体中文](README.md) · [繁體中文](README.zh-TW.md) · [English](README.en.md)

[![Website](https://img.shields.io/badge/Website-NookClip-1677FF?logo=safari&logoColor=white)](https://lx3xun.github.io/nook-clip/)
[![macOS 14.0+](https://img.shields.io/badge/macOS-14.0%2B-007AFF?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift 5.10+](https://img.shields.io/badge/Swift-5.10%2B-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Rust 1.75+](https://img.shields.io/badge/Rust-Core_Engine-000000?logo=rust&logoColor=white)](https://www.rust-lang.org)
[![License GPLv3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

## 💡 解决什么问题

日常使用电脑时，系统剪贴板往往有几个很别扭的地方：

- **随手一复制，旧内容就没了**：刚复制的代码、链接或段落，被下一条复制直接冲掉，常常要返回原来的页面重新找。
- **历史记录越积越多，很难找**：很多工具只支持按时间一页页翻，或者搜索慢、不支持拼音与截图里的文字。
- **担心密码和凭证被窃取**：剪贴板里经常出现 API 密钥、密码、连接串等敏感信息。很多工具不仅联网打点、上传统计，甚至把历史记录传上云端。
- **后台工具太重、耗内存**：常驻后台动辄占用几百兆内存，呼出时还会卡一下。

**NookClip 就是为了解决这些问题而写的一个轻量剪贴板工具：**

底层用 Rust 存储与检索，界面走原生开发，常驻内存约 20 MB，快捷键呼出无延迟。同时明确隐私底线：**没有账号、没有联网打点与崩溃上报，全部历史记录都只保存在你的本地设备上**。

| 浅色模式（Light） | 深色模式（Dark） |
| :---: | :---: |
| ![NookClip 浅色模式](site/assets/nookclip-light.png) | ![NookClip 深色模式](site/assets/nookclip-dark.png) |

---

## 功能一览

### 剪贴板记录与快速查找
- **快捷键呼出**：默认按 `⌘ ⇧ V` 呼出面板，随选随粘，失去焦点或按 `Esc` 自动退出。
- **打字直接搜**：呼出面板后无需专门点搜索框，直接敲键盘就能开始搜索。
- **应用启动**：搜索框支持输入已安装应用名或中文拼音（如 `wx` 找微信、`zd` 找终端），回车直接打开应用。
- **全文搜索与图片文字搜索**：基于 SQLite FTS5 全文索引，支持直接搜索历史文字、网址，以及自动识别出的截图文字（OCR），搜索结果高亮显示。
- **分类筛选**：支持按文本、图片、文件、链接、代码、色值、敏感凭证等类型快速筛选。

### 内容识别与预览
- **离线图片文字识别（OCR）**：使用系统自带离线视觉能力识别截图中的文字，既能直接搜图里的字，也能一键把文字复制出来。
- **代码高亮与 JSON 格式化**：代码自动高亮显示；识别到 JSON 时支持一键展开美化、压缩或复制。
- **链接生成二维码**：识别到网址后，可在预览区直接生成二维码，方便手机扫码打开。
- **色值即时预览**：识别到十六进制颜色值（如 `#FF5722`）会在列表中直接显示色点，右侧支持一键复制 HEX / RGB。
- **失效文件保护**：如果复制的文件已被删除或移动，粘贴前会明确提示，避免误粘失效路径。

### 敏感信息防护
- **敏感凭证识别**：自动识别 API Key（OpenAI、AWS 等）、Token、私钥和含密码的数据库连接串。
- **本地加密存储**：敏感记录使用 AES-256-GCM 加密后存入本地数据库，主密钥由系统钥匙串与本地受保护文件共同保管。
- **防窥遮罩**：列表中默认使用 `••••••••` 掩码显示，支持 30 秒后自动重锁。
- **不上云、不进索引**：敏感信息不会写入全文搜索索引，开启同步时也不会上传。
- **黑名单排除**：支持将 1Password、密码管理器等敏感应用加入黑名单，切到前台时自动暂停记录。

### 更多实用功能
- **iCloud Drive 同步**：通过个人 iCloud 云盘在多台设备间同步文本与收藏（可选开启，无需第三方服务器）。
- **备份与导出**：支持导出 JSON 或 Markdown 格式，导出时可选择排除或遮码敏感记录。
- **批量操作与撤销**：支持按住 Shift 或 ⌘ 多选、合并粘贴与批量删除；删除后支持 10 秒内按 `⌘ Z` 撤销。

---
## ⌨️ 快捷键指南

| 快捷键 | 操作说明 |
| :--- | :--- |
| **`⌘ ⇧ V`** | 全局呼出 / 隐藏面板（可在「设置 → 粘贴」中录制自定义或选预设） |
| **`↑` / `↓`** | 上下移动选中项（长按连续移动，触底自动扩页） |
| **`⇧ ↑` / `⇧ ↓` / `⌘ 点选`** | 扩展批量多选（多选后按 `⏎` 合并粘贴，按 `⌘ ⌫` 批量删除） |
| **`⏎`** | 粘贴选中项到当前前台应用 / 启动选中的应用程序 |
| **`⌥ ⏎`** | 纯文本粘贴（自动剔除字体、颜色、背景等富文本格式） |
| **`⌘ ⏎`** | 粘贴且保持面板打开（适合连续填表与比对） |
| **`⌘ C`** | 重新复制选中项到系统剪贴板（列表态复制整条，预览区支持划词复制） |
| **`⌘ [` / `⌘ ]`** | 左右循环切换分类（`⌘ ]` 下一个，`⌘ [` 上一个） |
| **`⌘ ↓`** | 打开 / 收起更多分类下拉菜单 |
| **`⌘ F`** | 聚焦搜索框（列表态下直接敲击字母/数字也可直接输入搜索） |
| **`⌘ T`** | 循环跳转下一个时间分组（今天 → 昨天 → 本周 → … → 回到顶部） |
| **`⌘ S`** | 收藏 / 取消收藏选中项（收藏条目豁免过期清理与容量淘汰） |
| **`⌘ R`** | 为选中项设置自定义别名（留空回车清除别名） |
| **`⌘ ⌫`** | 删除选中项（10 秒内可撤销） |
| **`⌘ Z`** | 撤销最近一次删除 |
| **`Esc`** | 分层返回：关闭下拉菜单 → 退出多选 → 清空搜索词 → 重置分类与时间筛选 → 收起面板 |

---

## 📦 下载与安装

### 方式一：下载安装包（DMG）

推荐直接下载通用安装包（Universal 二进制，原生支持 Apple Silicon `arm64` 与 Intel `x86_64`）：

- **GitHub 镜像直链**：[下载 NookClip.dmg (最新版本)](https://github.com/lx3xun/nook-clip/releases/latest/download/NookClip.dmg)
- **Gitee 镜像直链（国内加速）**：[前往 Gitee 发行版下载](https://gitee.com/lx3xun/nook-clip/releases)
- **所有版本历史**：前往 [GitHub Releases](https://github.com/lx3xun/nook-clip/releases)

下载后双击打开 `.dmg`，将 **NookClip** 拖入 **Applications（应用程序）** 文件夹即可。

> **⚠️ 首次打开与权限提示（开源 Ad-hoc 签名版本）**
>
> 本开源版本未接入付费 Apple Developer 公证，采用本地 ad-hoc 签名，首次启动可能触发 macOS Gatekeeper 安全提示：
>
> 1. **提示「无法打开，因为无法验证开发者」**：在访达（Finder）中找到 `/Applications/NookClip.app`，**按住 Control 键点按（或右键）→ 选择「打开」**，在弹出对话框中再次点击「打开」。
> 2. **提示「已损坏，移到废纸篓」**：打开终端（Terminal）执行以下命令清除下载隔离扩展属性：
>    ```bash
>    xattr -cr /Applications/NookClip.app
>    ```
> 3. **辅助功能权限（自动粘贴必需）**：前往 **「系统设置 → 隐私与安全性 → 辅助功能」** 开启 **NookClip**。若版本覆盖更新后无法自动粘贴，请先在列表中选中 NookClip 点击 `[-]` 移除，再重新点击 `[+]` 添加勾选即可。

### 方式二：从源码一键构建（推荐开发者，无 Gatekeeper 拦截）

```bash
git clone https://github.com/lx3xun/nook-clip.git
cd nook-clip
zsh scripts/build.sh app --universal   # 产出 dist/NookClip.app（arm64 + x86_64）
cp -R dist/NookClip.app /Applications/
```

**编译环境要求**：
- macOS 14.0 (Sonoma) 或更高版本
- Xcode 15+ 或 Swift 5.10+ Command Line Tools
- Rust 1.75+ 工具链（构建双架构 Universal 包时需安装 `aarch64-apple-darwin` 与 `x86_64-apple-darwin` target）

---

## 隐私与数据安全

NookClip 的设计原则是「默认本地、绝不上报」：

1. **不采集任何数据**：无账号、无行为统计、无崩溃上报。
2. **明确的网络请求场景**：仅在检查新版本更新（可在设置中关闭），或你主动开启 iCloud Drive 同步时才会有网络读写。
3. **敏感凭据本地加密**：识别到的密码与 Key 在存盘时使用 AES-256-GCM 加密，主密钥保存在本地与系统钥匙串中。
4. **敏感内容隔离**：被标记为敏感的信息绝不写入全文搜索索引，开启 iCloud 同步时也不会上传。
5. **数据路径全本地透明**：
   ```text
   ~/Library/Application Support/com.lx3xun.nookclip/
   ├── library.db       # SQLite 数据库（本地历史记录与索引）
   ├── Content/         # 本地图片与文件缓存
   └── .master_key      # 加密主密钥文件
   ```

---

## 🛠 开发与构建

### 项目结构

```text
nook-clip/
├── crates/                        # Rust 核心工作区（跨平台存储、全文检索、同步与加密）
│   ├── nook-core/                 # 核心业务引擎（SQLite WAL + FTS5、AES-256-GCM、Zstd 同步包、脱敏导出）
│   └── nook-ffi/                  # UniFFI 0.28 绑定层（生成 Swift / C 桥接代码与静态库）
├── platform/macOS/                # macOS 原生客户端（Swift Package）
│   ├── Package.swift              # SwiftPM 依赖配置（Sparkle 2）
│   ├── Sources/NookClip/
│   │   ├── App/                   # 应用生命周期、无边框悬浮面板（DraggablePanel）、全局热键与键盘分发
│   │   ├── Clipboard/             # 剪贴板监听、自动粘贴、敏感检测、应用排除与语言分类
│   │   ├── CoreBridge/            # UniFFI 生成的 Swift 桥接接口
│   │   ├── Crypto/                # 0600 密钥文件与 Keychain 协同服务
│   │   ├── Localization/          # 三语即时切换管理（zh-Hans / zh-Hant / en）
│   │   ├── Resources/             # 多语言文案（Localizable.strings）与应用图标资源
│   │   ├── Search/                # 本地应用检索（含拼音索引）、Vision 离线 OCR、搜索解析
│   │   ├── Storage/               # Rust 存储封装、iCloud Drive 同步引擎与保留期清理策略
│   │   └── UI/                    # SwiftUI 主视图、富预览卡片（代码/JSON/OCR/二维码/色值）与设置页
│   ├── Tests/NookClipTests/       # 单元与集成测试套件（进程私有剪贴板隔离）
│   └── Packaging/                 # Info.plist 与 entitlements 签名配置
├── scripts/                       # 统一构建、打包与发布脚本（build.sh / build-app.sh / build-dmg.sh / release.sh）
├── README.md                      # 简体中文文档
├── README.zh-TW.md                # 繁體中文文檔
└── README.en.md                   # English Documentation
```

### 常用开发命令

```bash
# 1. 日常极速开发（Debug 增量构建，Rust 无改动时 0 秒跳过）
zsh scripts/build.sh dev

# 2. 增量构建并立即启动本地 NookClip.app
zsh scripts/build.sh run

# 3. 单独编译 Rust 核心并重新生成 UniFFI Swift 绑定
zsh scripts/build.sh rust

# 4. 打包发布级双架构 Universal .app 与 .dmg（含 SHA256 校验）
zsh scripts/build.sh app --universal
zsh scripts/build.sh dmg --universal

# 5. 清理构建产物与缓存
zsh scripts/build.sh clean
```

### 运行测试

测试套件全程使用进程私有命名剪贴板与临时隔离数据库，**绝不会污染你的系统剪贴板或真实历史记录**：

```bash
# 运行 Rust 核心层单元测试与集成测试
cargo test --workspace

# 运行 macOS Swift 单元与集成测试
swift test --package-path platform/macOS

# 运行万级数据量性能基准测试（5k / 10k / 50k 阈值校验，默认跳过）
NOOK_PERF=1 swift test --package-path platform/macOS --filter PerformanceBenchmarkTests
```

### 参与贡献

欢迎提交 Issue 与 Pull Request！请参阅 [CONTRIBUTING.md](CONTRIBUTING.md) 了解代码规范、三语文案同步要求与测试隔离准则。若发现安全或隐私相关漏洞，请勿提交公开 Issue，请按 [SECURITY.md](SECURITY.md) 指引私密报告。

---

## 📄 开源协议与商标声明

- **开源授权**：本项目源代码基于 [GNU General Public License v3.0 (GPLv3)](LICENSE) 协议开源。任何基于本项目的修改或衍生分发必须同样采用 GPLv3 协议开放全部源代码。
- **商业分发与 App Store 独占权**：原始版权所有人（`lx3xun`）保留在 Apple App Store 及官方商业渠道独家分发公证安装包（Notarized Binary）及闭源商业扩展版本的全部权利。未经书面许可，任何第三方不得将本项目或其衍生版本上架至 Apple App Store 或其他商业应用商店。
- **品牌与商标保护**：依据 GPLv3 第 7(e) 条附加条款，**“Nook”**、**“NookClip”** 名称、应用图标（`AppIcon.icns` / `NookClipIcon.svg`）及相关品牌视觉标识归 `lx3xun` 独家所有，不在开源许可授权范围内。第三方修改或重新分发的版本必须移除上述品牌标识与名称。

[GPLv3](LICENSE) © 2026 lx3xun
