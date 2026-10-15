#!/usr/bin/env python3
"""
NookClip 剪贴板测试数据生成器
生成包含 1000 条真实测试数据的 SQLite 数据库记录，覆盖全部 8 种分类：
- 文本 (Text): 150 条
- 代码 / JSON (Code): 200 条
- 链接 (URL): 150 条
- 颜色 (Color): 100 条
- 图片 (Image): 150 条（并在 Content 目录生成真实图片）
- 文件 (File): 150 条
- 敏感信息 (Sensitive): 100 条（AES-256-GCM 真实加密）
- 收藏 (Favorite): 跨分类标记约 150 条 (favorite = 1)
"""

import os
import sys
import json
import uuid
import time
import shutil
import random
import sqlite3
import argparse
from datetime import datetime, timedelta
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from PIL import Image, ImageDraw

DEFAULT_DB_PATH = os.path.expanduser("~/Library/Application Support/com.lx3xun.nookclip/library.db")
DEFAULT_CONTENT_DIR = os.path.expanduser("~/Library/Application Support/com.lx3xun.nookclip/Content")
RUST_MASTER_KEY = bytes([0x42] * 32)


# ==========================================
# 样本数据池
# ==========================================

TEXT_SAMPLES = [
    ("会议待办", "下周一上午 10:00 评审 NookClip 2.0 剪贴板检索性能优化方案，请准备好 FTS 延迟数据对比。"),
    ("产品待办清单", "1. 完善快捷键 Tab 循环切换分类交互\n2. 增加暗黑模式下的对比度调节\n3. 优化大图缩略图解码内存上限\n4. 支持导出格式自定义"),
    ("设计灵感", "少即是多（Less is more）。好的设计是尽可能少的设计，克制、优雅且注重细节。"),
    ("沟通备忘", "张总您好，附件是本季度的技术进展汇报与下个阶段的排期计划，请您查阅指导。"),
    ("技术随笔", "Talk is cheap. Show me the code. —— Linus Torvalds"),
    ("提示词", "请扮演一名资深的 macOS 客户端系统工程师，审查以下 Swift 并发安全与内存泄漏相关代码。"),
    ("读书摘录", "最重要的并不是知道事情的答案，而是知道提出什么样的问题。"),
    ("客服回复模板", "您好，感谢您使用 NookClip！关于您反馈的快捷键冲突问题，您可以在「设置 -> 快捷键」中重新录制全局热键。"),
    ("咖啡订单", "热美式 x 2，冰燕麦拿铁 x 1（不加糖，多冰），肉桂卷 x 1，配送至科技园 A 座 801。"),
    ("发布日志初稿", "v1.2.0 发布：全新分类导航、毫秒级三元组搜索、端到端隐私加密存储。"),
    ("灵感碎片", "在工具类应用中，速度和可靠性才是最重要的用户体验，任何微小的卡顿都会打断专注。"),
    ("读书笔记", "系统思考：整体大于各部分之和，关注元素之间的反馈回路与流动，而非单个静态指标。"),
    ("周报小结", "本周完成：1. 修复剪贴板长文本换行渲染异常；2. 优化 SQLite WAL 模式写入性能；3. 单元测试覆盖率提升至 92%。"),
    ("架构原则", "保持单一事实来源（Single Source of Truth），业务逻辑纯函数化，副作用收口在边缘层。"),
    ("日程提醒", "明天下午 15:30 参加 Apple 开发者线上沟通会，主题：Swift 6 严格并发迁移实践。"),
    ("面试评价", "候选人计算机基础扎实，对 macOS RunLoop、内存管理及底层 POSIX 接口有深入理解，建议录用。"),
    ("用户反馈", "这是我用过最轻巧优雅的剪贴板管理工具，启动飞快，内存占用很低，希望加入更多分类标签！"),
    ("生活备忘", "周末购买：猫粮 1 袋、滤水壶滤芯 2 个、挂耳咖啡 1 盒、吸尘器尘袋。"),
    ("技术原则", "所有的复杂性必须有明确的业务收益作为支撑；如果没有，就应该直接删除多余抽象。"),
    ("格言分享", "Stay hungry, stay foolish. 求知若饥，虚心若愚。"),
]

