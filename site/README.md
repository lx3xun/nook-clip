# NookClip 产品落地页 (Landing Page)

本项目是 NookClip macOS 剪贴板管理工具的官方落地页，采用**纯静态原生架构（HTML5 + 现代 CSS3 + 极简 Vanilla JS）**构建，零第三方运行时依赖，具备极致轻量、高保真 macOS 质感与秒开性能。

## 目录结构

```text
site/
├── index.html                 # 语义化 HTML 主页面结构（含 SEO、Open Graph、无障碍规范）
├── style.css                  # 完整样式系统（自适应深浅色主题、毛玻璃拟真窗口、Bento 网格、响应式断点）
├── main.js                    # 轻量交互脚本（深浅色主题切换联动、截图切换、一键复制构建命令、移动端抽屉导航）
├── assets/                    # 运行时必需的高清图片与品牌矢量图标（已精简）
│   ├── nookclip-appicon.svg   # 1024x1024 macOS 原生圆角应用图标
│   ├── nookclip-dark.png      # 真实深色模式产品界面截图
│   ├── nookclip-light.png     # 真实浅色模式产品界面截图
│   ├── favicon.ico            # 浏览器多尺寸 Favicon
│   ├── favicon.svg            # 矢量 Favicon
│   ├── apple-touch-icon.png   # 移动端主屏图标
│   └── icon.png               # 社交分享 Open Graph 高清卡片图标
└── previews/                  # 自动化浏览器冒烟审查截图（桌面端与移动端）
    ├── desktop-preview.png
    └── mobile-preview.png
```

## 本地预览与调试

由于是纯原生静态页面，无需执行 `npm install`：

```bash
# 方式 1：使用 Python 内置 HTTP 服务
python3 -m http.server 8080 --directory site

# 方式 2：使用 Node.js http-server 或 npx serve
npx serve site

# 方式 3：任何静态文件服务器或直接在浏览器打开 site/index.html
```

访问 `http://localhost:8080` 即可实时查看。

## 部署上线指南

### 方式一：GitHub Pages（已配置 GitHub Actions 自动化）
仓库已包含 `.github/workflows/deploy-site.yml`：
1. 在 GitHub 仓库设置中前往 **Settings → Pages**；
2. 将 **Build and deployment → Source** 设置为 **GitHub Actions**；
3. 任何推送到 `main` 分支且包含 `site/**` 改动的提交均会自动触发一键部署上线。

### 方式二：Cloudflare Pages / Vercel
- **Framework Preset**: None / Other
- **Build Command**: *(留空)*
- **Output Directory**: `site`

### 方式三：独立 Nginx 服务器配置示例

```nginx
server {
    listen 80;
    server_name nookclip.com;

    root /var/www/nook-clip/site;
    index index.html;

    # 启用 Gzip 压缩
    gzip on;
    gzip_types text/plain text/css application/javascript image/svg+xml;

    location / {
        try_files $uri $uri/ /index.html;
    }

    # 静态图片缓存策略
    location ~* \.(png|svg|ico)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }
}
```

## 回滚方案
静态页面部署具备天然回滚能力：
- **GitHub Pages / Vercel / Cloudflare**：进入部署面板点击前一个成功的 Deployment 即可秒级回滚。
- **Git 级别**：`git revert <commit-id>` 即可无缝触发自动重新构建与发布。
