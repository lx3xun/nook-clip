# NookClip — 品牌标识与设计规范 (Brand Guidelines)

> 轻量、快速、注重隐私的桌面效率工作台（剪贴板 · 便签笔记 · 待办清单）

---

## 1. 标识核心理念 (Core Idea)

- **核心符号：** **The N-Card Monogram (E3)**。
- **创意阐述：** 100% 传承原版白底圆角卡片与标志性电光蓝条的视觉认知，将原版分散的横线重构为咬合严密的品牌大写字母「N」；左柱代表剪贴板历史沉淀，45° 对角折线象征随手笔记，右柱电光蓝胶囊代表待办推进与完成。
- **设计哲学：** 识别大于解释（Identifier, not an explanation）。纯几何构建、去拟物化、全尺寸自洽（从 16px 菜单栏到 1024px 高清 App 图标）。

---

## 2. 规范色彩体系 (Color Palette)

| 色彩角色 | 色板名称 | HEX | RGB | CMYK | 适用场景 |
|---|---|---|---|---|---|
| **主品牌色** | Electric Blue | `#1677FF` | 22, 119, 255 | 80, 50, 0, 0 | 动作胶囊、主按钮、高亮焦点 |
| **深色底色** | Slate Navy | `#0F172A` | 15, 23, 42 | 85, 75, 50, 60 | 深色卡片基座、主文本、深色模式 |
| **中性过渡色** | Muted Slate | `#64748B` | 100, 116, 139 | 60, 45, 35, 10 | 笔记折线、次级条目、边框 |
| **纯净背景** | Pure White | `#FFFFFF` | 255, 255, 255 | 0, 0, 0, 0 | 浅色卡片底色、反白标识 |
| **浅灰底衬** | Soft Slate | `#F1F5F9` | 241, 245, 249 | 4, 2, 2, 0 | 浅色模式背景、条目填充 |

---

## 3. 安全空间与最小尺寸 (Clear Space & Minimum Size)

### 安全空间 (Clear Space)
- 标识四周必须保留至少 **1 × W** 的安全呼吸空间（$W$ = 符号内部单根纵柱的宽度，即画幅的 1/8）。
- 在此区域内严禁放置任何其他文字、按钮或装饰图形。

### 最小可用尺寸 (Minimum Size)
- **横向组合 (Horizontal Lockup)：** 屏幕显示最小宽度为 **96 px**；
- **独立图形符号 (Symbol)：** 屏幕显示最小为 **16 px**（必须使用专用 `nookclip-symbol-small.svg` 或 `MenuBarIcon.svg`）。

---

## 4. 交付文件清单 (Asset Manifest)

所有成品文件已存放在 `assets/logo-kit/` 与 `assets/logo-kit/exports/`：

### 核心矢量源文件
- `assets/logo-kit/nookclip-symbol.svg`：标准全彩符号主文件
- `assets/logo-kit/nookclip-symbol-solid.svg`：100% 单色矢量主文件（纯黑，无虚假白色遮罩）
- `assets/logo-kit/nookclip-symbol-small.svg`：16px / 32px 专用的粗笔画微缩文件
- `assets/logo-kit/nookclip-lockup-horizontal.svg`：标准横向组合（符号 + NookClip）
- `assets/logo-kit/nookclip-lockup-stacked.svg`：标准方块堆叠组合（符号 + 居中名称）
- `assets/logo-kit/nookclip-appicon.svg`：1024×1024 macOS 原生圆角 App 图标（可直接替换原 `site/assets/nookclip-icon.svg`）
- `assets/logo-kit/MenuBarIcon.svg`：macOS 顶部菜单栏 22×22 像素专用模板图标

### Web & 导出资源包 (`exports/`)
- `exports/favicon.ico`：包含 16/32/48px 的多尺寸 Favicon
- `exports/favicon-16.png`、`favicon-32.png`、`favicon-48.png`
- `exports/apple-touch-icon.png` (180×180)
- `exports/icon-192.png`、`icon-512.png`、`maskable-512.png`
- `exports/site.webmanifest` & `exports/head-snippet.html`
- `exports/nookclip-appicon-1024.png`、`512.png`、`256.png`、`128.png`
- `exports/nookclip-lockup-horizontal-1200.png`

### 演示板与行业 Mockup
- `assets/logo-kit/presentation.html`：交互式客户演示板（包含 README、终端、App 图标等 6 种场景）
- `assets/logo-kit/slides/slide-01.png` ~ `slide-05.png`：5 张高清幻灯片

---

## 5. 使用禁忌 (Don'ts)

1. **严禁拉伸变形：** 缩放时必须保持等比例约束（1:1）；
2. **严禁使用未授权的色彩搭配：** 不得随意将主电光蓝替换为其他未经定义的杂色；
3. **严禁拆解重组：** 不得随意改变纵柱与折角的距离或角度（严格遵循 45° 几何线）；
4. **单色场景使用规范：** 在单色印刷或单色屏幕环境下，必须使用 `nookclip-symbol-solid.svg`，严禁直接使用全彩版转灰度。