CODE_SAMPLES = [
    # Swift
    ("swift", "AuroraView.swift", """struct AuroraView: View {
    @State private var phase = 0.0

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let angle = Angle.degrees(now * 30)
                context.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)), with: .color(.accentColor))
            }
        }
    }
}"""),
    ("swift", "ClipboardMonitor.swift", """final class ClipboardMonitor: ObservableObject {
    private var lastChangeCount = 0
    private var timer: Timer?

    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
    }
}"""),
    ("swift", "TaskQueue.swift", """actor TaskQueue {
    private var pending: [() async -> Void] = []
    
    func enqueue(_ task: @escaping () async -> Void) {
        pending.append(task)
    }
}"""),
    # Rust
    ("rust", "repository.rs", """impl StorageRepository {
    pub fn save_item(&self, item: &ClipItemSummary) -> Result<()> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        tx.execute(
            "INSERT INTO clip_items (id, title, summary) VALUES (?1, ?2, ?3)",
            params![&item.id, &item.title, &item.summary],
        )?;
        tx.commit()?;
        Ok(())
    }
}"""),
    ("rust", "crypto.rs", """pub struct CryptoEngine {
    cipher: Aes256Gcm,
}

impl CryptoEngine {
    pub fn new(key: &[u8; 32]) -> Self {
        Self { cipher: Aes256Gcm::new_from_slice(key).unwrap() }
    }
}"""),
    ("rust", "search.rs", """pub fn search_trigram(conn: &Connection, query: &str) -> Result<Vec<String>> {
    let mut stmt = conn.prepare("SELECT clip_id FROM clip_fts WHERE clip_fts MATCH ?1")?;
    let ids = stmt.query_map([query], |r| r.get(0))?.collect::<Result<Vec<_>, _>>()?;
    Ok(ids)
}"""),
    # Python
    ("python", "top_words.py", """from collections import Counter
import re

def top_words(text: str, n: int = 10) -> list[tuple[str, int]]:
    words = re.findall(r'\\b[a-zA-Z]{3,}\\b', text.lower())
    return Counter(words).most_common(n)

if __name__ == '__main__':
    print(top_words('The quick brown fox jumps over the lazy dog.'))"""),
    ("python", "fastapi_app.py", """from fastapi import FastAPI, Depends
from pydantic import BaseModel

app = FastAPI()

class Item(BaseModel):
    name: str
    price: float

@app.post("/items/")
async def create_item(item: Item):
    return {"status": "ok", "data": item}"""),
    # TypeScript
    ("typescript", "groupByTag.ts", """export function groupBy<T, K extends keyof any>(
  list: T[],
  getKey: (item: T) => K
): Record<K, T[]> {
  return list.reduce((previous, currentItem) => {
    const group = getKey(currentItem);
    if (!previous[group]) previous[group] = [];
    previous[group].push(currentItem);
    return previous;
  }, {} as Record<K, T[]>);
}"""),
    ("typescript", "useDebounce.ts", """import { useState, useEffect } from 'react';

export function useDebounce<T>(value: T, delay: number): T {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const handler = setTimeout(() => setDebounced(value), delay);
    return () => clearTimeout(handler);
  }, [value, delay]);
  return debounced;
}"""),
    # Go
    ("go", "server.go", """package main

import (
    "fmt"
    "net/http"
)

func helloHandler(w http.ResponseWriter, r *http.Request) {
    fmt.Fprintf(w, "Hello, NookClip Clipboard!")
}

func main() {
    http.HandleFunc("/hello", helloHandler)
    http.ListenAndServe(":8080", nil)
}"""),
    # SQL
    ("sql", "query_stats.sql", """SELECT 
    item_type,
    COUNT(*) AS total_count,
    SUM(favorite) AS favorite_count,
    ROUND(AVG(copy_count), 2) AS avg_copies
FROM clip_items
WHERE deleted_at IS NULL
GROUP BY item_type
ORDER BY total_count DESC;"""),
    # Shell
    ("bash", "build_ffmpeg.sh", """ffmpeg -i input.mov \\
  -vf "scale=1920:-2" \\
  -c:v libx264 \\
  -crf 18 \\
  -preset slow \\
  output.mp4"""),
    ("bash", "deploy_docker.sh", """docker run -d \\
  --name nook-cache \\
  -p 6379:6379 \\
  -v redis-data:/data \\
  --restart unless-stopped \\
  redis:alpine"""),
    # JSON
    ("json", "package.json", """{
  "name": "nook-desktop",
  "version": "1.2.0",
  "description": "Minimalist macOS clipboard manager",
  "main": "index.js",
  "scripts": {
    "build": "swift build -c release",
    "test": "swift test"
  },
  "dependencies": {
    "sparkle": "^2.10.0"
  }
}"""),
    ("json", "tsconfig.json", """{
  "compilerOptions": {
    "target": "ESNext",
    "module": "NodeNext",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true
  }
}"""),
    # HTML / CSS
    ("css", "styles.css", """.clipboard-card {
  display: flex;
  align-items: center;
  padding: 8px 12px;
  border-radius: 8px;
  background: var(--surface-bg);
  transition: transform 0.15s ease, box-shadow 0.15s ease;
}

.clipboard-card:hover {
  transform: translateY(-1px);
}"""),
]

