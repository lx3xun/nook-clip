# 功能演示动图（生成说明）

`site/assets/features/` 下的 GIF / MP4 / 封面图都是脚本生成的，不是真机录屏。
界面按 SwiftUI 主题令牌（`NookClipTheme.swift`）与真实控件尺寸复刻。

## 目录

| 文件 | 说明 |
| :--- | :--- |
| `paste-stack.mp4` / `.gif` | 顺序粘贴（⌥⏎）：多选 4 条 → 批量栏 → ⌥⏎ → 浮窗逐条贴进目标文档 |
| `scrub-paste.mp4` / `.gif` | 语义脱敏粘贴（⌃⏎）：识别 6 处敏感信息 → 换成占位符 → 贴出脱敏文本 |
| `pinned-note.mp4` / `.gif` | 屏幕置顶贴条（⌘P）：钉在桌面 → 调不透明度 → 折叠/点击穿透 |
| `filter-tags.mp4` / `.gif` | 类型与标签筛选（⌘↓）：展开 8 槽位网格 + 标签流 → 胶囊组合过滤 → ⌘L 打标 → ⌫ 复位 |
| `ocr-search.mp4` / `.gif` | 离线图片文字识别与搜索：点「识别文字」毫秒提取 → 写入 FTS5 索引 → 敲词搜出截图并高亮命中 |
| `all-three.mp4` | 粘贴三进阶拼接整片（约 27 秒，24fps） |
| `poster-*.jpg` | 各段封面图（README 缩略图用） |
| `preview.html` | 带文字说明的展示页，浏览器直接打开即可看完整动态视频 |
| `src/` | 生成器（见下） |

规格：MP4 = 1240×860 / 30fps / H.264；GIF = 820px 宽 / 10fps / 80 色调色板。

## 重新生成

`src/` 里是完整的动画引擎：`player.html`（舞台样式）+ `scenes.js`（三条时间轴）+ `capture.mjs`（headless Chrome 逐帧抓图）。

```bash
cd site/assets/features/src

# 1. 逐帧抓图（每段 276 帧左右，约 30 秒）
node capture.mjs --scene a --fps 30 --duration 9200 --width 1240 --height 860 --dsf 2 --out /tmp/frames/a
node capture.mjs --scene b --fps 30 --duration 8200 --width 1240 --height 860 --dsf 2 --out /tmp/frames/b
node capture.mjs --scene c --fps 30 --duration 9200 --width 1240 --height 860 --dsf 2 --out /tmp/frames/c
node capture.mjs --scene d --fps 30 --duration 8600 --width 1240 --height 860 --dsf 2 --out /tmp/frames/d
node capture.mjs --scene e --fps 30 --duration 8800 --width 1240 --height 860 --dsf 2 --out /tmp/frames/e

# 2. 合成 MP4
for s in a b c d e; do
  ffmpeg -y -framerate 30 -i /tmp/frames/$s/f%04d.jpg \
    -vf "scale=1240:860:flags=lanczos" -c:v libx264 -preset slow -crf 20 \
    -pix_fmt yuv420p -movflags +faststart ../$s.mp4
done

# 3. 合成 GIF
for s in a b c d e; do
  ffmpeg -y -framerate 30 -i /tmp/frames/$s/f%04d.jpg \
    -vf "fps=10,scale=820:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=80:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
    -loop 0 ../$s.gif
done

调试时把 `--fps` 降到 1～4、`--dsf` 用 1，几秒就能出一版缩略预览。

## 关键约定

- `scenes.js` 里所有动效都从时间 `t` 用纯函数算出来，**不用 CSS transition / animation**，这样任意时刻都能 `window.__seek(t)` 复现同一帧，抓帧才不会抖。
- 场景入口是 `?scene=a|b|c|d|e`，时长分别是 9200 / 8200 / 9200 / 8600 / 8800 ms。
- 舞台尺寸固定 1240×860，`--width/--height` 必须和它一致，否则会出黑边。
- Chrome 必须用 `--headless=new`（旧版 `--headless` 在无 GPU 环境下 GPU 进程崩溃后 WebSocket 会断开）。
- 应用图标复用 `site/assets/apps/*.png`。