URL_SAMPLES = [
    ("Apple 开发者文档", "https://developer.apple.com/documentation/swiftui/"),
    ("Human Interface Guidelines", "https://developer.apple.com/design/human-interface-guidelines/"),
    ("GitHub · lx3xun/nook-clip", "https://github.com/lx3xun/nook-clip"),
    ("Rust 官方标准库文档", "https://doc.rust-lang.org/std/"),
    ("Swift 语言设计 Evolution 提案", "https://github.com/apple/swift-evolution"),
    ("Figma 设计系统工作台", "https://www.figma.com/design/nook-app-ui/"),
    ("Hacker News 技术热榜", "https://news.ycombinator.com/"),
    ("Tailwind CSS 设计色彩调色板", "https://tailwindcss.com/docs/customizing-colors"),
    ("SQLite FTS5 全文搜索官方指南", "https://www.sqlite.org/fts5.html"),
    ("V2EX 程序员社区", "https://www.v2ex.com/"),
    ("少数派 · 效率工具专栏", "https://sspai.com/matrix"),
    ("MDN Web Docs 技术手册", "https://developer.mozilla.org/zh-CN/"),
    ("Tokio 异步运行时文档", "https://tokio.rs/tokio/tutorial"),
    ("UniFFI 跨语言绑定工具库", "https://mozilla.github.io/uniffi-rs/"),
    ("Raycast 扩展生态商店", "https://www.raycast.com/store"),
    ("Next.js 官方最佳实践", "https://nextjs.org/docs"),
    ("Go 语言并发设计模式", "https://go.dev/blog/pipelines"),
    ("PostgreSQL 官方性能调优指南", "https://www.postgresql.org/docs/current/performance-tips.html"),
    ("Docker 容器网络配置手册", "https://docs.docker.com/network/"),
    ("阮一峰的网络日志", "https://www.ruanyifeng.com/blog/"),
]

COLOR_SAMPLES = [
    ("#007AFF", "系统高亮蓝"),
    ("#34C759", "活力健康绿"),
    ("#5856D6", "极客紫罗兰"),
    ("#AF52DE", "柔和薰衣草"),
    ("#FF9500", "暖阳琥珀橙"),
    ("#FF3B30", "危险警示红"),
    ("#5AC8FA", "天青浅海蓝"),
    ("#FF2D55", "珊瑚玫瑰粉"),
    ("#3B82F6", "Tailwind 经典蓝"),
    ("#10B981", "翡翠绿 500"),
    ("#8B5CF6", "靛紫 500"),
    ("#F59E0B", "暖黄 500"),
    ("#EF4444", "鲜红 500"),
    ("#EC4899", "品红 500"),
    ("#06B6D4", "青蓝 500"),
    ("#84CC16", "青柠绿 500"),
    ("#1E293B", "暗黑界面深板岩"),
    ("#64748B", "次要文本中性灰"),
    ("#F8FAFC", "明亮卡片背景底色"),
    ("rgb(59, 130, 246)", "RGB 经典蓝"),
    ("rgb(16, 185, 129)", "RGB 薄荷绿"),
    ("rgb(239, 68, 68)", "RGB 警示红"),
    ("rgb(245, 158, 11)", "RGB 警示琥珀"),
    ("rgb(139, 92, 246)", "RGB 科技紫"),
]

FILE_SAMPLES = [
    (["/Users/zhangxiaofeng/lx3xun/nook/README.md"], "README.md"),
    (["/Users/zhangxiaofeng/lx3xun/nook/Package.swift"], "Package.swift"),
    (["/Users/zhangxiaofeng/lx3xun/nook/Cargo.toml"], "Cargo.toml"),
    (["/Users/zhangxiaofeng/Downloads/Xcode_16.0_Release.dmg"], "Xcode_16.0_Release.dmg"),
    (["/Users/zhangxiaofeng/Documents/Q3_Financial_Analysis.pdf"], "Q3_Financial_Analysis.pdf"),
    (["/Users/zhangxiaofeng/Documents/Nook_Architecture_Design.pdf"], "Nook_Architecture_Design.pdf"),
    (["/Users/zhangxiaofeng/Desktop/Release_Artifacts_v1.2.0.zip"], "Release_Artifacts_v1.2.0.zip"),
    (["/Users/zhangxiaofeng/Documents/Product_Roadmap_2026.xlsx"], "Product_Roadmap_2026.xlsx"),
    (["/Users/zhangxiaofeng/Movies/Nook_Demo_Recording.mov"], "Nook_Demo_Recording.mov"),
    (["/Users/zhangxiaofeng/Documents/API_Contract_v2.docx"], "API_Contract_v2.docx"),
    (["/Users/zhangxiaofeng/lx3xun/nook/CHANGELOG.md", "/Users/zhangxiaofeng/lx3xun/nook/README.en.md"], "2 个文件"),
    (["/Users/zhangxiaofeng/Desktop/spec1.pdf", "/Users/zhangxiaofeng/Desktop/spec2.pdf", "/Users/zhangxiaofeng/Desktop/spec3.pdf"], "3 个文件"),
    (["/Users/zhangxiaofeng/Projects/backup_data.tar.gz"], "backup_data.tar.gz"),
    (["/Users/zhangxiaofeng/Data/customer_export_202610.csv"], "customer_export_202610.csv"),
    (["/Users/zhangxiaofeng/Config/settings.yaml"], "settings.yaml"),
]

SENSITIVE_SAMPLES = [
    ("OpenAI API 密钥", "sk-proj-7HkLmNpQ2RtVwXyZ1AbCdEfGhIjKlMnOpQrStUvWxYz", "sk-proj-••••••••WxYz"),
    ("Claude API Key", "sk-ant-api03-9A8B7C6D5E4F3G2H1I0J_kLmNoPqRsTuVwXyZ", "sk-ant-••••••••XyZ"),
    ("AWS Access Key ID", "AKIAIOSFODNN7EXAMPLE", "AKIA••••••••MPLE"),
    ("AWS Secret Access Key", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "••••••••••••••••"),
    ("GitHub Personal Token", "ghp_AbCdEfGhIjKlMnOpQrStUvWxYz1234567890", "ghp_••••••••7890"),
    ("PostgreSQL 生产库密码", "postgres://nook_admin:P@ssw0rd_987654@db.prod.internal:5432/nook", "postgres://••••:••••@db.prod.internal"),
    ("SSH 客户端私钥", "-----BEGIN OPENSSH PRIVATE KEY-----\\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAA=\\n-----END OPENSSH PRIVATE KEY-----", "••••••••••••••••"),
    ("Stripe Webhook Secret", "whsec_3b7a8f9c1e2d4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f", "whsec_••••••••e1f"),
    ("员工身份证件号码", "110101199003072384", "110101••••••••2384"),
    ("测试用双币信用卡", "4111 2222 3333 4444", "4111 •••• •••• 4444"),
    ("Redis 鉴权口令", "AUTH mY_sUpEr_sEcReT_pAsSwOrD_2026!", "••••••••••••••••"),
    ("Google Cloud Service Key", "AIzaSyD-7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2", "AIza••••••••1d2"),
]

SOURCE_APPS = [
    ("微信", "com.tencent.xinWeChat"),
    ("备忘录", "com.apple.Notes"),
    ("Safari", "com.apple.Safari"),
    ("Xcode", "com.apple.dt.Xcode"),
    ("Figma", "com.figma.Desktop"),
    ("Finder", "com.apple.finder"),
    ("Terminal", "com.apple.Terminal"),
    ("截图", None),
    ("VS Code", "com.microsoft.VSCode"),
    ("Slack", "com.tinyspeck.slackmacgap"),
    ("Chrome", "com.google.Chrome"),
]


# ==========================================
# 辅助函数
# ==========================================

def encrypt_sensitive(plaintext: str) -> tuple[bytes, bytes]:
    """使用 Rust master key 加密明文，返回 (ciphertext, nonce)"""
    aesgcm = AESGCM(RUST_MASTER_KEY)
    nonce = os.urandom(12)
    ciphertext = aesgcm.encrypt(nonce, plaintext.encode("utf-8"), None)
    return ciphertext, nonce


def generate_test_images(content_dir: str, count: int = 150) -> list[dict]:
    """在 Content 目录生成丰富的小尺寸真实测试图片，返回元信息列表"""
    os.makedirs(content_dir, exist_ok=True)
    images = []

    palette = [
        ((43, 16, 85), (117, 151, 222), "极光渐变壁纸"),
        ((11, 16, 38), (27, 40, 69), "星空夜空深蓝"),
        ((252, 203, 144), (253, 101, 133), "落日余晖暖粉"),
        ((19, 106, 138), (38, 120, 113), "深海碧绿插画"),
        ((99, 102, 241), (168, 85, 247), "Indigo 霓虹紫"),
        ((244, 63, 94), (251, 146, 60), "珊瑚橙暖意"),
        ((16, 185, 129), (5, 150, 105), "极客薄荷绿"),
        ((30, 41, 59), (15, 23, 42), "暗黑控制台"),
        ((236, 72, 153), (219, 39, 119), "樱花品红 UI"),
        ((14, 165, 233), (2, 132, 199), "天际蔚蓝卡片"),
    ]

    sizes = [
        (800, 600),
        (1200, 800),
        (512, 512),
        (1920, 1080),
        (640, 480),
        (1024, 768),
        (1600, 900),
        (400, 400),
    ]

    for i in range(count):
        file_uuid = str(uuid.uuid4()).upper()
        ext = "png" if i % 3 != 0 else "tiff"
        filename = f"{file_uuid}.{ext}"
        filepath = os.path.join(content_dir, filename)

        width, height = random.choice(sizes)
        c1, c2, theme_name = palette[i % len(palette)]

        # 创建渐变或卡片图像
        img = Image.new("RGB", (width, height), color=c1)
        draw = ImageDraw.Draw(img)

        # 简单纵向渐变
        for y in range(0, height, 4):
            factor = y / float(height)
            r = int(c1[0] + (c2[0] - c1[0]) * factor)
            g = int(c1[1] + (c2[1] - c1[1]) * factor)
            b = int(c1[2] + (c2[2] - c1[2]) * factor)
            draw.line([(0, y), (width, y)], fill=(r, g, b), width=4)

        # 几何装饰卡片
        cx, cy = width // 2, height // 2
        rw, rh = min(width, height) // 3, min(width, height) // 3
        draw.rectangle(
            [cx - rw, cy - rh, cx + rw, cy + rh],
            outline=(255, 255, 255, 180),
            width=max(2, width // 400),
        )

        img.save(filepath)
        size_kb = max(1, os.path.getsize(filepath) // 1024)
        hash_str = file_uuid[:8].lower()

        images.append({
            "title": f"{theme_name}_{i + 1}.{ext}",
            "summary": f"{width} × {height} 像素 · {size_kb} KB #{hash_str}",
            "payload_path": filepath,
            "width": width,
            "height": height,
        })

    return images


# ==========================================
# 主生成逻辑
# ==========================================

def generate_records(count: int, content_dir: str) -> list[dict]:
    """生成 1000 条结构化条目字典"""
    records = []
    now = time.time()
    # 30 天时间跨度（秒）
    time_span = 30 * 24 * 3600

    # 各分类数量分配（总计 count = 1000）
    # 文本: 150, 代码: 200, 链接: 150, 颜色: 100, 图片: 150, 文件: 150, 敏感: 100
    target_counts = {
        "text": 150,
        "code": 200,
        "url": 150,
        "color": 100,
        "image": 150,
        "file": 150,
        "sensitive": 100,
    }

    # 1. 文本
    for i in range(target_counts["text"]):
        sample_title, sample_text = TEXT_SAMPLES[i % len(TEXT_SAMPLES)]
        unique_text = f"{sample_text} [测试序号 #{i + 1}]" if i >= len(TEXT_SAMPLES) else sample_text
        records.append({
            "item_type": "text",
            "kind": "text",
            "title": f"{sample_title} #{i + 1}" if i >= len(TEXT_SAMPLES) else sample_title,
            "summary": unique_text,
            "raw_text": unique_text,
            "is_sensitive": 0,
            "metadata_json": None,
            "payload_path": None,
            "source_app": random.choice([("微信", "com.tencent.xinWeChat"), ("备忘录", "com.apple.Notes"), ("Slack", "com.tinyspeck.slackmacgap"), ("飞书", "com.electron.lark")]),
        })

    # 2. 代码 / JSON
    for i in range(target_counts["code"]):
        lang, title, snippet = CODE_SAMPLES[i % len(CODE_SAMPLES)]
        snippet_unique = snippet if i < len(CODE_SAMPLES) else f"{snippet}\n// entry #{i + 1}"
        records.append({
            "item_type": "text",
            "kind": "json" if lang == "json" else "code",
            "title": f"{title} ({i + 1})" if i >= len(CODE_SAMPLES) else title,
            "summary": snippet_unique,
            "raw_text": snippet_unique,
            "is_sensitive": 0,
            "metadata_json": json.dumps({"language": lang}),
            "payload_path": None,
            "source_app": random.choice([("Xcode", "com.apple.dt.Xcode"), ("VS Code", "com.microsoft.VSCode"), ("Terminal", "com.apple.Terminal")]),
        })

    # 3. 链接
    for i in range(target_counts["url"]):
        title, url = URL_SAMPLES[i % len(URL_SAMPLES)]
        unique_url = f"{url}?ref=test_{i + 1}" if i >= len(URL_SAMPLES) else url
        records.append({
            "item_type": "url",
            "kind": "url",
            "title": f"{title} #{i + 1}" if i >= len(URL_SAMPLES) else title,
            "summary": unique_url,
            "raw_text": unique_url,
            "is_sensitive": 0,
            "metadata_json": json.dumps({"url": unique_url}),
            "payload_path": None,
            "source_app": random.choice([("Safari", "com.apple.Safari"), ("Chrome", "com.google.Chrome")]),
        })

    # 4. 颜色
    for i in range(target_counts["color"]):
        val, name = COLOR_SAMPLES[i % len(COLOR_SAMPLES)]
        if i >= len(COLOR_SAMPLES):
            # 随机生成微调色
            r, g, b = random.randint(30, 240), random.randint(30, 240), random.randint(30, 240)
            if i % 2 == 0:
                val = f"#{r:02X}{g:02X}{b:02X}"
            else:
                val = f"rgb({r}, {g}, {b})"
            name = f"调色板自选色 #{i + 1}"
        records.append({
            "item_type": "text",
            "kind": "color",
            "title": f"{name} {val}",
            "summary": val,
            "raw_text": val,
            "is_sensitive": 0,
            "metadata_json": None,
            "payload_path": None,
            "source_app": random.choice([("Figma", "com.figma.Desktop"), ("Xcode", "com.apple.dt.Xcode")]),
        })

    # 5. 图片
    image_meta_list = generate_test_images(content_dir, count=target_counts["image"])
    for img_info in image_meta_list:
        records.append({
            "item_type": "image",
            "kind": "image",
            "title": img_info["title"],
            "summary": img_info["summary"],
            "raw_text": img_info["title"],
            "is_sensitive": 0,
            "metadata_json": None,
            "payload_path": img_info["payload_path"],
            "source_app": random.choice([("截图", None), ("Figma", "com.figma.Desktop"), ("Safari", "com.apple.Safari"), ("微信", "com.tencent.xinWeChat")]),
        })

    # 6. 文件
    for i in range(target_counts["file"]):
        paths, title = FILE_SAMPLES[i % len(FILE_SAMPLES)]
        if i >= len(FILE_SAMPLES):
            title = f"Document_{i + 1}.pdf"
            summary_path = f"/Users/zhangxiaofeng/Documents/Archive/Document_{i + 1}.pdf"
        else:
            summary_path = "\n".join(paths)
        records.append({
            "item_type": "file",
            "kind": "file",
            "title": title,
            "summary": summary_path,
            "raw_text": summary_path,
            "is_sensitive": 0,
            "metadata_json": None,
            "payload_path": summary_path,
            "source_app": ("Finder", "com.apple.finder"),
        })

    # 7. 敏感信息
    for i in range(target_counts["sensitive"]):
        label, secret, mask = SENSITIVE_SAMPLES[i % len(SENSITIVE_SAMPLES)]
        unique_secret = f"{secret}_{i + 1}" if i >= len(SENSITIVE_SAMPLES) else secret
        unique_mask = f"{mask} ({i + 1})" if i >= len(SENSITIVE_SAMPLES) else mask
        ciphertext, nonce = encrypt_sensitive(unique_secret)
        records.append({
            "item_type": "text",
            "kind": "sensitive",
            "title": f"{label} [{unique_mask}]",
            "summary": unique_mask,
            "raw_text": None,
            "encrypted_content": ciphertext,
            "nonce": nonce,
            "is_sensitive": 1,
            "metadata_json": None,
            "payload_path": None,
            "source_app": random.choice([("Terminal", "com.apple.Terminal"), ("Xcode", "com.apple.dt.Xcode"), ("Chrome", "com.google.Chrome")]),
        })

    # 洗牌随机打散各类型顺序
    random.seed(42)
    random.shuffle(records)

    # 统一注入 UUID、时间戳（最新在最前）、复制次数与收藏标记
    # 时间线分布：从近到远递减，保证列表时间排序真实
    for idx, item in enumerate(records):
        item["id"] = str(uuid.uuid4()).upper()
        # 抛物线/对数分布：越近的时间数据密度越大
        progress = idx / float(len(records))
        time_offset = (progress ** 1.5) * time_span
        item["last_used_at"] = now - time_offset
        item["created_at"] = item["last_used_at"] - random.uniform(60, 3600)
        item["copy_count"] = random.randint(1, 10)
        # 约 15% 标记为收藏
        item["favorite"] = 1 if (idx % 7 == 0) else 0

    return records


def populate_database(db_path: str, records: list[dict], clean_existing: bool = False):
    """连接数据库并批量写入"""
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()

    cur.execute("PRAGMA foreign_keys = ON;")
    cur.execute("PRAGMA journal_mode = WAL;")

    cur.execute("BEGIN IMMEDIATE;")

    if clean_existing:
        print("🧹 正在清理原有历史记录...")
        cur.execute("DELETE FROM clip_fts;")
        cur.execute("DELETE FROM clip_payloads;")
        cur.execute("DELETE FROM clip_items;")

    print(f"📦 正在写入 {len(records)} 条测试数据到 {db_path} ...")

    insert_item_sql = """
    INSERT INTO clip_items (
        id, item_type, title, summary, created_at, last_used_at,
        copy_count, favorite, source_app_bundle_id, source_app_name,
        is_sensitive, deleted_at, payload_path, kind
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
    """

    insert_payload_sql = """
    INSERT INTO clip_payloads (
        id, raw_text, encrypted_content, nonce, ocr_text, metadata_json
    ) VALUES (?, ?, ?, ?, NULL, ?)
    """

    insert_fts_sql = """
    INSERT INTO clip_fts (
        title, summary, ocr_text, source_app_name, source_app_bundle_id, clip_id
    ) VALUES (?, ?, '', ?, ?, ?)
    """

    for r in records:
        source_name, source_bundle = r["source_app"]
        cur.execute(
            insert_item_sql,
            (
                r["id"],
                r["item_type"],
                r["title"],
                r["summary"],
                r["created_at"],
                r["last_used_at"],
                r["copy_count"],
                r["favorite"],
                source_bundle,
                source_name,
                r["is_sensitive"],
                r["payload_path"],
                r.get("kind", "text"),
            ),
        )

        cur.execute(
            insert_payload_sql,
            (
                r["id"],
                r["raw_text"],
                r.get("encrypted_content"),
                r.get("nonce"),
                r["metadata_json"],
            ),
        )

        # 仅非敏感条目进入 FTS5 全文索引
        if r["is_sensitive"] == 0:
            cur.execute(
                insert_fts_sql,
                (
                    r["title"],
                    r["summary"],
                    source_name,
                    source_bundle,
                    r["id"],
                ),
            )

    conn.commit()
    conn.close()
    print("✅ 数据库提交完毕！")


def print_stats(db_path: str):
    """打印分类统计"""
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()

    total = cur.execute("SELECT count(*) FROM clip_items WHERE deleted_at IS NULL").fetchone()[0]
    favorites = cur.execute("SELECT count(*) FROM clip_items WHERE deleted_at IS NULL AND favorite = 1").fetchone()[0]
    sensitive = cur.execute("SELECT count(*) FROM clip_items WHERE deleted_at IS NULL AND is_sensitive = 1").fetchone()[0]
    fts_count = cur.execute("SELECT count(*) FROM clip_fts").fetchone()[0]

    by_type = cur.execute("""
        SELECT item_type, count(*) 
        FROM clip_items 
        WHERE deleted_at IS NULL AND is_sensitive = 0
        GROUP BY item_type
    """).fetchall()

    conn.close()

    print("\n📊 数据库数据统计汇总：")
    print(f"  • 总有效条数: {total} 条")
    print(f"  • 收藏条数: {favorites} 条")
    print(f"  • 敏感条目: {sensitive} 条（AES-256-GCM 加密）")
    print(f"  • 全文检索 (FTS5) 索引行数: {fts_count} 条")
    print("  • 基础分类分布:")
    for t, c in by_type:
        print(f"    - {t}: {c} 条")


# ==========================================
# 入口
# ==========================================

def main():
    parser = argparse.ArgumentParser(description="生成 NookClip 剪贴板 1000 条各分类测试数据")
    parser.add_argument("--count", type=int, default=1000, help="生成总条数（默认 1000）")
    parser.add_argument("--db", type=str, default=DEFAULT_DB_PATH, help=f"目标数据库路径（默认: {DEFAULT_DB_PATH}）")
    parser.add_argument("--content-dir", type=str, default=DEFAULT_CONTENT_DIR, help=f"图片载荷存储目录（默认: {DEFAULT_CONTENT_DIR}）")
    parser.add_argument("--clean", action="store_true", help="清空库中现有记录（默认保留追加）")
    parser.add_argument("--no-backup", action="store_true", help="写入前不自动备份现有数据库")
    parser.add_argument("--dry-run", action="store_true", help="仅生成验证，不写真实磁盘与数据库")
    parser.add_argument("--restart", action="store_true", help="写入完成后自动重启 NookClip 应用以加载数据")

    args = parser.parse_args()

    db_path = os.path.abspath(args.db)
    content_dir = os.path.abspath(args.content_dir)

    print(f"🚀 开始生成 {args.count} 条全分类测试数据...")
    print(f"📁 目标数据库: {db_path}")
    print(f"🖼️ 图片载荷目录: {content_dir}")

    # 1. 备份
    if os.path.exists(db_path) and not args.no_backup and not args.dry_run:
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        backup_path = f"{db_path}.backup_{timestamp}"
        shutil.copy2(db_path, backup_path)
        print(f"💾 已自动备份现有数据库至: {backup_path}")

    # 2. 生成数据
    records = generate_records(args.count, content_dir)

    if args.dry_run:
        print(f"🔍 Dry-run 完成，已生成 {len(records)} 条内存记录，未落盘。")
        return

    # 3. 写入数据库
    populate_database(db_path, records, clean_existing=args.clean)

    # 4. 统计校验
    print_stats(db_path)

    # 5. 可选重启 App
    if args.restart:
        import subprocess
        app_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "../NookClip.app"))
        p = subprocess.run(["pgrep", "-f", "NookClip.app|Nook.app"], capture_output=True)
        if p.returncode == 0:
            print("\n🔄 检测到应用正在运行，正在重启...")
            subprocess.run(["killall", "NookClip"], stderr=subprocess.DEVNULL)
            subprocess.run(["killall", "Nook"], stderr=subprocess.DEVNULL)
            time.sleep(0.8)
        if os.path.exists(app_path):
            subprocess.run(["open", app_path])
            print("✨ NookClip 应用已重启并加载最新数据！")
        else:
            subprocess.run(["open", "-a", "NookClip"])
            print("✨ NookClip 应用已尝试重启！")


if __name__ == "__main__":
    main()
