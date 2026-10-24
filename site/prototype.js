/**
 * NookClip 100% 交互原型测试台引擎 (Interactive Prototype Engine)
 * 100% 像素级复刻官方原生界面 (nookclip-light.png & nookclip-dark.png)
 * 包含：真实 10 条展示数据、实体蓝色高亮选行、分类筛选、搜索/拼音、快捷键循环、深浅色模式。
 * 完整支持多语言动态切换 (简体中文 zh-Hans · 繁體中文 zh-Hant · 英文 en)
 */

(function(window) {
  'use strict';

  // =========================================================================
  // 1. 紧凑型 SVG 二维码生成器 (Pure JS QR Code Generator - Version 3-M)
  // =========================================================================
  const MiniQRCode = (() => {
    const EXP = new Uint8Array(512), LOG = new Uint8Array(256);
    for (let i = 0, x = 1; i < 255; i++) {
      EXP[i] = x; LOG[x] = i;
      x = (x << 1) ^ (x >= 128 ? 0x11d : 0);
    }
    for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
    const mul = (a, b) => (a && b ? EXP[LOG[a] + LOG[b]] : 0);

    function rsPoly(n) {
      let p = [1];
      for (let i = 0; i < n; i++) {
        const next = new Array(p.length + 1).fill(0);
        for (let j = 0; j < p.length; j++) {
          next[j] ^= mul(p[j], EXP[i]);
          next[j + 1] ^= p[j];
        }
        p = next;
      }
      return p;
    }

    function rsCalc(data, num) {
      const poly = rsPoly(num);
      const res = new Array(num).fill(0);
      for (let i = 0; i < data.length; i++) {
        const f = data[i] ^ res[0];
        res.shift();
        res.push(0);
        for (let j = 0; j < num; j++) res[j] ^= mul(poly[j], f);
      }
      return res;
    }

    return {
      toSVG(text, size = 120) {
        const N = 29;
        const matrix = Array.from({length: N}, () => new Int8Array(N));
        const res = Array.from({length: N}, () => new Uint8Array(N));

        function set(r, c, v) {
          matrix[r][c] = v ? 1 : 0;
          res[r][c] = 1;
        }

        function finder(r, c) {
          for (let i = -1; i <= 7; i++) {
            for (let j = -1; j <= 7; j++) {
              const row = r + i, col = c + j;
              if (row < 0 || row >= N || col < 0 || col >= N) continue;
              const isB = (i >= 0 && i <= 6 && (j === 0 || j === 6)) ||
                          (j >= 0 && j <= 6 && (i === 0 || i === 6)) ||
                          (i >= 2 && i <= 4 && j >= 2 && j <= 4);
              set(row, col, isB);
            }
          }
        }
        finder(0, 0);
        finder(0, N - 7);
        finder(N - 7, 0);

        for (let i = -2; i <= 2; i++) {
          for (let j = -2; j <= 2; j++) {
            set(22 + i, 22 + j, Math.max(Math.abs(i), Math.abs(j)) !== 1);
          }
        }

        for (let i = 8; i < N - 8; i++) {
          set(6, i, i % 2 === 0);
          set(i, 6, i % 2 === 0);
        }
        set(N - 8, 8, 1);

        for (let i = 0; i < 9; i++) { res[8][i] = 1; res[i][8] = 1; }
        for (let i = 0; i < 8; i++) { res[8][N - 1 - i] = 1; res[N - 1 - i][8] = 1; }

        const bits = [0, 1, 0, 0];
        const len = Math.min(text.length, 42);
        for (let i = 7; i >= 0; i--) bits.push((len >> i) & 1);
        for (let i = 0; i < len; i++) {
          const code = text.charCodeAt(i);
          for (let b = 7; b >= 0; b--) bits.push((code >> b) & 1);
        }
        while (bits.length < 44 * 8 && bits.length % 8 !== 0) bits.push(0);
        while (bits.length < 44 * 8) bits.push(0);

        const dataBytes = [];
        for (let i = 0; i < bits.length; i += 8) {
          let b = 0;
          for (let j = 0; j < 8; j++) b = (b << 1) | (bits[i + j] || 0);
          dataBytes.push(b);
        }
        const pad = [0xEC, 0x11];
        let pidx = 0;
        while (dataBytes.length < 44) dataBytes.push(pad[pidx++ % 2]);

        const allBytes = dataBytes.concat(rsCalc(dataBytes, 26));
        const stream = [];
        for (const b of allBytes) {
          for (let i = 7; i >= 0; i--) stream.push((b >> i) & 1);
        }

        let bitIdx = 0, upward = true;
        for (let right = N - 1; right > 0; right -= 2) {
          if (right === 6) right--;
          const cols = [right, right - 1];
          for (let count = 0; count < N; count++) {
            const row = upward ? N - 1 - count : count;
            for (const col of cols) {
              if (!res[row][col]) {
                const bit = bitIdx < stream.length ? stream[bitIdx++] : 0;
                set(row, col, bit ^ ((row + col) % 2 === 0 ? 1 : 0));
              }
            }
          }
          upward = !upward;
        }

        const rects = [];
        for (let r = 0; r < N; r++) {
          for (let c = 0; c < N; c++) {
            if (matrix[r][c]) rects.push(`<rect x="${c}" y="${r}" width="1" height="1" fill="#000"/>`);
          }
        }
        return `<svg width="${size}" height="${size}" viewBox="0 0 ${N} ${N}" shape-rendering="crispEdges" style="color:#000;"><rect width="${N}" height="${N}" fill="#fff"/>${rects.join('')}</svg>`;
      }
    };
  })();

  // =========================================================================
  // 2. 多语言规范与数据结构 (Multi-Language Specifications & Data)
  // =========================================================================

  function normalizeLang(lang) {
    if (!lang) return 'zh-Hans';
    if (/zh-TW|zh-HK|zh-MO|zh-Hant/i.test(lang)) return 'zh-Hant';
    if (/zh/i.test(lang)) return 'zh-Hans';
    if (/en/i.test(lang)) return 'en';
    return 'zh-Hans';
  }

  // 分类定义表 (三语支持)
  //
  // 顺序即客户端「按类型」网格的固定槽序（CategoryBarCoordinator.gridCategoryIDs）：
  // 收藏、图片、文本、链接 / 代码、文件、色值、回收站——4 列 × 2 行、读序从左到右、
  // 从上到下，8 个槽位平权且位置固定（旧版「第 4 槽下拉 + 拖拽排序」已退役）。
  // id 0「全部」不占网格：它是默认的无筛选态，由搜索框内嵌胶囊表达。
  // 回收站槽当前模型无计数，恒按空态置灰渲染（与客户端一致）。
  const CATEGORY_ICON_BY_ID = {
    0: 'grid', 8: 'star', 2: 'image', 1: 'text', 4: 'link',
    5: 'code', 3: 'file', 6: 'color', 7: 'trash'
  };

  const CATEGORIES_DATA = {
    'zh-Hans': [
      { id: 8, name: "收藏", icon: "star", tint: "favorite" },
      { id: 2, name: "图片", icon: "image", tint: "image" },
      { id: 1, name: "文本", icon: "text", tint: "text" },
      { id: 4, name: "链接", icon: "link", tint: "url" },
      { id: 5, name: "代码", icon: "code", tint: "code" },
      { id: 3, name: "文件", icon: "file", tint: "file" },
      { id: 6, name: "色值", icon: "color", tint: "color" },
      { id: 7, name: "回收站", icon: "trash", tint: "trash" }
    ],
    'zh-Hant': [
      { id: 8, name: "收藏", icon: "star", tint: "favorite" },
      { id: 2, name: "圖片", icon: "image", tint: "image" },
      { id: 1, name: "文字", icon: "text", tint: "text" },
      { id: 4, name: "連結", icon: "link", tint: "url" },
      { id: 5, name: "程式碼", icon: "code", tint: "code" },
      { id: 3, name: "檔案", icon: "file", tint: "file" },
      { id: 6, name: "色值", icon: "color", tint: "color" },
      { id: 7, name: "回收站", icon: "trash", tint: "trash" }
    ],
    'en': [
      { id: 8, name: "Favorites", icon: "star", tint: "favorite" },
      { id: 2, name: "Images", icon: "image", tint: "image" },
      { id: 1, name: "Text", icon: "text", tint: "text" },
      { id: 4, name: "Links", icon: "link", tint: "url" },
      { id: 5, name: "Code", icon: "code", tint: "code" },
      { id: 3, name: "Files", icon: "file", tint: "file" },
      { id: 6, name: "Colors", icon: "color", tint: "color" },
      { id: 7, name: "Trash", icon: "trash", tint: "trash" }
    ]
  };

  // 侧列底部常驻的「全部」筛选项（不占类型网格，仅用于清除筛选与键盘循环的起点）
  const ALL_CATEGORY_DATA = {
    'zh-Hans': { id: 0, name: "全部", icon: "grid" },
    'zh-Hant': { id: 0, name: "全部", icon: "grid" },
    'en': { id: 0, name: "All", icon: "grid" }
  };

  const CATEGORIES = CATEGORIES_DATA['zh-Hans'];

  // 拼音/首字母应用推荐表 (三语支持)
  const INSTALLED_APPS_DATA = {
    'zh-Hans': [
      { id: "app-wechat", name: "微信", pinyin: "wx", bundle: "com.tencent.xinWeChat", icon: "wechat", path: "/Applications/WeChat.app" },
      { id: "app-terminal", name: "终端", pinyin: "zd", bundle: "com.apple.Terminal", icon: "terminal", path: "/System/Applications/Utilities/Terminal.app" },
      { id: "app-xcode", name: "Xcode", pinyin: "xc", bundle: "com.apple.dt.Xcode", icon: "xcode", path: "/Applications/Xcode.app" },
      { id: "app-safari", name: "Safari 浏览器", pinyin: "sf", bundle: "com.apple.Safari", icon: "safari", path: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app" },
      { id: "app-figma", name: "Figma", pinyin: "fg", bundle: "com.figma.Desktop", icon: "figma", path: "/Applications/Figma.app" }
    ],
    'zh-Hant': [
      { id: "app-wechat", name: "微信", pinyin: "wx", bundle: "com.tencent.xinWeChat", icon: "wechat", path: "/Applications/WeChat.app" },
      { id: "app-terminal", name: "終端機", pinyin: "zd", bundle: "com.apple.Terminal", icon: "terminal", path: "/System/Applications/Utilities/Terminal.app" },
      { id: "app-xcode", name: "Xcode", pinyin: "xc", bundle: "com.apple.dt.Xcode", icon: "xcode", path: "/Applications/Xcode.app" },
      { id: "app-safari", name: "Safari 瀏覽器", pinyin: "sf", bundle: "com.apple.Safari", icon: "safari", path: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app" },
      { id: "app-figma", name: "Figma", pinyin: "fg", bundle: "com.figma.Desktop", icon: "figma", path: "/Applications/Figma.app" }
    ],
    'en': [
      { id: "app-wechat", name: "WeChat", pinyin: "wechat", bundle: "com.tencent.xinWeChat", icon: "wechat", path: "/Applications/WeChat.app" },
      { id: "app-terminal", name: "Terminal", pinyin: "terminal", bundle: "com.apple.Terminal", icon: "terminal", path: "/System/Applications/Utilities/Terminal.app" },
      { id: "app-xcode", name: "Xcode", pinyin: "xcode", bundle: "com.apple.dt.Xcode", icon: "xcode", path: "/Applications/Xcode.app" },
      { id: "app-safari", name: "Safari", pinyin: "safari", bundle: "com.apple.Safari", icon: "safari", path: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app" },
      { id: "app-figma", name: "Figma", pinyin: "figma", bundle: "com.figma.Desktop", icon: "figma", path: "/Applications/Figma.app" }
    ]
  };

  const INSTALLED_APPS = INSTALLED_APPS_DATA['zh-Hans'];

  // 标签定义表 (三语支持)
  //
  // 标签是用户自建的横切维度（一条记录可同时属于「类型 = 文本」与「标签 = 前端」），
  // 所以在筛选面板里与「按类型」并列展示。名称不做翻译——标签是用户自己起的词。
  // tagApplied 表示该条记录的标签（标签体系尚未在测试台接入编辑，此处按只读展示）。
  // 演示数据里「当前用户」的 home 目录；不含该前缀的路径即视作文件已失效
  const DEMO_USER_HOME = 'alex';
  const TAGS_DATA = [
    { id: "tag-frontend", name: "前端" },
    { id: "tag-design", name: "设计" },
    { id: "tag-backend", name: "后端" },
    { id: "tag-database", name: "数据库" },
    { id: "tag-security", name: "安全" },
    { id: "tag-docs", name: "文档" }
  ];

  // SVG 矢量符号库 (对齐 SF Symbols)
  const ICONS = {
    grid: '<svg viewBox="0 0 16 16" width="13" height="13" fill="currentColor"><rect x="1.5" y="1.5" width="5.5" height="5.5" rx="1.5"/><rect x="9" y="1.5" width="5.5" height="5.5" rx="1.5"/><rect x="1.5" y="9" width="5.5" height="5.5" rx="1.5"/><rect x="9" y="9" width="5.5" height="5.5" rx="1.5"/></svg>',
    star: '<svg viewBox="0 0 16 16" width="12" height="12" fill="currentColor"><path d="M8 .25a.75.75 0 0 1 .673.418l1.882 3.815 4.21.612a.75.75 0 0 1 .416 1.279l-3.046 2.97.719 4.192a.75.75 0 0 1-1.088.791L8 12.347l-3.766 1.98a.75.75 0 0 1-1.088-.79l.72-4.194L.818 6.374a.75.75 0 0 1 .416-1.28l4.21-.611L7.327.668A.75.75 0 0 1 8 .25z"/></svg>',
    starOutline: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M8 1.5l1.8 3.6 4 .6-2.9 2.8.7 4L8 10.6 4.4 12.5l.7-4-2.9-2.8 4-.6L8 1.5z"/></svg>',
    text: '<svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M3.5 1.5A1.5 1.5 0 0 0 2 3v10a1.5 1.5 0 0 0 1.5 1.5h9A1.5 1.5 0 0 0 14 13V5.5L10 1.5H3.5z"/><path d="M9.5 1.5V5H13M4.5 7h7M4.5 9.5h7M4.5 12h4.5"/></svg>',
    link: '<svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.4"><circle cx="8" cy="8" r="6.5"/><path d="M1.5 8h13M8 1.5a10 10 0 0 1 3 6.5 10 10 0 0 1-3 6.5 10 10 0 0 1-3-6.5 10 10 0 0 1 3-6.5z"/></svg>',
    image: '<svg viewBox="0 0 16 16" width="13" height="13" fill="currentColor"><path d="M2 3a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V5a2 2 0 0 0-2-2H2zm9 3a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0zM2 11l3-4 2.5 3 2.5-3.5 4 4.5H2z"/></svg>',
    code: '<svg viewBox="0 0 16 16" width="13" height="13" fill="currentColor"><path d="M5.5 3.5a1 1 0 0 0-1 1V6a1 1 0 0 1-1 1H3a1 1 0 0 1 0 2h.5a1 1 0 0 1 1 1v1.5a1 1 0 0 0 1 1h1a.75.75 0 0 0 0-1.5H6V10a2.5 2.5 0 0 0-2-2.45A2.5 2.5 0 0 0 6 5.1V4h.5a.75.75 0 0 0 0-1.5h-1zm5 0a.75.75 0 0 0 0 1.5h.5V5a2.5 2.5 0 0 0 2 2.45 2.5 2.5 0 0 0-2 2.45v.6h-.5a.75.75 0 0 0 0 1.5h1a1 1 0 0 0 1-1V9.5a1 1 0 0 1 1-1h.5a1 1 0 0 1 0-2h-.5a1 1 0 0 1-1-1V4.5a1 1 0 0 0-1-1h-1z"/></svg>',
    color: '<svg viewBox="0 0 16 16" width="13" height="13" fill="currentColor"><path d="M8 0a8 8 0 1 0 8 8 3.5 3.5 0 0 0-3.5-3.5H10A1.5 1.5 0 0 1 8.5 3V1.5A1.5 1.5 0 0 0 7 0h1zm-4.5 5a1.5 1.5 0 1 1 0-3 1.5 1.5 0 0 1 0 3zm4-2a1.5 1.5 0 1 1 0-3 1.5 1.5 0 0 1 0 3zm-4 7a1.5 1.5 0 1 1 0-3 1.5 1.5 0 0 1 0 3zm9 0a1.5 1.5 0 1 1 0-3 1.5 1.5 0 0 1 0 3z"/></svg>',
    sensitive: '<svg viewBox="0 0 16 16" width="13" height="13" fill="currentColor"><path d="M8 .5l6 2.5v5c0 4.5-3 7.5-6 8-3-.5-6-3.5-6-8V3L8 .5zM8 4a2 2 0 0 0-2 2v1h-.5a.5.5 0 0 0-.5.5v3a.5.5 0 0 0 .5.5h5a.5.5 0 0 0 .5-.5v-3a.5.5 0 0 0-.5-.5H10V6a2 2 0 0 0-2-2zm1 3H7V6a1 1 0 0 1 2 0v1z"/></svg>',
    search: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.6"><circle cx="7" cy="7" r="5"/><path d="M11 11l3.5 3.5"/></svg>',
    trash: '<svg viewBox="0 0 16 16" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M3 4.5h10M5.5 4.5V3a1 1 0 0 1 1-1h3a1 1 0 0 1 1 1v1.5M4.5 4.5v9a1 1 0 0 0 1 1h5a1 1 0 0 0 1-1v-9M6.5 7.5v4M9.5 7.5v4"/></svg>',
    chevronDown: '<svg viewBox="0 0 16 16" width="10" height="10" fill="currentColor"><path d="M4 6l4 4 4-4H4z"/></svg>',
    hash: '<svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M6.2 2.2L4.8 13.8M11.2 2.2L9.8 13.8M2.5 6h11.5M2 10h11.5"/></svg>',
    close: '<svg viewBox="0 0 16 16" width="8" height="8" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M3.5 3.5l9 9M12.5 3.5l-9 9"/></svg>',
    chevronUpDown: '<svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M4.5 6L8 2.5 11.5 6M4.5 10l3.5 3.5 3.5-3.5"/></svg>',
    check: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2"><polyline points="3 8.5 6.5 12 13 4"/></svg>',
    file: '<svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M3.5 1.5A1.5 1.5 0 0 0 2 3v10a1.5 1.5 0 0 0 1.5 1.5h9A1.5 1.5 0 0 0 14 13V5.5L10 1.5H3.5z"/><path d="M9.5 1.5V5H13"/></svg>',
    open: '<svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M12 9v4.5A1.5 1.5 0 0 1 10.5 15h-8A1.5 1.5 0 0 1 1 13.5v-8A1.5 1.5 0 0 1 2.5 4H7M10 1h5v5M6.5 9.5L15 1"/></svg>',
    folder: '<svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M1.5 3A1.5 1.5 0 0 1 3 1.5h3.5L8 3.5h5A1.5 1.5 0 0 1 14.5 5v8a1.5 1.5 0 0 1-1.5 1.5h-10A1.5 1.5 0 0 1 1.5 13V3z"/></svg>',
    qrcode: '<svg viewBox="0 0 16 16" width="13" height="13" fill="currentColor"><path d="M2 2h5v5H2V2zm1.5 1.5v2h2v-2h-2zM9 2h5v5H9V2zm1.5 1.5v2h2v-2h-2zM2 9h5v5H2V9zm1.5 1.5v2h2v-2h-2zM9 9h2v2H9V9zm3 0h2v1.5h-2V9zm-3 3h1.5v2H9v-2zm2 2h1.5v-1.5h2V14h-3.5v-2H11v2h1z"/></svg>',
    ocr: '<svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M2 5V3.5A1.5 1.5 0 0 1 3.5 2H5M11 2h1.5A1.5 1.5 0 0 1 14 3.5V5M14 11v1.5a1.5 1.5 0 0 1-1.5 1.5H11M5 14H3.5A1.5 1.5 0 0 1 2 12.5V11"/><path d="M4.5 6.5h7M4.5 9.5h7"/></svg>',
    info: '<svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" stroke-width="1.3"><circle cx="8" cy="8" r="6.5"/><path d="M8 5v.01M8 7.5v4"/></svg>',
    copy: '<svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.3"><rect x="5" y="5" width="8" height="9" rx="1.5"/><path d="M3 11H2.5A1.5 1.5 0 0 1 1 9.5v-7A1.5 1.5 0 0 1 2.5 1h7A1.5 1.5 0 0 1 11 2.5V3"/></svg>',
    eye: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M1 8s3-5 7-5 7 5 7 5-3 5-7 5-7-5-7-5z"/><circle cx="8" cy="8" r="2.5"/></svg>',
    eyeSlash: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M1 1l14 14M6.5 6.5a2.5 2.5 0 0 0 3 3M3.2 4.5C2 5.5 1 8 1 8s3 5 7 5c1.4 0 2.7-.4 3.7-1M6 3.3C6.6 3.1 7.3 3 8 3c4 0 7 5 7 5s-1 1.7-2.3 3"/></svg>',
    help: '<svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.3"><circle cx="8" cy="8" r="6.5"/><path d="M6.2 6.2a2 2 0 1 1 2.8 1.8c-.8.5-1 1-1 1.8M8 12.2v.01" stroke-width="1.3" stroke-linecap="round"/></svg>'
  };

  // 来源 App 高保真彩色小图标
  const APP_ICONS = {
    notes: `<img src="assets/apps/notes.png" width="16" height="16" alt="Notes" class="nook-app-icon-img">`,
    screenshot: `<img src="assets/apps/screenshot.png" width="16" height="16" alt="Screenshot" class="nook-app-icon-img">`,
    figma: `<img src="assets/apps/figma.png" width="16" height="16" alt="Figma" class="nook-app-icon-img">`,
    nook: `<img src="assets/apps/nook.png" width="16" height="16" alt="NookClip" class="nook-app-icon-img">`,
    terminal: `<img src="assets/apps/terminal.png" width="16" height="16" alt="Terminal" class="nook-app-icon-img">`,
    xcode: `<img src="assets/apps/xcode.png" width="16" height="16" alt="Xcode" class="nook-app-icon-img">`,
    safari: `<img src="assets/apps/safari.png" width="16" height="16" alt="Safari" class="nook-app-icon-img">`,
    vscode: `<img src="assets/apps/vscode.png" width="16" height="16" alt="VSCode" class="nook-app-icon-img">`,
    wechat: `<img src="assets/apps/wechat.png" width="16" height="16" alt="WeChat" class="nook-app-icon-img">`,
    finder: `<img src="assets/apps/finder.png" width="16" height="16" alt="Finder" class="nook-app-icon-img">`
  };

  // 核心 UI 字典 (支持简体/繁体/英文动态切换)
  const UI_I18N = {
    'zh-Hans': {
      windowAria: "NookClip 剪贴板测试台",
      searchPlaceholder: "搜索剪贴板或应用...",
      searchClear: "清空搜索",
      cycleTimeTitle: "切换时间分组 (⌘T / 点击下拉)",
      today: "今天",
      yesterday: "昨天",
      this_week: "本周",
      noMatch: "未找到匹配的历史记录",
      // 搜索框展开筛选面板（按类型 4×2 固定网格 + 按标签流式胶囊）
      filterByType: "按类型",
      filterByTag: "按标签",
      filterEmptyType: "暂无此类型的记录",
      filterEmptyTag: "还没有标签，在预览区点 # 即可给条目打标",
      filterNoTagMatch: "没有匹配的标签",
      filterConditionHint: "输入关键词搜索…",
      filterRemoveCondition: "移除筛选条件",
      filterOpenTitle: "展开类型与标签筛选 (⌘↓ / 点击搜索框)",
      rowTimeToggleHint: "点击切换完整日期/周几",
      timeMenuEmpty: "暂无其他时间分组",
      spacerBetween: "至",
      undoToast: (count) => `已删除 ${count} 条记录`,
      undoBtn: "撤销 (⌘Z)",
      batchSelected: (count) => `已选择 ${count} 项`,
      batchEscHint: "⇧↓ 扩展 · Esc 退出",
      batchMerge: "合并粘贴",
      batchDelete: "删除",
      hintSelect: "选择",
      hintPaste: "粘贴",
      // ⌘[ / ⌘] 循环的是「内容类型」，但客户端底栏文案就叫「分类」（MainView.swift 底栏），
      // 这里保留客户端的真实用词，避免落地页与 App 截图对不上
      hintCategory: "分类",
      helpTitle: "快捷键速查 (?)",
      helpRows: [
        { desc: "多选 / 批量模式", keys: ["⇧↓", "⇧v"] },
        { desc: "拷贝当前项", keys: ["⌘C"] },
        { desc: "聚焦搜索框", keys: ["⌘F"] },
        { desc: "纯文本粘贴", keys: ["⌥↩"] },
        { desc: "粘贴并保持打开", keys: ["⌘↩"] },
        { desc: "展开类型 / 标签筛选", keys: ["⌘↓"] },
        { desc: "在全部与各类型间循环", keys: ["⌘[", "⌘]"] },
        { desc: "循环时间分组", keys: ["⌘T"] },
        { desc: "设置条目别名", keys: ["⌘R"] },
        { desc: "收藏 / 取消收藏", keys: ["⌘S"] },
        { desc: "删除当前选中", keys: ["⌘⌫"] },
        { desc: "撤销上次删除", keys: ["⌘Z"] },
        { desc: "分层返回 / 收起面板", keys: ["Esc"] }
      ],
      copyCount: (count) => `复制 ${count} 次`,
      btnOpen: "打开",
      btnOpenBrowser: "在浏览器中打开",
      btnFinder: "在访达中显示",
      starBtnTitle: "收藏 (⌘S)",
      unstarBtnTitle: "取消收藏 (⌘S)",
      deleteBtnTitle: "删除 (⌘⌫)",
      copyCountShort: (count) => `复制 ${count} 次`,
      btnQrTitle: "显示二维码",
      fileMissingBadge: "已失效",
      tagBtnTitle: "标签 (⌘L)",
      statFile: "文件",
      statUrl: "URL",
      shortcutCard: {
        lead: "⌨️ 效率进阶指南：",
        rows: [
          { text: "· ⌥ ↩ ：纯文本粘贴（自动剔除网页/文档字体与背景样式）" },
          { text: "· ⌘ ↩ ：粘贴后保持面板打开（适合连续填表）" },
          { text: "· ⇧ ↓ / ⌘ 点选 ：扩展多选（按 ↩ 合并多条一起粘贴）" },
          { pair: true, spans: ["· ⌘ [ / ⌘ ] ：切换内容类型（跳过空类型）", "· ⌘ T ：循环跳转时间分组"] },
          { pair: true, spans: ["· ⌘ S ：收藏（豁免自动清理）", "· ⌘ R ：为条目设置别名"] },
          { pair: true, spans: ["· ⌘ ⌫ ：删除选中项", "· ⌘ Z ：10 秒内撤销删除"] }
        ]
      },
      sensitiveCard: {
        title: "敏感凭证已通过 AES-256-GCM 本地加密隔离",
        maskBtn: "遮罩密文 (30s 自动重锁倒计时)",
        revealBtn: "查看明文",
        hint: "敏感内容不入全文索引，同步 iCloud 时自动排除，30 秒后自动重新加密。"
      },
      codeTabs: {
        prettify: "美化",
        minify: "压缩",
        raw: "原文",
        copyCode: "拷贝代码"
      },
      ocrCard: {
        title: "提取文字",
        rules: "规则",
        collapse: "收起",
        scanningBadge: "正在识别…",
        offlineBadge: "离线识别",
        ruleFormats: "• <b>支持格式</b>：仅限 PNG、JPG、TIFF 等图片及截图。",
        ruleLanguages: "• <b>语言支持</b>：支持简体中文、繁体中文、英文神经网络检测。",
        ruleLimits: "• <b>识别限制</b>：全程本机离线处理，数据不出设备；自动写入全文检索索引。",
        scanningText: "正在按需加载 Apple Vision 离线 OCR 引擎…",
        copyBtn: "一键复制识别文字",
        notScanned: "尚未提取文字",
        recognizeBtn: "识别文字",
        footerHint: "💡 支持图片中的中文/英文离线提取",
        offlineOcr: "离线 OCR",
        svgSub: "离线实况文本识别演示（支持中英文混合检索）",
        svgHint: "点击图片右下角「提取文字」按钮，体验本地离线文字提取"
      },
      colorCard: {
        copyHex: "点击复制 HEX 格式",
        copyRgb: "点击复制 RGB 格式",
        copied: "已复制",
        hint: "点击行可复制对应格式 · 行内色点与列表条目实时同步"
      },
      fileCard: {
        multiHeader: (count, size) => `${count} 个文件 · 共 ${size}`,
        copyPath: "拷贝路径"
      },
      urlCard: {
        copy: "复制链接"
      },
      appLauncher: {
        header: "应用程序",
        openBadge: "打开 ⏎"
      },
      pasteHudDefault: "已模拟粘贴至前台应用光标处",
      toasts: {
        escReset: "已按下 Esc：分层复位完毕",
        category: (name) => `切换至类型：${name}`,
        favorited: (title) => `已收藏「${title}」★`,
        unfavorited: (title) => `已取消收藏「${title}」`,
        deletedOne: (title) => `已删除「${title}」`,
        deletedBatch: (count) => `已批量删除 ${count} 项记录`,
        undoDeleted: (title) => `已撤销删除「${title}」`,
        renameUpdated: (title) => `别名已更新为：「${title}」`,
        sensitiveRevealed: "已验证本机凭证：明文将在 30 秒后自动重新遮罩",
        sensitiveAutoLocked: "敏感凭证已自动重新加密脱敏",
        sensitiveMasked: "敏感凭证已重锁",
        ocrLoading: "正在加载 Apple Vision 离线引擎…",
        ocrDone: "Apple Vision 离线实况文字提取完成！",
        copiedItem: (title) => `已拷贝「${title}」到剪贴板`,
        pastePlain: (title) => `纯文本粘贴 (⌥↩)：「${title}」➔ 已回填至前台光标处`,
        pasteKeep: (title) => `粘贴且保持打开 (⌘↩)：「${title}」➔ 已回填至前台光标处`,
        pasteQuick: (title) => `一键粘贴 (↩)：「${title}」➔ 已回填至前台光标处`,
        pasteBatch: (count) => `已批量合并粘贴 ${count} 项内容 ➔ 自动回填`,
        appLaunched: (name) => `已模拟激活并打开应用程序：「${name}」`,
        locateGroup: (title) => `已定位时间分组：${title}`,
        resetDemo: "已成功重置 20 条跨时段原生演示数据",
        openSimulated: "已模拟打开文件或链接",
        revealFinderSimulated: "已在访达中显示文件",
        qrShown: "二维码已展示于下方卡片",
        codeCopied: "已复制代码至剪贴板",
        ocrCopied: "已复制提取的 OCR 文字",
        urlCopied: "已复制链接",
        hexCopied: (hex) => `已复制 HEX: ${hex}`,
        rgbCopied: (rgb) => `已复制 RGB: ${rgb}`,
        pathCopied: (name) => `已复制路径: ${name}`
      }
    },
    'zh-Hant': {
      windowAria: "NookClip 剪貼簿測試台",
      searchPlaceholder: "搜尋剪貼簿或應用程式...",
      searchClear: "清除搜尋",
      cycleTimeTitle: "切換時間分組 (⌘T / 點擊下拉)",
      today: "今天",
      yesterday: "昨天",
      this_week: "本週",
      noMatch: "找不到相符的歷史記錄",
      filterByType: "依類型",
      filterByTag: "依標籤",
      filterEmptyType: "目前沒有此類型的記錄",
      filterEmptyTag: "還沒有標籤，在預覽區點 # 即可為項目加上標籤",
      filterNoTagMatch: "找不到相符的標籤",
      filterConditionHint: "輸入關鍵字搜尋…",
      filterRemoveCondition: "移除篩選條件",
      filterOpenTitle: "展開類型與標籤篩選 (⌘↓ / 點擊搜尋框)",
      rowTimeToggleHint: "點擊切換完整日期/星期",
      timeMenuEmpty: "目前沒有其他時間分組",
      spacerBetween: "至",
      undoToast: (count) => `已刪除 ${count} 項記錄`,
      undoBtn: "復原 (⌘Z)",
      batchSelected: (count) => `已選取 ${count} 項`,
      batchEscHint: "⇧↓ 擴展 · Esc 退出",
      batchMerge: "合併貼上",
      batchDelete: "刪除",
      hintSelect: "選取",
      hintPaste: "貼上",
      hintCategory: "分類",
      helpTitle: "快速鍵速查 (?)",
      helpRows: [
        { desc: "多選 / 批次模式", keys: ["⇧↓", "⇧v"] },
        { desc: "拷貝目前項", keys: ["⌘C"] },
        { desc: "聚焦搜尋框", keys: ["⌘F"] },
        { desc: "純文字貼上", keys: ["⌥↩"] },
        { desc: "貼上並保持開啟", keys: ["⌘↩"] },
        { desc: "循環時間錨點", keys: ["⌘T"] },
        { desc: "設定項目別名", keys: ["⌘R"] },
        { desc: "收藏 / 取消收藏", keys: ["⌘S"] },
        { desc: "刪除目前選取", keys: ["⌘⌫"] },
        { desc: "復原上次刪除", keys: ["⌘Z"] },
        { desc: "分層返回 / 收起面板", keys: ["Esc"] }
      ],
      copyCount: (count) => `複製 ${count} 次`,
      btnOpen: "開啟",
      btnOpenBrowser: "在瀏覽器中開啟",
      btnFinder: "在 Finder 中顯示",
      starBtnTitle: "收藏 (⌘S)",
      unstarBtnTitle: "取消收藏 (⌘S)",
      deleteBtnTitle: "刪除 (⌘⌫)",
      copyCountShort: (count) => `複製 ${count} 次`,
      btnQrTitle: "顯示 QR Code",
      fileMissingBadge: "已失效",
      tagBtnTitle: "標籤 (⌘L)",
      statFile: "檔案",
      statUrl: "URL",
      shortcutCard: {
        lead: "⌨️ 效率進階指南：",
        rows: [
          { text: "· ⌥ ↩ ：純文字貼上（自動剔除網頁/文件字體與背景樣式）" },
          { text: "· ⌘ ↩ ：貼上後保持面板開啟（適合連續填表）" },
          { text: "· ⇧ ↓ / ⌘ 點選 ：擴展多選（按 ↩ 合併多條一起貼上）" },
          { pair: true, spans: ["· ⌘ [ / ⌘ ] ：快速切換分類", "· ⌘ T ：循環跳轉時間分組"] },
          { pair: true, spans: ["· ⌘ S ：收藏（豁免自動清理）", "· ⌘ R ：為項目設定別名"] },
          { pair: true, spans: ["· ⌘ ⌫ ：刪除選取項", "· ⌘ Z ：10 秒內復原刪除"] }
        ]
      },
      sensitiveCard: {
        title: "敏感憑證已透過 AES-256-GCM 本地加密隔離",
        maskBtn: "遮罩密文 (30s 自動重鎖倒數)",
        revealBtn: "查看明文",
        hint: "敏感內容不入全文索引，同步 iCloud 時自動排除，30 秒後自動重新加密。"
      },
      codeTabs: {
        prettify: "美化",
        minify: "壓縮",
        raw: "原文",
        copyCode: "拷貝程式碼"
      },
      ocrCard: {
        title: "擷取文字",
        rules: "規則",
        collapse: "收起",
        scanningBadge: "正在辨識…",
        offlineBadge: "離線辨識",
        ruleFormats: "• <b>支援格式</b>：僅限 PNG、JPG、TIFF 等圖片及螢幕截圖。",
        ruleLanguages: "• <b>語言支援</b>：支援簡體中文、繁體中文、英文神經網路偵測。",
        ruleLimits: "• <b>辨識限制</b>：全程本機離線處理，資料不出設備；自動寫入全文檢索索引。",
        scanningText: "正在按需載入 Apple Vision 離線 OCR 引擎…",
        copyBtn: "一鍵複製辨識文字",
        notScanned: "尚未擷取文字",
        recognizeBtn: "辨識文字",
        footerHint: "💡 支援圖片中的中文/英文離線擷取",
        offlineOcr: "離線 OCR",
        svgSub: "離線實況文字辨識示範（支援中英文混合檢索）",
        svgHint: "點擊圖片右下角「擷取文字」按鈕，體驗本機離線文字擷取"
      },
      colorCard: {
        copyHex: "點擊複製 HEX 格式",
        copyRgb: "點擊複製 RGB 格式",
        copied: "已複製",
        hint: "點擊行可複製對應格式 · 行內色點與列表項目即時同步"
      },
      fileCard: {
        multiHeader: (count, size) => `${count} 個檔案 · 共 ${size}`,
        copyPath: "拷貝路徑"
      },
      urlCard: {
        copy: "複製連結"
      },
      appLauncher: {
        header: "應用程式",
        openBadge: "開啟 ⏎"
      },
      pasteHudDefault: "已模擬貼上至前景應用程式游標處",
      toasts: {
        escReset: "已按下 Esc：分層復位完畢",
        category: (name) => `切換至分類：${name}`,
        favorited: (title) => `已收藏「${title}」★`,
        unfavorited: (title) => `已取消收藏「${title}」`,
        deletedOne: (title) => `已刪除「${title}」`,
        deletedBatch: (count) => `已批次刪除 ${count} 項記錄`,
        undoDeleted: (title) => `已復原刪除「${title}」`,
        renameUpdated: (title) => `別名已更新為：「${title}」`,
        sensitiveRevealed: "已驗證本機憑證：明文將在 30 秒後自動重新遮罩",
        sensitiveAutoLocked: "敏感憑證已自動重新加密脫敏",
        sensitiveMasked: "敏感憑證已重鎖",
        ocrLoading: "正在載入 Apple Vision 離線引擎…",
        ocrDone: "Apple Vision 離線實況文字擷取完成！",
        copiedItem: (title) => `已拷貝「${title}」至剪貼簿`,
        pastePlain: (title) => `純文字貼上 (⌥↩)：「${title}」➔ 已回填至前景游標處`,
        pasteKeep: (title) => `貼上且保持開啟 (⌘↩)：「${title}」➔ 已回填至前景游標處`,
        pasteQuick: (title) => `一鍵貼上 (↩)：「${title}」➔ 已回填至前景游標處`,
        pasteBatch: (count) => `已批次合併貼上 ${count} 項內容 ➔ 自動回填`,
        appLaunched: (name) => `已模擬啟動並開啟應用程式：「${name}」`,
        locateGroup: (title) => `已定位時間分組：${title}`,
        resetDemo: "已成功重設 20 條跨時段原生示範資料",
        openSimulated: "已模擬開啟檔案或連結",
        revealFinderSimulated: "已在 Finder 中顯示檔案",
        qrShown: "二維碼已展示於下方卡片",
        codeCopied: "已複製程式碼至剪貼簿",
        ocrCopied: "已複製擷取的 OCR 文字",
        urlCopied: "已複製連結",
        hexCopied: (hex) => `已複製 HEX: ${hex}`,
        rgbCopied: (rgb) => `已複製 RGB: ${rgb}`,
        pathCopied: (name) => `已複製路徑: ${name}`
      }
    },
    'en': {
      windowAria: "NookClip Clipboard Testbench",
      searchPlaceholder: "Search clipboard or app...",
      searchClear: "Clear search",
      cycleTimeTitle: "Cycle time group (⌘T / click for menu)",
      today: "Today",
      yesterday: "Yesterday",
      this_week: "This Week",
      noMatch: "No matching clipboard history found",
      filterByType: "By Type",
      filterByTag: "By Tag",
      filterEmptyType: "Nothing in this type yet",
      filterEmptyTag: "No tags yet — click # in the preview to tag an item",
      filterNoTagMatch: "No matching tags",
      filterConditionHint: "Type to search…",
      filterRemoveCondition: "Remove filter",
      filterOpenTitle: "Open type & tag filters (⌘↓ / click the search field)",
      rowTimeToggleHint: "Click to toggle full date & weekday",
      timeMenuEmpty: "No other time groups",
      spacerBetween: "to",
      undoToast: (count) => `${count} item${count > 1 ? 's' : ''} deleted`,
      undoBtn: "Undo (⌘Z)",
      batchSelected: (count) => `${count} item${count > 1 ? 's' : ''} selected`,
      batchEscHint: "⇧↓ Extend · Esc Exit",
      batchMerge: "Merge & Paste",
      batchDelete: "Delete",
      hintSelect: "Select",
      hintPaste: "Paste",
      hintCategory: "Category",
      helpTitle: "Shortcuts Help (?)",
      helpRows: [
        { desc: "Multi-select / Batch", keys: ["⇧↓", "⇧v"] },
        { desc: "Copy selected item", keys: ["⌘C"] },
        { desc: "Focus search input", keys: ["⌘F"] },
        { desc: "Paste plain text", keys: ["⌥↩"] },
        { desc: "Paste & keep open", keys: ["⌘↩"] },
        { desc: "Open type / tag filters", keys: ["⌘↓"] },
        { desc: "Cycle All ↔ each type", keys: ["⌘[", "⌘]"] },
        { desc: "Cycle time group", keys: ["⌘T"] },
        { desc: "Set item alias", keys: ["⌘R"] },
        { desc: "Toggle favorite", keys: ["⌘S"] },
        { desc: "Delete selected", keys: ["⌘⌫"] },
        { desc: "Undo last delete", keys: ["⌘Z"] },
        { desc: "Layered dismiss / hide", keys: ["Esc"] }
      ],
      copyCount: (count) => `Copied ${count} time${count > 1 ? 's' : ''}`,
      btnOpen: "Open",
      btnOpenBrowser: "Open in Browser",
      btnFinder: "Reveal in Finder",
      starBtnTitle: "Favorite (⌘S)",
      unstarBtnTitle: "Unfavorite (⌘S)",
      deleteBtnTitle: "Delete (⌘⌫)",
      copyCountShort: (count) => `Copied ${count}×`,
      btnQrTitle: "Show QR code",
      fileMissingBadge: "Missing",
      tagBtnTitle: "Tags (⌘L)",
      statFile: "File",
      statUrl: "URL",
      shortcutCard: {
        lead: "⌨️ Pro Efficiency Guide:",
        rows: [
          { text: "· ⌥ ↩ : Plain text paste (auto strip fonts & styles)" },
          { text: "· ⌘ ↩ : Paste and keep panel open (great for filling forms)" },
          { text: "· ⇧ ↓ / ⌘ Click : Multi-select (press ↩ to merge & paste)" },
          { pair: true, spans: ["· ⌘ [ / ⌘ ] : Switch category", "· ⌘ T : Jump time group"] },
          { pair: true, spans: ["· ⌘ S : Favorite (exempt from cleanup)", "· ⌘ R : Set alias"] },
          { pair: true, spans: ["· ⌘ ⌫ : Delete selected", "· ⌘ Z : Undo delete within 10s"] }
        ]
      },
      sensitiveCard: {
        title: "Credential isolated via local AES-256-GCM encryption",
        maskBtn: "Mask (Auto-lock in 30s)",
        revealBtn: "Reveal Plaintext",
        hint: "Excluded from search index & iCloud sync; re-encrypted after 30 seconds."
      },
      codeTabs: {
        prettify: "Prettify",
        minify: "Minify",
        raw: "Raw",
        copyCode: "Copy Code"
      },
      ocrCard: {
        title: "Recognized Text",
        rules: "Rules",
        collapse: "Collapse",
        scanningBadge: "Scanning…",
        offlineBadge: "Offline OCR",
        ruleFormats: "• <b>Supported Formats</b>: PNG, JPG, TIFF images and screenshots.",
        ruleLanguages: "• <b>Languages</b>: Simplified Chinese, Traditional Chinese, and English neural detection.",
        ruleLimits: "• <b>Privacy</b>: 100% on-device offline processing; auto-indexed for FTS5.",
        scanningText: "Loading Apple Vision offline OCR engine…",
        copyBtn: "Copy Recognized Text",
        notScanned: "No text recognized yet",
        recognizeBtn: "Recognize Text",
        footerHint: "💡 Supports offline CJK & English extraction from images",
        offlineOcr: "Offline OCR",
        svgSub: "Offline Live Text OCR Demo (supports mixed CJK & English)",
        svgHint: "Click \"Recognize Text\" at bottom right to extract text locally"
      },
      colorCard: {
        copyHex: "Click to copy HEX format",
        copyRgb: "Click to copy RGB format",
        copied: "Copied",
        hint: "Click row to copy format · Row color swatch syncs in real-time"
      },
      fileCard: {
        multiHeader: (count, size) => `${count} files · Total ${size}`,
        copyPath: "Copy Path"
      },
      urlCard: {
        copy: "Copy Link"
      },
      appLauncher: {
        header: "Applications",
        openBadge: "Open ⏎"
      },
      pasteHudDefault: "Simulated paste to frontmost cursor",
      toasts: {
        escReset: "Esc pressed: Navigation reset",
        category: (name) => `Switched to category: ${name}`,
        favorited: (title) => `Added "${title}" to favorites ★`,
        unfavorited: (title) => `Removed "${title}" from favorites`,
        deletedOne: (title) => `Deleted "${title}"`,
        deletedBatch: (count) => `Batch deleted ${count} items`,
        undoDeleted: (title) => `Restored "${title}"`,
        renameUpdated: (title) => `Alias updated to: "${title}"`,
        sensitiveRevealed: "Local credential verified: Plaintext will auto-mask in 30s",
        sensitiveAutoLocked: "Sensitive credential auto re-encrypted",
        sensitiveMasked: "Sensitive credential re-locked",
        ocrLoading: "Loading Apple Vision offline engine…",
        ocrDone: "Apple Vision offline text extraction completed!",
        copiedItem: (title) => `Copied "${title}" to clipboard`,
        pastePlain: (title) => `Plain text paste (⌥↩): "${title}" ➔ Pasted at cursor`,
        pasteKeep: (title) => `Paste & keep open (⌘↩): "${title}" ➔ Pasted at cursor`,
        pasteQuick: (title) => `Quick paste (↩): "${title}" ➔ Pasted at cursor`,
        pasteBatch: (count) => `Batch merged & pasted ${count} items ➔ Pasted at cursor`,
        appLaunched: (name) => `Simulated launch of application: "${name}"`,
        locateGroup: (title) => `Navigated to time group: ${title}`,
        resetDemo: "Reset 20 native demo items across timelines",
        openSimulated: "Simulated opening file or link",
        revealFinderSimulated: "File revealed in Finder",
        qrShown: "QR code displayed in card below",
        codeCopied: "Copied code to clipboard",
        ocrCopied: "Copied recognized OCR text",
        urlCopied: "Copied link",
        hexCopied: (hex) => `Copied HEX: ${hex}`,
        rgbCopied: (rgb) => `Copied RGB: ${rgb}`,
        pathCopied: (name) => `Copied path: ${name}`
      }
    }
  };

  // 100% 对齐官方界面的基础数据结构
  //
  // 时间分组不再硬编码在每条记录上：`isoDate` 是唯一的权威时间戳，
  // 分档与标题统一由 applyTimeline()/deriveGroupMeta() 按「自然日差」推导——
  // 与客户端 Rust `bucket_of` / Swift `Timeline.group` 同一套规则
  // （7 天内按天：今天 / 昨天 / 本周；7 天外直接进月份 / 年份归档，
  // 已退役的「上周」档不再出现）。
  const BASE_DEMO_ITEMS = [
    {
      id: "demo-1",
      kind: "text",
      category: 1,
      sourceApp: "notes",
      isFavorite: true,
      tags: ["tag-frontend", "tag-docs"],
      copyCount: 2,
      snippetIcon: '<svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="#38BDF8" stroke-width="1.6" style="display:inline-block;vertical-align:-1px;margin-right:2px;"><rect x="3" y="2" width="10" height="12" rx="1.5"/><path d="M5 5h6M5 8h6M5 11h4"/></svg>'
    },
    {
      id: "demo-2",
      kind: "image",
      category: 2,
      sourceApp: "screenshot",
      isFavorite: false,
      tags: ["tag-docs"],
      copyCount: 1,
      ocrText: null
    },
    {
      id: "demo-3",
      kind: "color",
      category: 6,
      sourceApp: "figma",
      colorHex: "#007AFF",
      rgbValue: "0, 122, 255",
      isFavorite: false,
      tags: ["tag-design", "tag-frontend"],
      copyCount: 5
    },
    {
      id: "demo-4",
      kind: "text",
      category: 1,
      sourceApp: "nook",
      isFavorite: true,
      tags: ["tag-docs"],
      copyCount: 3,
      snippetIcon: '💡 '
    },
    {
      id: "demo-5",
      kind: "sensitive",
      category: 7,
      sourceApp: "terminal",
      plainText: "sk-proj-NookDemoKeyForLocalEncryption256GCM",
      isSensitive: true,
      isFavorite: false,
      tags: ["tag-security", "tag-backend"],
      copyCount: 1,
      snippetIcon: '<span style="color:#4ADE80;font-family:monospace;font-size:10px;font-weight:bold;margin-right:2px;">&gt;_</span>'
    },
    {
      id: "demo-6",
      kind: "json",
      category: 5,
      sourceApp: "xcode",
      summary: '{\n  "app": "NookClip",\n  "engine": "Rust + SQLite FTS5",\n  "privacy": {\n    "localOnly": true,\n    "encryption": "AES-256-GCM"\n  },\n  "shortcuts": ["⌘⇧V", "⏎", "⌥⏎", "⌘S"]\n}',
      isFavorite: true,
      tags: ["tag-frontend", "tag-backend"],
      copyCount: 6
    },
    {
      id: "demo-7",
      kind: "text",
      category: 1,
      sourceApp: "xcode",
      isFavorite: false,
      tags: ["tag-frontend", "tag-docs"],
      copyCount: 1
    },
    {
      id: "demo-8",
      kind: "url",
      category: 4,
      sourceApp: "safari",
      summary: "https://github.com/lx3xun/nook-clip/pull/75421",
      isFavorite: true,
      tags: ["tag-docs", "tag-frontend"],
      copyCount: 2
    },
    {
      id: "demo-8b",
      kind: "file",
      category: 3,
      sourceApp: "finder",
      summary: "/Users/alex/Projects/nook/migrations/20261015_add_fts5.sql",
      isFavorite: false,
      tags: ["tag-database", "tag-backend"],
      copyCount: 1
    },
    {
      id: "demo-9",
      kind: "color",
      category: 6,
      sourceApp: "figma",
      summary: "#6366F1",
      colorHex: "#6366F1",
      rgbValue: "99, 102, 241",
      isFavorite: false,
      tags: ["tag-design"],
      copyCount: 4
    },
    {
      id: "demo-10",
      kind: "code",
      category: 5,
      sourceApp: "vscode",
      summary: "pub struct LockFreeQueue<T> {\n    head: AtomicPtr<Node<T>>,\n    tail: AtomicPtr<Node<T>>,\n}\n\nimpl<T> LockFreeQueue<T> {\n    pub fn new() -> Self {\n        let dummy = Box::into_raw(Box::new(Node::empty()));\n        Self {\n            head: AtomicPtr::new(dummy),\n            tail: AtomicPtr::new(dummy),\n        }\n    }\n}",
      isFavorite: false,
      tags: ["tag-backend"],
      copyCount: 3
    },
    {
      id: "demo-11",
      kind: "url",
      category: 4,
      sourceApp: "safari",
      summary: "https://meeting.feishu.cn/j/948271842?pwd=nook",
      isFavorite: false,
      tags: ["tag-docs"],
      copyCount: 1
    },
    {
      id: "demo-12",
      kind: "code",
      category: 5,
      sourceApp: "terminal",
      summary: "#!/usr/bin/env bash\nxcrun notarytool submit NookClip.dmg \\\n  --apple-id \"dev@lx3xun.com\" \\\n  --team-id \"A1B2C3D4E5\" \\\n  --keychain-profile \"AC_PASSWORD\" \\\n  --wait",
      isFavorite: true,
      tags: ["tag-security", "tag-backend"],
      copyCount: 7
    },
    {
      id: "demo-13",
      kind: "sensitive",
      category: 7,
      sourceApp: "terminal",
      plainText: "AKIAIOSFODNN7EXAMPLE3M7Q",
      isSensitive: true,
      isFavorite: false,
      tags: ["tag-security", "tag-backend"],
      copyCount: 2
    },
    {
      id: "demo-14",
      kind: "file",
      category: 3,
      sourceApp: "finder",
      summary: "/Users/alex/Documents/NookClip-Architecture.pdf\n/Users/alex/Documents/Database-Schema.sql",
      isFavorite: false,
      tags: ["tag-docs", "tag-database"],
      copyCount: 3
    },
    {
      id: "demo-15",
      kind: "code",
      category: 5,
      sourceApp: "vscode",
      summary: "module.exports = {\n  theme: {\n    extend: {\n      colors: {\n        nook: { 50: '#F0F9FF', 500: '#007AFF', 900: '#0C4A6E' }\n      }\n    }\n  }\n};",
      isFavorite: false,
      tags: ["tag-design", "tag-frontend"],
      copyCount: 1
    },
    {
      id: "demo-16",
      kind: "text",
      category: 1,
      sourceApp: "notes",
      isFavorite: true,
      tags: ["tag-database", "tag-backend", "tag-docs"],
      copyCount: 4
    },
    {
      id: "demo-17",
      kind: "text",
      category: 1,
      sourceApp: "notes",
      isFavorite: false,
      tags: ["tag-docs"],
      copyCount: 2
    },
    {
      id: "demo-18",
      kind: "code",
      category: 5,
      sourceApp: "xcode",
      summary: "let read_pool = Pool::builder()\n    .max_size(16)\n    .build(read_manager)?;\nlet write_pool = Pool::builder()\n    .max_size(4)\n    .build(write_manager)?;",
      isFavorite: false,
      tags: ["tag-database", "tag-backend"],
      copyCount: 1
    },
    {
      id: "demo-19",
      kind: "sensitive",
      category: 7,
      sourceApp: "wechat",
      plainText: "wx94f2847291a4b810e8a2",
      isSensitive: true,
      isFavorite: false,
      tags: ["tag-security", "tag-backend"],
      copyCount: 1
    }
  ];

  // 每条数据的本地化字段对照表
  const ITEM_I18N = {
    'zh-Hans': {
      'demo-1': {
        title: "进阶效率快捷键速查卡（常驻备忘）",
        summary: "⌨️ 效率进阶指南：\n• ⌥ ↩ ：纯文本粘贴（自动剔除网页/文档字体与背景样式）\n• ⌘ ↩ ：粘贴后保持面板打开（适合连续填表）\n• ⇧ ↓ / ⌘ 点选 ：扩展多选（按 ↩ 合并多条一起粘贴）\n• ⌘ [ / ⌘ ] ：切换内容类型（跳过空类型）  • ⌘ T ：循环跳转时间分组\n• ⌘ S ：收藏（豁免自动清理） • ⌘ R ：为条目设置别名\n• ⌘ ⌫ ：删除选中项          • ⌘ Z ：10 秒内撤销删除",
        source: "备忘录",
        timeStr: "今天 11:29",
        snippet: "效率...内撤销删除",
        metaLine: "7 行 · 208 字符",
        timeGroup: "today",
        groupTitle: "今天"
      },
      'demo-2': {
        title: "图片与离线 Vision OCR 演示",
        summary: "640 × 320 · PNG 图像文件",
        source: "截图",
        timeStr: "今天 11:10",
        snippet: "640 × 320",
        metaLine: "640 × 320 · 42 KB",
        timeGroup: "today",
        groupTitle: "今天",
        badge: "PNG",
        rawOcrText: "NookClip · Apple Vision OCR\n离线实况文本识别演示（支持中英文混合检索）\n点击图片右下角「提取文字」按钮，体验本地离线文字提取\n100% On-Device · Zero Cloud Upload · Instant FTS5"
      },
      'demo-3': {
        title: "macOS 系统强调蓝（色彩胶囊演示）",
        summary: "#007AFF",
        source: "Figma",
        timeStr: "今天 10:40",
        snippet: "#007AFF",
        metaLine: "#007AFF",
        timeGroup: "today",
        groupTitle: "今天"
      },
      'demo-4': {
        title: "欢迎使用 NookClip — 30 秒上手指南",
        summary: "💡 核心主循环：在任意应用中复制内容 → 按 ⌘ ⇧ V 呼出面板 → 按 ↑ / ↓ 选择 → 按 ⏎ 直接粘贴回原应用。\n\n✨ 试试现在直接输入「API」或「蓝」：列表态无需点搜索框，直接打字即触发毫秒级全历史搜索！",
        source: "NookClip",
        timeStr: "今天 10:39",
        snippet: "核心...史搜索!",
        metaLine: "4 行 · 136 字符",
        timeGroup: "today",
        groupTitle: "今天"
      },
      'demo-5': {
        title: "OpenAI API 密钥（隐私加密保护演示）",
        summary: "sk-proj-••••••••56GCM",
        source: "终端",
        timeStr: "今天 10:38",
        snippet: "sk-proj-...56GCM",
        metaLine: "AES-256 加密 · 本地隔离",
        timeGroup: "today",
        groupTitle: "今天",
        badge: "私密"
      },
      'demo-6': {
        title: "代码高亮与 JSON 格式化演示",
        source: "Xcode",
        timeStr: "今天 10:36",
        snippet: '{ "app":...", "⌘S"] }',
        metaLine: "JSON · 8 行 · 162 字符",
        timeGroup: "today",
        groupTitle: "今天",
        badge: "JSON"
      },
      'demo-7': {
        title: "SwiftUI 状态管理实践小结",
        summary: "使用 @Observable 替代 ObservableObject，配合细粒度属性依赖收集，避免整个视图树无效重复求值，大幅降低复杂长列表布局开销。",
        source: "Xcode",
        timeStr: "昨天 13:01",
        snippet: "使用 @O...布局开销。",
        metaLine: "1 行 · 74 字符",
        timeGroup: "yesterday",
        groupTitle: "昨天"
      },
      'demo-8': {
        title: "GitHub PR 合并指引",
        source: "Safari",
        timeStr: "昨天 05:49",
        snippet: "github.co...ull/75421",
        metaLine: "网页链接 · 48 字符",
        timeGroup: "yesterday",
        groupTitle: "昨天"
      },
      'demo-8b': {
        title: "20261015_add_fts5.sql",
        source: "访达",
        timeStr: "昨天 02:15",
        snippet: "20261015_add_fts5.sql",
        metaLine: "8.4 KB",
        fileList: [
          { name: "20261015_add_fts5.sql", size: "8.4 KB", path: "/Users/alex/Projects/nook/migrations/20261015_add_fts5.sql" }
        ],
        timeGroup: "yesterday",
        groupTitle: "昨天"
      },
      'demo-9': {
        title: "色彩胶囊示例",
        source: "Figma",
        timeStr: "10月14日 22:37",
        snippet: "#6366F1",
        metaLine: "#6366F1",
        timeGroup: "this_week",
        groupTitle: "本周"
      },
      'demo-10': {
        title: "Rust 并发无锁设计",
        source: "Visual Studio Code",
        timeStr: "10月13日 13:01",
        snippet: "pub struct LockFreeQueue...",
        metaLine: "Rust 代码 · 14 行 · 246 字符",
        timeGroup: "this_week",
        groupTitle: "本周",
        badge: "Rust"
      },
      'demo-11': {
        title: "团队周会飞书会议邀请链接",
        source: "Safari",
        timeStr: "10月12日 09:30",
        snippet: "feishu.cn/j/948271842",
        metaLine: "在线会议 · 44 字符",
        timeGroup: "this_week",
        groupTitle: "本周"
      },
      'demo-12': {
        title: "Apple Developer 证书配置与 notarize.sh",
        source: "终端",
        timeStr: "10月11日 16:40",
        snippet: "xcrun notarytool submit...",
        metaLine: "Shell 脚本 · 6 行 · 168 字符",
        timeGroup: "this_week",
        groupTitle: "本周",
        badge: "Shell"
      },
      'demo-13': {
        title: "AWS S3 生产存储桶访问密钥配置",
        summary: "AKIA••••••••••••3M7Q",
        source: "终端",
        timeStr: "10月8日 17:22",
        snippet: "AKIA...3M7Q",
        metaLine: "AWS 访问密钥 · 加密隔离",
        isoDate: "2026-10-08T17:22:00",
        timeGroup: "month-10",
        groupTitle: "10月",
        badge: "私密"
      },
      'demo-14': {
        title: "NookClip-Architecture.pdf 等 2 个文件",
        source: "访达",
        timeStr: "10月7日 14:05",
        snippet: "NookClip-Architecture.pdf",
        metaLine: "2 个文件 · 共 2.4 MB",
        fileList: [
          { name: "NookClip-Architecture.pdf", size: "2.1 MB", path: "/Users/alex/Documents/NookClip-Architecture.pdf" },
          { name: "Database-Schema.sql", size: "320 KB", path: "/Users/alex/Documents/Database-Schema.sql" }
        ],
        isoDate: "2026-10-07T14:05:00",
        timeGroup: "month-10",
        groupTitle: "10月"
      },
      'demo-15': {
        title: "TailwindCSS 3.4 扩展调色盘配置",
        source: "Visual Studio Code",
        timeStr: "10月5日 11:30",
        snippet: "colors: { nook: ... }",
        metaLine: "JavaScript · 9 行 · 142 字符",
        isoDate: "2026-10-05T11:30:00",
        timeGroup: "month-10",
        groupTitle: "10月",
        badge: "JS"
      },
      'demo-16': {
        title: "SQLite WAL 模式与 FTS5 全文检索压测记录",
        summary: "在 50,000 条剪贴板历史压力测试下：\n• 单条写入延迟：平均 0.32 ms\n• FTS5 毫秒前缀匹配延迟：平均 0.78 ms\n• 内存常驻增量：仅增加 2.4 MB，完全达到原生轻量指标！",
        source: "备忘录",
        timeStr: "9月28日 20:10",
        snippet: "在 50,000 条剪贴板历史压测...",
        metaLine: "5 行 · 128 字符",
        isoDate: "2026-09-28T20:10:00",
        timeGroup: "month-09",
        groupTitle: "9月"
      },
      'demo-17': {
        title: "NookClip v0.1.0 发布规划会议备忘",
        summary: "1. 剪贴板主循环体验对齐 macOS 14 原生窗口\n2. 本地 AES-256 加密与自动脱敏\n3. 离线 Vision OCR 与二维码跨端\n4. 交付开源官网与交互测试台",
        source: "备忘录",
        timeStr: "9月22日 15:45",
        snippet: "1. 剪贴板主循环体验...",
        metaLine: "4 行 · 98 字符",
        isoDate: "2026-09-22T15:45:00",
        timeGroup: "month-09",
        groupTitle: "9月"
      },
      'demo-18': {
        title: "PostgreSQL 读写分离连接池配置",
        source: "Xcode",
        timeStr: "9月15日 18:20",
        snippet: "let read_pool = Pool...",
        metaLine: "Rust 代码 · 6 行 · 158 字符",
        isoDate: "2026-09-15T18:20:00",
        timeGroup: "month-09",
        groupTitle: "9月",
        badge: "Rust"
      },
      'demo-19': {
        title: "微信开放平台应用凭据 AppSecret",
        summary: "wx94••••••••••••e8a2",
        source: "微信",
        timeStr: "9月08日 10:05",
        snippet: "wx94...e8a2",
        metaLine: "微信 AppSecret · 加密凭证",
        isoDate: "2026-09-08T10:05:00",
        timeGroup: "month-09",
        groupTitle: "9月",
        badge: "私密"
      }
    },
    'zh-Hant': {
      'demo-1': {
        title: "進階效率快速鍵速查卡（常駐備忘）",
        summary: "⌨️ 效率進階指南：\n• ⌥ ↩ ：純文字貼上（自動剔除網頁/文件字體與背景樣式）\n• ⌘ ↩ ：貼上後保持面板開啟（適合連續填表）\n• ⇧ ↓ / ⌘ 點選 ：擴展多選（按 ↩ 合併多條一起貼上）\n• ⌘ [ / ⌘ ] ：快速切換分類  • ⌘ T ：循環跳轉時間分組\n• ⌘ S ：收藏（豁免自動清理） • ⌘ R ：為項目設定別名\n• ⌘ ⌫ ：刪除選取項          • ⌘ Z ：10 秒內復原刪除",
        source: "備忘錄",
        timeStr: "今天 11:29",
        snippet: "效率...內復原刪除",
        metaLine: "7 行 · 208 字元",
        timeGroup: "today",
        groupTitle: "今天"
      },
      'demo-2': {
        title: "圖片與離線 Vision OCR 示範",
        summary: "640 × 320 · PNG 圖片檔案",
        source: "截圖",
        timeStr: "今天 11:10",
        snippet: "640 × 320",
        metaLine: "640 × 320 · 42 KB",
        timeGroup: "today",
        groupTitle: "今天",
        badge: "PNG",
        rawOcrText: "NookClip · Apple Vision OCR\n離線實況文字辨識示範（支援中英文混合檢索）\n點擊圖片右下角「擷取文字」按鈕，體驗本機離線文字擷取\n100% On-Device · Zero Cloud Upload · Instant FTS5"
      },
      'demo-3': {
        title: "macOS 系統強調藍（色彩膠囊示範）",
        summary: "#007AFF",
        source: "Figma",
        timeStr: "今天 10:40",
        snippet: "#007AFF",
        metaLine: "#007AFF",
        timeGroup: "today",
        groupTitle: "今天"
      },
      'demo-4': {
        title: "歡迎使用 NookClip — 30 秒快速上手指南",
        summary: "💡 核心主迴圈：在任意應用程式中複製內容 → 按 ⌘ ⇧ V 呼叫面板 → 按 ↑ / ↓ 選取 → 按 ⏎ 直接貼回原應用程式。\n\n✨ 試試現在直接輸入「API」或「藍」：列表態無須點搜尋框，直接鍵入即觸發毫秒級全歷史搜尋！",
        source: "NookClip",
        timeStr: "今天 10:39",
        snippet: "核心...史搜尋!",
        metaLine: "4 行 · 136 字元",
        timeGroup: "today",
        groupTitle: "今天"
      },
      'demo-5': {
        title: "OpenAI API 金鑰（隱私加密保護示範）",
        summary: "sk-proj-••••••••56GCM",
        source: "終端機",
        timeStr: "今天 10:38",
        snippet: "sk-proj-...56GCM",
        metaLine: "AES-256 加密 · 本地隔離",
        timeGroup: "today",
        groupTitle: "今天",
        badge: "私密"
      },
      'demo-6': {
        title: "程式碼突顯與 JSON 格式化示範",
        source: "Xcode",
        timeStr: "今天 10:36",
        snippet: '{ "app":...", "⌘S"] }',
        metaLine: "JSON · 8 行 · 162 字元",
        timeGroup: "today",
        groupTitle: "今天",
        badge: "JSON"
      },
      'demo-7': {
        title: "SwiftUI 狀態管理實踐小結",
        summary: "使用 @Observable 替代 ObservableObject，配合細粒度屬性相依性收集，避免整個視圖樹無效重複求值，大幅降低複雜長列表版面配置開銷。",
        source: "Xcode",
        timeStr: "昨天 13:01",
        snippet: "使用 @O...版面配置開銷。",
        metaLine: "1 行 · 74 字元",
        timeGroup: "yesterday",
        groupTitle: "昨天"
      },
      'demo-8': {
        title: "GitHub PR 合併指引",
        source: "Safari",
        timeStr: "昨天 05:49",
        snippet: "github.co...ull/75421",
        metaLine: "網頁連結 · 48 字元",
        timeGroup: "yesterday",
        groupTitle: "昨天"
      },
      'demo-8b': {
        title: "20261015_add_fts5.sql",
        source: "Finder",
        timeStr: "昨天 02:15",
        snippet: "20261015_add_fts5.sql",
        metaLine: "8.4 KB",
        fileList: [
          { name: "20261015_add_fts5.sql", size: "8.4 KB", path: "/Users/alex/Projects/nook/migrations/20261015_add_fts5.sql" }
        ],
        timeGroup: "yesterday",
        groupTitle: "昨天"
      },
      'demo-9': {
        title: "色彩膠囊範例",
        source: "Figma",
        timeStr: "10月14日 22:37",
        snippet: "#6366F1",
        metaLine: "#6366F1",
        timeGroup: "this_week",
        groupTitle: "本週"
      },
      'demo-10': {
        title: "Rust 並行無鎖設計",
        source: "Visual Studio Code",
        timeStr: "10月13日 13:01",
        snippet: "pub struct LockFreeQueue...",
        metaLine: "Rust 程式碼 · 14 行 · 246 字元",
        timeGroup: "this_week",
        groupTitle: "本週",
        badge: "Rust"
      },
      'demo-11': {
        title: "團隊週會飛書會議邀請連結",
        source: "Safari",
        timeStr: "10月12日 09:30",
        snippet: "feishu.cn/j/948271842",
        metaLine: "線上會議 · 44 字元",
        timeGroup: "this_week",
        groupTitle: "本週"
      },
      'demo-12': {
        title: "Apple Developer 憑證配置與 notarize.sh",
        source: "終端機",
        timeStr: "10月11日 16:40",
        snippet: "xcrun notarytool submit...",
        metaLine: "Shell 指令稿 · 6 行 · 168 字元",
        timeGroup: "this_week",
        groupTitle: "本週",
        badge: "Shell"
      },
      'demo-13': {
        title: "AWS S3 生產儲存貯體存取金鑰配置",
        summary: "AKIA••••••••••••3M7Q",
        source: "終端機",
        timeStr: "10月8日 17:22",
        snippet: "AKIA...3M7Q",
        metaLine: "AWS 存取金鑰 · 加密隔離",
        isoDate: "2026-10-08T17:22:00",
        timeGroup: "month-10",
        groupTitle: "10月",
        badge: "私密"
      },
      'demo-14': {
        title: "NookClip-Architecture.pdf 等 2 個檔案",
        source: "Finder",
        timeStr: "10月7日 14:05",
        snippet: "NookClip-Architecture.pdf",
        metaLine: "2 個檔案 · 共 2.4 MB",
        fileList: [
          { name: "NookClip-Architecture.pdf", size: "2.1 MB", path: "/Users/alex/Documents/NookClip-Architecture.pdf" },
          { name: "Database-Schema.sql", size: "320 KB", path: "/Users/alex/Documents/Database-Schema.sql" }
        ],
        isoDate: "2026-10-07T14:05:00",
        timeGroup: "month-10",
        groupTitle: "10月"
      },
      'demo-15': {
        title: "TailwindCSS 3.4 擴展調色盤配置",
        source: "Visual Studio Code",
        timeStr: "10月5日 11:30",
        snippet: "colors: { nook: ... }",
        metaLine: "JavaScript · 9 行 · 142 字元",
        isoDate: "2026-10-05T11:30:00",
        timeGroup: "month-10",
        groupTitle: "10月",
        badge: "JS"
      },
      'demo-16': {
        title: "SQLite WAL 模式與 FTS5 全文檢索壓力測試記錄",
        summary: "在 50,000 條剪貼簿歷史壓力測試下：\n• 單條寫入延遲：平均 0.32 ms\n• FTS5 毫秒前綴匹配延遲：平均 0.78 ms\n• 記憶體常駐增量：僅增加 2.4 MB，完全達到原生輕量指標！",
        source: "備忘錄",
        timeStr: "9月28日 20:10",
        snippet: "在 50,000 條剪貼簿歷史壓力測試...",
        metaLine: "5 行 · 128 字元",
        isoDate: "2026-09-28T20:10:00",
        timeGroup: "month-09",
        groupTitle: "9月"
      },
      'demo-17': {
        title: "NookClip v0.1.0 發布規劃會議備忘",
        summary: "1. 剪貼簿主迴圈體驗對齊 macOS 14 原生視窗\n2. 本機 AES-256 加密與自動脫敏\n3. 離線 Vision OCR 與二維碼跨端\n4. 交付開源官網與互動測試台",
        source: "備忘錄",
        timeStr: "9月22日 15:45",
        snippet: "1. 剪貼簿主迴圈體驗...",
        metaLine: "4 行 · 98 字元",
        isoDate: "2026-09-22T15:45:00",
        timeGroup: "month-09",
        groupTitle: "9月"
      },
      'demo-18': {
        title: "PostgreSQL 讀寫分離連線池配置",
        source: "Xcode",
        timeStr: "9月15日 18:20",
        snippet: "let read_pool = Pool...",
        metaLine: "Rust 程式碼 · 6 行 · 158 字元",
        isoDate: "2026-09-15T18:20:00",
        timeGroup: "month-09",
        groupTitle: "9月",
        badge: "Rust"
      },
      'demo-19': {
        title: "微信開放平台應用憑證 AppSecret",
        summary: "wx94••••••••••••e8a2",
        source: "微信",
        timeStr: "9月08日 10:05",
        snippet: "wx94...e8a2",
        metaLine: "微信 AppSecret · 加密憑證",
        isoDate: "2026-09-08T10:05:00",
        timeGroup: "month-09",
        groupTitle: "9月",
        badge: "私密"
      }
    },
    'en': {
      'demo-1': {
        title: "Pro Shortcuts Cheat Sheet (Pinned Memo)",
        summary: "⌨️ Pro Efficiency Guide:\n• ⌥ ↩ : Plain text paste (auto strip fonts & styles)\n• ⌘ ↩ : Paste and keep panel open (great for filling forms)\n• ⇧ ↓ / ⌘ Click : Multi-select (press ↩ to merge & paste)\n• ⌘ [ / ⌘ ] : Switch category  • ⌘ T : Jump time group\n• ⌘ S : Favorite (exempt from cleanup)  • ⌘ R : Set alias\n• ⌘ ⌫ : Delete selected  • ⌘ Z : Undo delete within 10s",
        source: "Notes",
        timeStr: "Today 11:29",
        snippet: "Pro Efficiency...Undo delete",
        metaLine: "7 lines · 208 chars",
        timeGroup: "today",
        groupTitle: "Today"
      },
      'demo-2': {
        title: "Image & Offline Vision OCR Demo",
        summary: "640 × 320 · PNG Image File",
        source: "Screenshot",
        timeStr: "Today 11:10",
        snippet: "640 × 320",
        metaLine: "640 × 320 · 42 KB",
        timeGroup: "today",
        groupTitle: "Today",
        badge: "PNG",
        rawOcrText: "NookClip · Apple Vision OCR\nOffline Live Text OCR Demo (supports mixed CJK & English)\nClick \"Recognize Text\" at bottom right to extract text locally\n100% On-Device · Zero Cloud Upload · Instant FTS5"
      },
      'demo-3': {
        title: "macOS Accent Blue (Color Capsule Demo)",
        summary: "#007AFF",
        source: "Figma",
        timeStr: "Today 10:40",
        snippet: "#007AFF",
        metaLine: "#007AFF",
        timeGroup: "today",
        groupTitle: "Today"
      },
      'demo-4': {
        title: "Welcome to NookClip — 30s Quick Start",
        summary: "💡 Core Loop: Copy anywhere → Press ⌘ ⇧ V to invoke panel → Use ↑ / ↓ to select → Press ⏎ to paste back directly.\n\n✨ Try typing \"API\" or \"Blue\" right now: type directly to trigger instant full-history search without clicking the search box!",
        source: "NookClip",
        timeStr: "Today 10:39",
        snippet: "Core Loop...instant search!",
        metaLine: "4 lines · 136 chars",
        timeGroup: "today",
        groupTitle: "Today"
      },
      'demo-5': {
        title: "OpenAI API Secret Key (Encryption Demo)",
        summary: "sk-proj-••••••••56GCM",
        source: "Terminal",
        timeStr: "Today 10:38",
        snippet: "sk-proj-...56GCM",
        metaLine: "AES-256 Encrypted · Local Isolation",
        timeGroup: "today",
        groupTitle: "Today",
        badge: "Private"
      },
      'demo-6': {
        title: "Code Highlighting & JSON Formatting Demo",
        source: "Xcode",
        timeStr: "Today 10:36",
        snippet: '{ "app":...", "⌘S"] }',
        metaLine: "JSON · 8 lines · 162 chars",
        timeGroup: "today",
        groupTitle: "Today",
        badge: "JSON"
      },
      'demo-7': {
        title: "SwiftUI State Management Practice Note",
        summary: "Using @Observable instead of ObservableObject with granular property dependency tracking avoids redundant view tree evaluation and reduces list layout overhead.",
        source: "Xcode",
        timeStr: "Yesterday 13:01",
        snippet: "Using @O...layout overhead.",
        metaLine: "1 line · 74 chars",
        timeGroup: "yesterday",
        groupTitle: "Yesterday"
      },
      'demo-8': {
        title: "GitHub PR Merge Guidelines",
        source: "Safari",
        timeStr: "Yesterday 05:49",
        snippet: "github.co...ull/75421",
        metaLine: "Web link · 48 chars",
        timeGroup: "yesterday",
        groupTitle: "Yesterday"
      },
      'demo-8b': {
        title: "20261015_add_fts5.sql",
        source: "Finder",
        timeStr: "Yesterday 02:15",
        snippet: "20261015_add_fts5.sql",
        metaLine: "8.4 KB",
        fileList: [
          { name: "20261015_add_fts5.sql", size: "8.4 KB", path: "/Users/alex/Projects/nook/migrations/20261015_add_fts5.sql" }
        ],
        timeGroup: "yesterday",
        groupTitle: "Yesterday"
      },
      'demo-9': {
        title: "Color Capsule Example",
        source: "Figma",
        timeStr: "Oct 14 22:37",
        snippet: "#6366F1",
        metaLine: "#6366F1",
        timeGroup: "this_week",
        groupTitle: "This Week"
      },
      'demo-10': {
        title: "Rust Lock-Free Concurrent Queue Design",
        source: "Visual Studio Code",
        timeStr: "Oct 13 13:01",
        snippet: "pub struct LockFreeQueue...",
        metaLine: "Rust · 14 lines · 246 chars",
        timeGroup: "this_week",
        groupTitle: "This Week",
        badge: "Rust"
      },
      'demo-11': {
        title: "Team Weekly Meeting Invite Link",
        source: "Safari",
        timeStr: "Oct 12 09:30",
        snippet: "feishu.cn/j/948271842",
        metaLine: "Online meeting · 44 chars",
        timeGroup: "this_week",
        groupTitle: "This Week"
      },
      'demo-12': {
        title: "Apple Developer Certificate & notarize.sh",
        source: "Terminal",
        timeStr: "Oct 11 16:40",
        snippet: "xcrun notarytool submit...",
        metaLine: "Shell script · 6 lines · 168 chars",
        timeGroup: "this_week",
        groupTitle: "This Week",
        badge: "Shell"
      },
      'demo-13': {
        title: "AWS S3 Production Bucket Access Key",
        summary: "AKIA••••••••••••3M7Q",
        source: "Terminal",
        timeStr: "Oct 8 17:22",
        snippet: "AKIA...3M7Q",
        metaLine: "AWS Access Key · Encrypted Isolation",
        isoDate: "2026-10-08T17:22:00",
        timeGroup: "month-10",
        groupTitle: "Oct",
        badge: "Private"
      },
      'demo-14': {
        title: "NookClip-Architecture.pdf and 1 other file",
        source: "Finder",
        timeStr: "Oct 7 14:05",
        snippet: "NookClip-Architecture.pdf",
        metaLine: "2 files · Total 2.4 MB",
        fileList: [
          { name: "NookClip-Architecture.pdf", size: "2.1 MB", path: "/Users/alex/Documents/NookClip-Architecture.pdf" },
          { name: "Database-Schema.sql", size: "320 KB", path: "/Users/alex/Documents/Database-Schema.sql" }
        ],
        isoDate: "2026-10-07T14:05:00",
        timeGroup: "month-10",
        groupTitle: "Oct"
      },
      'demo-15': {
        title: "TailwindCSS 3.4 Palette Extension Config",
        source: "Visual Studio Code",
        timeStr: "Oct 5 11:30",
        snippet: "colors: { nook: ... }",
        metaLine: "JavaScript · 9 lines · 142 chars",
        isoDate: "2026-10-05T11:30:00",
        timeGroup: "month-10",
        groupTitle: "Oct",
        badge: "JS"
      },
      'demo-16': {
        title: "SQLite WAL & FTS5 Full-Text Benchmark Report",
        summary: "Under 50,000 clipboard history load test:\n• Single write latency: avg 0.32 ms\n• FTS5 prefix match latency: avg 0.78 ms\n• Resident memory growth: only +2.4 MB, perfectly lightweight!",
        source: "Notes",
        timeStr: "Sep 28 20:10",
        snippet: "Under 50,000 history load test...",
        metaLine: "5 lines · 128 chars",
        isoDate: "2026-09-28T20:10:00",
        timeGroup: "month-09",
        groupTitle: "Sep"
      },
      'demo-17': {
        title: "NookClip v0.1.0 Release Roadmap Memo",
        summary: "1. Align clipboard loop with macOS 14 native window\n2. Local AES-256 encryption & auto-masking\n3. Offline Vision OCR & QR code sync\n4. Deliver open-source landing page & interactive testbench",
        source: "Notes",
        timeStr: "Sep 22 15:45",
        snippet: "1. Align clipboard loop...",
        metaLine: "4 lines · 98 chars",
        isoDate: "2026-09-22T15:45:00",
        timeGroup: "month-09",
        groupTitle: "Sep"
      },
      'demo-18': {
        title: "PostgreSQL Read-Write Split Connection Pool",
        source: "Xcode",
        timeStr: "Sep 15 18:20",
        snippet: "let read_pool = Pool...",
        metaLine: "Rust · 6 lines · 158 chars",
        isoDate: "2026-09-15T18:20:00",
        timeGroup: "month-09",
        groupTitle: "Sep",
        badge: "Rust"
      },
      'demo-19': {
        title: "WeChat Open Platform AppSecret",
        summary: "wx94••••••••••••e8a2",
        source: "WeChat",
        timeStr: "Sep 8 10:05",
        snippet: "wx94...e8a2",
        metaLine: "WeChat AppSecret · Encrypted",
        isoDate: "2026-09-08T10:05:00",
        timeGroup: "month-09",
        groupTitle: "Sep",
        badge: "Private"
      }
    }
  };

  function getDemoItems(lang) {
    const normalized = normalizeLang(lang);
    const locMap = ITEM_I18N[normalized] || ITEM_I18N['zh-Hans'];
    return BASE_DEMO_ITEMS.map(base => {
      const item = JSON.parse(JSON.stringify(base));
      const loc = locMap[item.id];
      if (loc) {
        Object.assign(item, loc);
        if (loc.fileList) item.fileList = JSON.parse(JSON.stringify(loc.fileList));
      }
      return item;
    });
  }

  // =========================================================================
  // 2.5 时间分组（与客户端同规则的纯函数）
  // =========================================================================
  //
  // 客户端分档规则（Rust `timeline::bucket_of` / Swift `Timeline.group`）：
  //   · 自然日差 0       → 今天
  //   · 自然日差 1       → 昨天
  //   · 自然日差 2–7     → 本周（标签沿用「本周」，但判定不看周界，
  //                        所以它的覆盖范围恒为 7 天，不再随星期几在 0–6 天间浮动）
  //   · 更早且同年       → 月份归档桶（当月桶只装近档窗口之外的条目）
  //   · 更早且跨年       → 年份归档桶
  // 「上周」档已退役：它夹在按天与按月之间，且 `本月` 又包含 `上周`，语义嵌套。
  // 去掉后只剩两种粒度：7 天内按天、7 天外按月/年。
  const SPAN_JUSTIFIED_DAYS = 7;

  /** 某月天数（用于判断月份桶是否覆盖整月） */
  function daysInMonth(year, month) {
    return new Date(Date.UTC(year, month, 0)).getUTCDate();
  }

  /**
   * 时间戳（字符串或 Date）→ 分档描述。规则与客户端逐条对齐。
   * @returns {{id: string, kind: 'near'|'month'|'year', month?: number, year?: number,
   *            lastDay?: number, elapsed?: number}}
   */
  function bucketOf(date, now) {
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const target = new Date(date.getFullYear(), date.getMonth(), date.getDate());
    const elapsed = Math.round((target - today) / 86400000);

    if (elapsed >= 0) return { id: 'today', kind: 'near', elapsed };
    if (elapsed === -1) return { id: 'yesterday', kind: 'near', elapsed };
    if (elapsed >= -SPAN_JUSTIFIED_DAYS) return { id: 'this-week', kind: 'near', elapsed };

    const year = date.getFullYear();
    if (year !== now.getFullYear()) return { id: `year-${year}`, kind: 'year', year };

    const month = date.getMonth() + 1;
    // 当月桶的实际覆盖末日（客户端 month_bucket_last_day 同算法）：
    // 今天是 10/23、窗口 7 天 → 近档占掉 10/16–10/23，当月桶只装 10/1–10/15，
    // 标题必须写成「10月 1–15日」，否则「10月 · 15」会被读成「10 月一共只有 15 条」。
    // 历史月份是完整的，返回该月天数（标题不带范围）；月初时 cutoff 落到上月，返回 0（不产生桶）。
    const cutoff = new Date(today.getFullYear(), today.getMonth(), today.getDate() - (SPAN_JUSTIFIED_DAYS + 1));
    let lastDay = daysInMonth(year, month);
    if (cutoff.getFullYear() === year && cutoff.getMonth() + 1 === month) {
      lastDay = cutoff.getDate();
    }
    return { id: `month-${String(month).padStart(2, '0')}`, kind: 'month', month, year, lastDay };
  }

  /** 分组标题：近档用相对词，月档带覆盖范围，年档只写年份 */
  function groupTitleOf(bucket, lang) {
    const dict = UI_I18N[lang] || UI_I18N['zh-Hans'];
    const range = (name, lastDay) => {
      if (lastDay >= daysInMonth(bucket.year, bucket.month)) return name;
      if (lang === 'en') return lastDay === 1 ? `${name} 1` : `${name} 1–${lastDay}`;
      return lastDay === 1 ? `${name} 1日` : `${name} 1–${lastDay}日`;
    };
    if (bucket.kind === 'near') {
      return bucket.id === 'today' ? dict.today : bucket.id === 'yesterday' ? dict.yesterday : dict.this_week;
    }
    if (bucket.kind === 'year') {
      return lang === 'en' ? String(bucket.year) : `${bucket.year}年`;
    }
    const monthName = lang === 'en'
      ? new Date(2000, bucket.month - 1, 1).toLocaleString('en-US', { month: 'short' })
      : `${bucket.month}月`;
    return range(monthName, bucket.lastDay);
  }

  /**
   * 行尾时间：7 天窗口内用「周几 HH:MM」（今天/昨天则用相对词），
   * 窗口外切到「10月12日 09:05」——与客户端同一 7 天窗口，两处不再各自判断。
   */
  function rowTimeOf(date, now, lang) {
    const dict = UI_I18N[lang] || UI_I18N['zh-Hans'];
    const pad = (n) => String(n).padStart(2, '0');
    const hm = `${pad(date.getHours())}:${pad(date.getMinutes())}`;
    const elapsed = Math.round(
      (new Date(date.getFullYear(), date.getMonth(), date.getDate())
        - new Date(now.getFullYear(), now.getMonth(), now.getDate())) / 86400000
    );
    if (elapsed === 0) return `${dict.today} ${hm}`;
    if (elapsed === -1) return `${dict.yesterday} ${hm}`;
    if (elapsed >= -SPAN_JUSTIFIED_DAYS) {
      const weekday = date.toLocaleDateString(
        lang === 'en' ? 'en-US' : lang === 'zh-Hant' ? 'zh-TW' : 'zh-CN',
        { weekday: 'short' }
      );
      return `${weekday} ${hm}`;
    }
    if (lang === 'en') {
      const mon = date.toLocaleString('en-US', { month: 'short' });
      return `${mon} ${date.getDate()} ${hm}`;
    }
    return `${date.getMonth() + 1}月${date.getDate()}日 ${hm}`;
  }

  /**
   * 给一组记录挂上推导出的时间分组（id / 标题 / 行尾时间）。
   * 记录自带 `isoDate` 时以它为权威时间戳，否则退回按 `timeGroup` 兜底。
   */
  function applyTimeline(items, now, lang) {
    return items.map(item => {
      if (!item.isoDate) return item;
      const date = new Date(item.isoDate);
      if (Number.isNaN(date.getTime())) return item;
      const bucket = bucketOf(date, now);
      return Object.assign({}, item, {
        date,
        timeGroup: bucket.id,
        groupTitle: groupTitleOf(bucket, lang),
        timeStr: rowTimeOf(date, now, lang)
      });
    });
  }

  const INITIAL_DEMO_ITEMS = getDemoItems('zh-Hans');

  // =========================================================================
  // 3. 原型测试台核心类 (NookClipPrototype)
  // =========================================================================
  class NookClipPrototype {
    constructor(container, options = {}) {
      this.container = typeof container === 'string' ? document.querySelector(container) : container;
      if (!this.container) return;

      this.options = Object.assign({
        theme: 'auto',
        lang: 'zh-Hans',
        standalone: false,
        onThemeChange: null,
        onToast: null
      }, options);

      this.currentLang = normalizeLang(this.options.lang || (typeof document !== 'undefined' && document.documentElement.lang) || 'zh-Hans');

      // 初始化数据 (默认首项选中为快捷键速查卡，与截图 100% 对齐)
      // 演示数据的时间戳按「当前时刻」锚定，分档/标题/行尾时间统一推导，
      // 保证任意一天打开测试台都能看到「今天 / 昨天 / 本周 / 本月 / 历史月份」完整档位
      this.now = new Date();
      this.items = applyTimeline(getDemoItems(this.currentLang), this.now, this.currentLang);
      this.selectedId = this.items[0].id;
      this.selectedIds = new Set();
      this.isBatchMode = false;
      this.activeCategory = 0; // 全部（默认无筛选态）
      this.activeTag = null;   // 标签筛选项（与类型筛选可叠加）
      this.searchText = "";
      this.isFilterPanelOpen = false; // 搜索框展开的类型/标签筛选面板
      this.filterKeyword = "";        // 面板内标签搜索词（与主搜索词分离）
      this.isTimeMenuOpen = false;
      this.isHelpOpen = false;
      this.renamingId = null;
      this.sensitiveRevealed = {};
      this.sensitiveTimers = {};
      this.jsonSegments = {};
      this.isOcrScanning = false;
      this.showOcrRules = false;
      // 预览顶栏二维码按钮的激活态 (PreviewToolbar.swift: showQRCode)
      this.showQrCode = false;
      this.deletedStack = [];
      this.undoTimer = null;
      this.currentTheme = this.options.theme || 'auto';

      this.initDOM();
      this.bindEvents();
      this.render();
    }

    t(key, ...args) {
      const dict = UI_I18N[this.currentLang] || UI_I18N['zh-Hans'];
      const val = dict[key] !== undefined ? dict[key] : (UI_I18N['zh-Hans'][key] || key);
      if (typeof val === 'function') {
        return val(...args);
      }
      return val;
    }

    getCategories() {
      return CATEGORIES_DATA[this.currentLang] || CATEGORIES_DATA['zh-Hans'];
    }

    getCategoryName(id) {
      if (id === 0) return (ALL_CATEGORY_DATA[this.currentLang] || ALL_CATEGORY_DATA['zh-Hans']).name;
      const found = this.getCategories().find(c => c.id === id);
      return found ? found.name : '';
    }

    /** 8 个固定类型槽（顺序＝客户端网格槽序；空槽 count 为 0，位置不塌缩） */
    getTypeSlots() {
      return this.getCategories().map(cat => ({
        id: cat.id,
        name: cat.name,
        icon: cat.icon,
        tint: cat.tint,
        count: this.countByCategory(cat.id)
      }));
    }

    /** 某个类型槽的命中数（收藏看 isFavorite，其余看记录自身 category） */
    countByCategory(id) {
      if (id === 8) return this.items.filter(it => it.isFavorite).length;
      return this.items.filter(it => it.category === id).length;
    }

    /**
     * ⌘[ / ⌘] 的循环序：全部 + 有内容的类型槽。
     * 空槽（如回收站）不进循环——否则会切到空列表（与客户端 orderedCategoryIDs 一致）。
     */
    getCycleCategoryIds() {
      return [0].concat(this.getTypeSlots().filter(slot => slot.count > 0).map(slot => slot.id));
    }

    /** 标签筛选项及其命中数（只列出现过的标签，按记录数降序） */
    getTagSlots() {
      return TAGS_DATA
        .map(tag => ({
          id: tag.id,
          name: tag.name,
          count: this.items.filter(it => (it.tags || []).includes(tag.id)).length
        }))
        .filter(tag => tag.count > 0)
        .sort((a, b) => b.count - a.count);
    }

    getTagName(id) {
      const tag = TAGS_DATA.find(t => t.id === id);
      return tag ? tag.name : '';
    }

    /** 搜索框内嵌的筛选胶囊：当前生效的类型 / 标签各一枚（无筛选时为空） */
    getFilterChips() {
      const chips = [];
      if (this.activeCategory !== 0) {
        const cat = this.getCategories().find(c => c.id === this.activeCategory);
        if (cat) chips.push({ kind: 'category', id: cat.id, name: cat.name, icon: cat.icon });
      }
      if (this.activeTag) {
        chips.push({ kind: 'tag', id: this.activeTag, name: this.getTagName(this.activeTag) });
      }
      return chips;
    }

    /** 清空全部筛选条件（类型 + 标签），不动搜索词 */
    clearFilters() {
      this.activeCategory = 0;
      this.activeTag = null;
    }

    setLanguage(lang) {
      const newLang = normalizeLang(lang);
      if (this.currentLang === newLang) return;
      this.currentLang = newLang;

      // 时间分组标题与行尾时间由 isoDate + 语言重新推导（不再从文案表里搬字符串），
      // 这样分组规则永远只有一处实现，切语言不会出现「今天」与硬编码日期混排。
      this.items = applyTimeline(getDemoItems(newLang), this.now, newLang);

      this.updateStaticTexts();
      this.render();
      this.renderSearchChrome();
    }

    updateStaticTexts() {
      const win = this.container.querySelector('#nookWindow');
      if (win) win.setAttribute('aria-label', this.t('windowAria'));

      const searchClear = this.container.querySelector('#nookSearchClear');
      if (searchClear) searchClear.title = this.t('searchClear');

      const cycleBtn = this.container.querySelector('#nookGroupMenuTrigger');
      if (cycleBtn) cycleBtn.title = this.t('cycleTimeTitle');

      const undoBtn = this.container.querySelector('#nookUndoBtn');
      if (undoBtn) undoBtn.textContent = this.t('undoBtn');

      const batchBar = this.container.querySelector('#nookBatchBar');
      if (batchBar) {
        const escSpan = batchBar.querySelector('.nook-batch-bar-top span:last-child');
        if (escSpan) escSpan.textContent = this.t('batchEscHint');
        const mergeBtn = batchBar.querySelector('#nookBatchMergeBtn');
        if (mergeBtn) mergeBtn.innerHTML = `${this.t('batchMerge')} <span class="nook-kbd">↩</span>`;
        const delBtn = batchBar.querySelector('#nookBatchDeleteBtn');
        if (delBtn) delBtn.innerHTML = `${this.t('batchDelete')} <span class="nook-kbd">⌘⌫</span>`;
      }

      const hintsFooter = this.container.querySelector('#nookHintsFooter');
      if (hintsFooter) {
        const labels = hintsFooter.querySelectorAll('.nook-hint-label');
        if (labels.length >= 3) {
          labels[0].textContent = this.t('hintSelect');
          labels[1].textContent = this.t('hintPaste');
          labels[2].textContent = this.t('hintCategory');
        }
        const helpBtn = hintsFooter.querySelector('#nookHelpBtn');
        if (helpBtn) helpBtn.title = this.t('helpTitle');

        const popover = hintsFooter.querySelector('#nookHelpPopover');
        if (popover) {
          const rows = this.t('helpRows');
          popover.innerHTML = rows.map(r => `
            <div class="nook-help-row"><span class="nook-help-desc">${r.desc}</span><span>${r.keys.map(k => `<span class="nook-kbd">${k}</span>`).join(' ')}</span></div>
          `).join('');
        }
      }

      const favBtn = this.container.querySelector('#nookFavoriteBtn');
      if (favBtn) favBtn.title = this.t('starBtnTitle');

      const delBtn = this.container.querySelector('#nookDeleteBtn');
      if (delBtn) delBtn.title = this.t('deleteBtnTitle');
      // 预览顶栏（来源/类型动作/标签）随语言切换重绘
      this.renderPreview();
    }

    initDOM() {
      this.container.innerHTML = `
        <div class="nook-sandbox-wrapper ${this.options.standalone ? 'is-standalone' : ''}">
          <!-- 悬浮窗口主体 -->
          <div class="nook-window nook-theme-${this.getEffectiveTheme()}" id="nookWindow" tabindex="0" role="region" aria-label="${this.t('windowAria')}">
            <!-- 左侧列表列 -->
            <div class="nook-list-col">
              <!-- 顶部搜索框 + 展开筛选面板（Spotlight 式）：
                   分类与标签已统一收进这里，旧版常驻分类条与「第 4 槽 ▾」下拉已移除。
                   展开时搜索框与面板共用同一张不透明纸面，避免两块面互相投影割裂。 -->
              <div class="nook-filter-shell" id="nookFilterShell">
                <div class="nook-search-bar" id="nookSearchBar">
                  <span class="nook-search-icon">${ICONS.search}</span>
                  <span class="nook-search-chips" id="nookSearchChips"></span>
                  <input type="text" class="nook-search-input" id="nookSearchInput" placeholder="${this.t('searchPlaceholder')}" autocomplete="off" spellcheck="false">
                  <button type="button" class="nook-search-clear" id="nookSearchClear" style="display:none;" title="${this.t('searchClear')}">✕</button>
                  <span class="nook-search-badge" id="nookSearchBadge">⌘F</span>
                </div>
                <div class="nook-filter-panel" id="nookFilterPanel" style="display:none;"></div>
              </div>

              <!-- 拼音应用搜索直达 -->
              <div class="nook-app-launcher-section" id="nookAppLauncher" style="display:none;"></div>

              <!-- 吸顶时间组头 (GroupHeaderView)：「今天 · 6」整块是分组跳转菜单入口，
                   常态无图标，悬停才淡入 ⌄ 并提亮；底缘 0.5pt 分割线 -->
              <div class="nook-group-header" id="nookGroupHeader">
                <div class="nook-group-header-title" id="nookGroupMenuTrigger" role="button" tabindex="0" title="${this.t('cycleTimeTitle')}">
                  <span id="nookGroupTitle">${this.t('today')}</span>
                  <span>·</span>
                  <span class="nook-group-header-count" id="nookGroupCount">6</span>
                  <button type="button" class="nook-group-header-btn" id="nookGroupCycleBtn" tabindex="-1" aria-hidden="true">
                    ${ICONS.chevronUpDown}
                  </button>
                </div>
              </div>

              <!-- 时间线分组下拉选择菜单 -->
              <div class="nook-time-dropdown" id="nookTimeDropdown" style="display:none;"></div>

              <!-- 10 条真实历史数据列表 -->
              <div class="nook-list-scroll" id="nookListScroll">
                <div id="nookRowsContainer"></div>
              </div>

              <!-- 底部撤销 Toast (条件浮现) -->
              <div class="nook-undo-toast" id="nookUndoToast" style="display:none;">
                <span class="nook-undo-toast-text">${this.t('undoToast', 1)}</span>
                <button type="button" class="nook-undo-toast-btn" id="nookUndoBtn">${this.t('undoBtn')}</button>
                <div class="nook-undo-progress" id="nookUndoProgress"></div>
              </div>

              <!-- 底部批量模式工具栏 -->
              <div class="nook-batch-bar" id="nookBatchBar" style="display:none;">
                <div class="nook-batch-bar-top">
                  <span id="nookBatchCount">${this.t('batchSelected', 0)}</span>
                  <span>${this.t('batchEscHint')}</span>
                </div>
                <div class="nook-batch-bar-bottom">
                  <button type="button" class="nook-btn-batch nook-btn-batch-primary" id="nookBatchMergeBtn">${this.t('batchMerge')} <span class="nook-kbd">↩</span></button>
                  <button type="button" class="nook-btn-batch nook-btn-batch-danger" id="nookBatchDeleteBtn">${this.t('batchDelete')} <span class="nook-kbd">⌘⌫</span></button>
                </div>
              </div>

              <!-- 底部常驻提示栏 (对齐原生 GroupAndFooter.swift: 居中纯排印展示 + 右侧 ? 按钮) -->
              <div class="nook-hints-footer" id="nookHintsFooter">
                <div class="nook-hints-group">
                  <span class="nook-hint-item"><span class="nook-hint-kbd">↑ ↓</span> <span class="nook-hint-label">${this.t('hintSelect')}</span></span>
                  <span class="nook-hint-item"><span class="nook-hint-kbd">↩</span> <span class="nook-hint-label">${this.t('hintPaste')}</span></span>
                  <span class="nook-hint-item"><span class="nook-hint-kbd">⌘ [ ⌘ ]</span> <span class="nook-hint-label">${this.t('hintCategory')}</span></span>
                </div>
                <button type="button" class="nook-help-btn" id="nookHelpBtn" title="${this.t('helpTitle')}">
                  ${ICONS.help}
                </button>
                <div class="nook-help-popover" id="nookHelpPopover" style="display:none;">
                  ${this.t('helpRows').map(r => `
                    <div class="nook-help-row"><span class="nook-help-desc">${r.desc}</span><span>${r.keys.map(k => `<span class="nook-kbd">${k}</span>`).join(' ')}</span></div>
                  `).join('')}
                </div>
              </div>
            </div>

            <!-- 右侧详细预览区 -->
            <div class="nook-preview-pane" id="nookPreviewPane">
              <!-- 顶部工具栏 (对齐 PreviewToolbar.swift: [App 图标+名称][类型动作] → Spacer → [复制 N 次][标签][#][★ | 🗑]) -->
              <div class="nook-preview-toolbar">
                <div class="nook-preview-meta-leading" id="nookPreviewMeta"></div>
                <div class="nook-preview-lead-actions" id="nookPreviewLeadActions"></div>
                <div class="nook-preview-actions">
                  <span class="nook-preview-copy-count" id="nookPreviewCopyCount"></span>
                  <div class="nook-preview-tags" id="nookPreviewTags"></div>
                  <div class="nook-preview-end-actions">
                    <button type="button" class="nook-toolbar-btn btn-star" id="nookFavoriteBtn" title="${this.t('starBtnTitle')}" aria-label="${this.t('starBtnTitle')}">
                      <span id="nookStarIcon">${ICONS.star}</span>
                    </button>
                    <button type="button" class="nook-toolbar-btn btn-delete" id="nookDeleteBtn" title="${this.t('deleteBtnTitle')}" aria-label="${this.t('deleteBtnTitle')}">
                      <span>${ICONS.trash}</span>
                    </button>
                  </div>
                </div>
              </div>

              <!-- 预览正文内容区 (对齐截图大标题与排版) -->
              <div class="nook-preview-body" id="nookPreviewBody"></div>
            </div>

            <!-- 粘贴/拷贝提示 HUD -->
            <div class="nook-paste-hud" id="nookPasteHud">
              <span class="nook-hud-icon">${ICONS.check}</span>
              <span id="nookPasteHudText">${this.t('pasteHudDefault')}</span>
            </div>
          </div>
        </div>
      `;
    }

    getEffectiveTheme() {
      if (this.currentTheme === 'light') return 'light';
      if (this.currentTheme === 'dark') return 'dark';
      return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
    }

    getFilteredItems() {
      let result = this.items;
      // 类型筛选与标签筛选是两套正交条件，可同时生效（与客户端搜索框内嵌的两枚胶囊一致）
      if (this.activeCategory === 8) {
        result = result.filter(item => item.isFavorite);
      } else if (this.activeCategory !== 0) {
        result = result.filter(item => item.category === this.activeCategory);
      }
      if (this.activeTag) {
        result = result.filter(item => (item.tags || []).includes(this.activeTag));
      }
      const q = this.searchText.trim().toLowerCase();
      if (q) {
        result = result.filter(item => {
          const title = (item.title || "").toLowerCase();
          const summary = (item.summary || "").toLowerCase();
          const source = (item.source || "").toLowerCase();
          return title.includes(q) || summary.includes(q) || source.includes(q);
        });
      }
      return result;
    }

    getSelectedItem() {
      const list = this.getFilteredItems();
      return list.find(item => item.id === this.selectedId) || list[0] || null;
    }

    render() {
      this.updateThemeVisuals();
      this.renderCategoryBar();
      this.renderRows();
      this.renderPreview();
      this.renderAppLauncher();
      this.renderBatchState();
      this.renderTimeRail();
    }

    updateThemeVisuals() {
      const win = this.container.querySelector('#nookWindow');
      if (win) {
        const theme = this.getEffectiveTheme();
        win.classList.toggle('nook-theme-light', theme === 'light');
        win.classList.toggle('nook-theme-dark', theme === 'dark');
      }
    }

    // ── 筛选面板（搜索框展开 · 按类型 4×2 固定网格 + 按标签流式胶囊）────────────

    /** 面板是否需要展示：显式展开，或「搜索框聚焦 / 已有关键词 / 已有筛选条件」。 */
    shouldShowFilterPanel() {
      return this.isFilterPanelOpen || this.hasFilterChips() || !!this.filterKeyword;
    }

    hasFilterChips() {
      return this.activeCategory !== 0 || !!this.activeTag;
    }

    /** 搜索框最多留 2 枚内嵌胶囊；多余的收进「+N」角标，点击展开面板查看 */
    getVisibleChips() {
      return this.getFilterChips().slice(0, 2);
    }

    renderSearchChrome() {
      const chipsEl = this.container.querySelector('#nookSearchChips');
      const clearEl = this.container.querySelector('#nookSearchClear');
      const badgeEl = this.container.querySelector('#nookSearchBadge');
      const input = this.container.querySelector('#nookSearchInput');
      const bar = this.container.querySelector('#nookSearchBar');
      if (!chipsEl) return;

      const chips = this.getFilterChips();
      const visible = this.getVisibleChips();
      const tintOf = (kind) => kind === 'category'
        ? 'var(--nook-filter-chip-symbol)'
        : 'var(--nook-text-secondary)';

      chipsEl.innerHTML = visible.map(chip => `
        <span class="nook-embed-chip" data-chip-kind="${chip.kind}" data-chip-id="${chip.id}" title="${this.t('filterRemoveCondition')}">
          ${chip.kind === 'category'
            ? `<span class="nook-embed-chip-icon" style="color:${tintOf('category')};">${ICONS[chip.icon] || ICONS.text}</span>`
            : `<span class="nook-embed-chip-hash">#</span>`}
          <span class="nook-embed-chip-name">${chip.name}</span>
          <span class="nook-embed-chip-x">${ICONS.close}</span>
        </span>
      `).join('') + (chips.length > visible.length
        ? `<span class="nook-embed-chip is-overflow">+${chips.length - visible.length}</span>`
        : '');

      // 已有筛选条件时让出 ⌘F 角标；有关键词时改出清空按钮
      if (clearEl) clearEl.style.display = this.searchText ? 'flex' : 'none';
      if (badgeEl) badgeEl.style.display = (this.searchText || chips.length) ? 'none' : 'inline';
      if (input) {
        input.placeholder = chips.length ? this.t('filterConditionHint') : this.t('searchPlaceholder');
        input.classList.toggle('has-chips', chips.length > 0);
      }
      if (bar) bar.classList.toggle('has-chips', chips.length > 0);

      const panel = this.container.querySelector('#nookFilterPanel');
      const shell = this.container.querySelector('#nookFilterShell');
      const open = this.shouldShowFilterPanel();
      if (panel) panel.style.display = open ? 'flex' : 'none';
      if (shell) shell.classList.toggle('is-open', open);
    }

    renderFilterPanel() {
      const panel = this.container.querySelector('#nookFilterPanel');
      if (!panel) return;

      const slots = this.getTypeSlots();
      const tags = this.getTagSlots();
      const kw = (this.filterKeyword || '').trim().toLowerCase();
      const visibleTags = kw ? tags.filter(tag => tag.name.toLowerCase().includes(kw)) : tags;

      const typesHtml = slots.map(slot => {
        const isActive = this.activeCategory === slot.id;
        const isEmpty = slot.count === 0;
        const cls = ['nook-type-tile'];
        if (isActive) cls.push('is-active');
        if (isEmpty) cls.push('is-empty');
        // 实心色块取色由 --nook-tile-tint 注入（NookClip.SidebarCategory.tintColor）
        return `
          <button type="button" class="${cls.join(' ')}" data-cat-id="${slot.id}"
                  style="--nook-tile-tint: var(--nook-tint-${slot.tint})"
                  aria-pressed="${isActive}" ${isEmpty ? 'aria-disabled="true"' : ''}
                  title="${slot.name} (${slot.count})">
            <span class="nook-type-tile-icon">${ICONS[slot.icon] || ICONS.text}</span>
            <span class="nook-type-tile-name">${slot.name}</span>
          </button>
        `;
      }).join('');

      const tagsHtml = visibleTags.length
        ? visibleTags.map(tag => {
            const isActive = this.activeTag === tag.id;
            return `
              <button type="button" class="nook-tag-pill ${isActive ? 'is-active' : ''}" data-tag-id="${tag.id}"
                      aria-pressed="${isActive}">
                <span class="nook-tag-pill-hash">#</span>
                <span>${tag.name}</span>
                <span class="nook-tag-pill-count">${tag.count}</span>
              </button>
            `;
          }).join('')
        : `<span class="nook-filter-empty">${kw ? this.t('filterNoTagMatch') : this.t('filterEmptyTag')}</span>`;

      // 结构与 CategoryFilterPanel 一致：按类型 → （有标签时）0.5pt 分割线 + 按标签。
      // 无标签时整个下半区隐藏、卡片自动变薄。
      const hasTags = visibleTags.length > 0;
      panel.innerHTML = `
        <div class="nook-filter-section">
          <div class="nook-filter-section-header">
            <span>${this.t('filterByType')}</span>
            ${this.activeCategory !== 0 || this.activeTag
              ? `<button type="button" class="nook-filter-clear" id="nookFilterClearBtn">${this.t('filterRemoveCondition')}</button>`
              : ''}
          </div>
          <div class="nook-type-grid">${typesHtml}</div>
        </div>
        ${hasTags ? `
        <div class="nook-filter-divider"></div>
        <div class="nook-filter-section">
          <div class="nook-filter-section-header is-tagline">
            <span>${this.t('filterByTag')}</span>
          </div>
          <div class="nook-tag-flow">${tagsHtml}</div>
        </div>` : ''}
      `;
    }

    /** 兼容旧调用点：分类条已并入筛选面板 */
    renderCategoryBar() {
      this.renderSearchChrome();
      this.renderFilterPanel();
    }

    renderRows() {
      const container = this.container.querySelector('#nookRowsContainer');
      const list = this.getFilteredItems();
      const countEl = this.container.querySelector('#nookGroupCount');
      const titleEl = this.container.querySelector('#nookGroupTitle');

      const selectedItem = this.getSelectedItem();
      const currentGroup = selectedItem ? (selectedItem.groupTitle || this.t('today')) : this.t('today');
      if (titleEl) titleEl.textContent = currentGroup;
      if (countEl) countEl.textContent = list.filter(it => (it.groupTitle || this.t('today')) === currentGroup).length || list.length;
      if (!container) return;

      if (list.length === 0) {
        container.innerHTML = `
          <div style="padding: 48px 20px; text-align: center; color: var(--nook-text-tertiary); font-size: 13px;">
            <div style="width: 32px; height: 32px; margin: 0 auto 10px; opacity: 0.5;">${ICONS.search}</div>
            ${this.t('noMatch')}
          </div>
        `;
        return;
      }

      if (!list.some(it => it.id === this.selectedId) && !this.renamingId) {
        this.selectedId = list[0].id;
      }

      let html = '';
      const q = this.searchText.trim();
      let lastGroupTitle = null;

      list.forEach((item, index) => {
        // 当不是搜索态时，显示跨时间分组的吸顶分割头
        if (!q && item.groupTitle && item.groupTitle !== lastGroupTitle) {
          lastGroupTitle = item.groupTitle;
          const groupCount = list.filter(it => it.groupTitle === item.groupTitle).length;
          if (index !== 0) {
            html += `
              <div class="nook-subgroup-header" data-time-group="${item.timeGroup}">
                <div class="nook-group-header-title">
                  <span>${item.groupTitle}</span> · <span class="nook-group-header-count">${groupCount}</span>
                </div>
              </div>
            `;
          }
        }

        const isSelected = item.id === this.selectedId;
        const isChecked = this.selectedIds.has(item.id);
        const appIcon = APP_ICONS[item.sourceApp] || APP_ICONS.nook;
        let tileContent = '';
        if (isSelected) {
          if (item.kind === 'color') {
            tileContent = `<div class="nook-row-tile-swatch" style="background:${item.colorHex};"></div>`;
          } else {
            tileContent = `<span class="nook-row-tile-icon" style="color:#FFF;">${ICONS[item.kind] || ICONS.text}</span>`;
          }
        } else {
          // 常态瓦片
          if (item.kind === 'color') {
            tileContent = `<div class="nook-row-tile-swatch" style="background:${item.colorHex};"></div>`;
          } else if (item.kind === 'image') {
            tileContent = `
              <svg viewBox="0 0 32 32" width="32" height="32" class="nook-thumbnail-svg">
                <rect width="32" height="32" rx="6" fill="#1E293B"/>
                <rect x="3" y="3" width="26" height="26" rx="4" fill="#0F172A" stroke="#3B82F6" stroke-width="1"/>
                <circle cx="7" cy="7" r="1.5" fill="#EF4444"/>
                <circle cx="11" cy="7" r="1.5" fill="#F59E0B"/>
                <circle cx="15" cy="7" r="1.5" fill="#10B981"/>
                <rect x="7" y="13" width="18" height="2" rx="1" fill="#93C5FD"/>
                <rect x="7" y="18" width="14" height="2" rx="1" fill="#64748B"/>
              </svg>
            `;
          } else if (item.kind === 'sensitive') {
            tileContent = `<span class="nook-row-tile-icon" style="color:var(--nook-color-sensitive);">${ICONS.sensitive}</span>`;
          } else if (item.kind === 'json') {
            tileContent = `<span class="nook-row-tile-icon" style="color:#FFF;">${ICONS.code}</span>`;
          } else if (item.kind === 'url') {
            tileContent = `<span class="nook-row-tile-icon" style="color:var(--nook-text-secondary);">${ICONS.link}</span>`;
          } else {
            tileContent = `<span class="nook-row-tile-icon" style="color:var(--nook-text-secondary);">${ICONS.text}</span>`;
          }
        }

        html += `
          <div class="nook-row ${isSelected ? 'is-selected' : ''} ${isChecked ? 'is-checked' : ''}" data-id="${item.id}">
            ${this.isBatchMode ? `
              <div class="nook-row-checkbox">${isChecked ? ICONS.check : ''}</div>
            ` : ''}

            <!-- 32x32 瓦片 -->
            <div class="nook-row-tile ${item.kind === 'sensitive' ? 'tile-sensitive' : ''}">
              ${tileContent}
            </div>

            <!-- 文字区域 -->
            <div class="nook-row-content">
              <div class="nook-row-title-line">
                ${this.renamingId === item.id ? `
                  <input type="text" class="nook-row-title-input" id="nookRenameInput" value="${this.escapeHTML(item.title)}">
                ` : `
                  <span class="nook-row-title ${item.kind === 'sensitive' && !isSelected ? 'is-sensitive-title' : ''}">${this.highlightText(item.title, q)}</span>
                `}
                ${item.badge ? `<span class="nook-badge ${item.badge === '私密' || item.badge === 'Private' ? 'badge-orange' : (item.badge === 'JSON' ? 'badge-blue' : 'badge-grey')}">${item.badge}</span>` : ''}
                ${item.isFavorite ? `<span class="nook-row-star ${isSelected ? 'star-white' : ''}">${ICONS.star}</span>` : ''}
              </div>
              <div class="nook-row-sub-line">
                <!-- 副行结构对齐 RowAtoms：类型徽标 → 上下文细节 → 标签 → 右对齐时间戳。
                     来源 App 不再以文字出现在副行，只作为瓦片右下角的 15pt 角标（已在 tile 内绘制）。 -->
                <span class="nook-row-summary">${(item.snippetIcon || '')}${this.highlightText(item.snippet, q)}</span>
                ${(item.tags || []).slice(0, 2).map(tagId => `<span class="nook-row-tag"><span class="nook-row-tag-hash">#</span>${this.escapeHTML(this.getTagName(tagId))}</span>`).join('')}
                <span class="nook-row-meta"${item.date ? ` title="${this.t('rowTimeToggleHint')}"` : ''}>${item.timeStr}</span>
              </div>
            </div>
          </div>
        `;
      });

      container.innerHTML = html;

      if (this.renamingId) {
        const input = container.querySelector('#nookRenameInput');
        if (input) {
          input.focus();
          input.select();
        }
      }
    }

    renderPreview() {
      const item = this.getSelectedItem();
      const meta = this.container.querySelector('#nookPreviewMeta');
      const leadActions = this.container.querySelector('#nookPreviewLeadActions');
      const copyCountEl = this.container.querySelector('#nookPreviewCopyCount');
      const tagsEl = this.container.querySelector('#nookPreviewTags');
      const body = this.container.querySelector('#nookPreviewBody');
      const favBtn = this.container.querySelector('#nookFavoriteBtn');
      const starIcon = this.container.querySelector('#nookStarIcon');

      if (!item) return;

      const appIcon = APP_ICONS[item.sourceApp] || APP_ICONS.nook;
      // 顶栏左侧只保留 sourceLabel：16×16 App 徽标 + 应用名（时间/复制次数已并入顶栏右侧 pill）
      if (meta) {
        meta.innerHTML = `
          <span class="nook-preview-app-icon">${appIcon}</span>
          <span class="nook-preview-source-name">${this.escapeHTML(item.source)}</span>
        `;
      }

      if (leadActions) leadActions.innerHTML = this.renderToolbarLeadActions(item);

      if (copyCountEl) {
        const cc = item.copyCount || 1;
        copyCountEl.textContent = cc > 1 ? this.t('copyCountShort', cc) : '';
        copyCountEl.hidden = cc <= 1;
      }

      if (tagsEl) tagsEl.innerHTML = this.renderToolbarTagChips(item);

      if (favBtn && starIcon) {
        const favTitle = item.isFavorite ? this.t('unstarBtnTitle') : this.t('starBtnTitle');
        favBtn.classList.toggle('is-favorite', item.isFavorite);
        favBtn.title = favTitle;
        favBtn.setAttribute('aria-label', favTitle);
        starIcon.innerHTML = item.isFavorite ? ICONS.star : ICONS.starOutline;
      }

      const delBtn = this.container.querySelector('#nookDeleteBtn');
      if (delBtn) {
        delBtn.title = this.t('deleteBtnTitle');
        delBtn.setAttribute('aria-label', this.t('deleteBtnTitle'));
      }

      if (!body) return;
      const q = this.searchText.trim();
      let contentHtml = '';

      // 对齐原生 PreviewPane 规范：标题始终展示（敏感条目带锁标记）
      contentHtml += `<h1 class="nook-preview-title ${item.isSensitive ? 'is-sensitive-title' : ''}">${item.isSensitive ? `<span class="nook-title-lock">${ICONS.sensitive}</span> ` : ''}${this.highlightText(item.title, q)}</h1>`;

      // 根据当前条目渲染对应详情内容 (Item 1 渲染截图中的快捷键速查清单)
      if (item.id === 'demo-1') {
        const sc = this.t('shortcutCard');
        contentHtml += `
          <div class="nook-preview-prose">
            <p class="nook-prose-lead">${sc.lead}</p>
            <div class="nook-shortcuts-grid">
              ${sc.rows.map(r => `<div class="${r.pair ? 'nook-sc-row-pair' : 'nook-sc-row-full'}">${r.spans ? r.spans.map(s => `<span>${s}</span>`).join('') : r.text}</div>`).join('')}
            </div>
          </div>
        `;
      } else if (item.kind === 'sensitive') {
        const isRevealed = !!this.sensitiveRevealed[item.id];
        const sc = this.t('sensitiveCard');
        contentHtml += `
          <div class="nook-sensitive-card">
            <span class="nook-sensitive-shield-icon">${ICONS.sensitive}</span>
            <div class="nook-sensitive-card-title">${sc.title}</div>
            ${isRevealed ? `
              <div class="nook-sensitive-revealed-text">${this.escapeHTML(item.plainText)}</div>
            ` : `
              <div class="nook-sensitive-masked-text">${this.escapeHTML(item.summary)}</div>
            `}
            <button type="button" class="nook-sensitive-toggle-btn ${isRevealed ? 'is-revealed' : ''}" id="nookSensitiveToggleBtn">
              ${isRevealed ? `${ICONS.eyeSlash} ${sc.maskBtn}` : `${ICONS.eye} ${sc.revealBtn}`}
            </button>
            <div class="nook-sensitive-hint">${sc.hint}</div>
          </div>
        `;
      } else if (item.kind === 'json' || item.kind === 'code') {
        const seg = this.jsonSegments[item.id] || 0;
        let codeText = item.summary;
        if (item.kind === 'json') {
          try {
            const parsed = JSON.parse(item.summary);
            if (seg === 0) codeText = JSON.stringify(parsed, null, 2);
            else if (seg === 1) codeText = JSON.stringify(parsed);
          } catch(e) {}
        }
        const ct = this.t('codeTabs');
        contentHtml += `
          <div>
            <div class="nook-code-card-header">
              <div class="nook-code-tabs">
                <button type="button" class="nook-code-tab ${seg === 0 ? 'is-active' : ''}" data-seg="0">${ct.prettify}</button>
                <button type="button" class="nook-code-tab ${seg === 1 ? 'is-active' : ''}" data-seg="1">${ct.minify}</button>
                <button type="button" class="nook-code-tab ${seg === 2 ? 'is-active' : ''}" data-seg="2">${ct.raw}</button>
              </div>
              <button type="button" class="nook-btn-tool" id="nookCopyCodeBtn"><span>${ICONS.copy}</span> ${ct.copyCode}</button>
            </div>
            <div class="nook-code-block">${this.formatCodeLines(codeText)}</div>
          </div>
        `;
      } else if (item.kind === 'image') {
        const oc = this.t('ocrCard');
        contentHtml += `
          <div class="nook-image-section">
            <div class="nook-image-card">
              <svg class="nook-image-preview" viewBox="0 0 640 320" style="width:100%;height:auto;display:block;">
                <rect width="640" height="320" fill="#0A0F1D"/>
                <rect x="24" y="24" width="592" height="272" rx="16" fill="#141E33" stroke="#2563EB" stroke-width="2" stroke-opacity="0.5"/>
                <text x="52" y="92" fill="#FFFFFF" font-family="-apple-system, 'SF Pro Display', sans-serif" font-size="28" font-weight="700">NookClip · Apple Vision OCR</text>
                <text x="52" y="142" fill="#93C5FD" font-family="-apple-system, 'SF Pro Text', sans-serif" font-size="18" font-weight="500">${oc.svgSub}</text>
                <text x="52" y="200" fill="#CBD5E1" font-family="'SF Mono', Menlo, monospace" font-size="14">${oc.svgHint}</text>
                <text x="52" y="244" fill="#64748B" font-family="'SF Mono', Menlo, monospace" font-size="14">100% On-Device · Zero Cloud Upload · Instant FTS5</text>
              </svg>
              <div class="nook-image-scan-laser ${this.isOcrScanning ? 'is-scanning' : ''}" id="nookLaserScan"></div>
              <button type="button" class="nook-livetext-btn" id="nookTriggerOcrBtn" title="${oc.recognizeBtn}">
                ${ICONS.ocr}
              </button>
            </div>
            <div class="nook-image-meta-line">
              <span>640 × 320</span>
              <span style="opacity:0.35;">·</span>
              <span>PNG · 42 KB</span>
              <span style="opacity:0.35;">·</span>
              <span>${oc.offlineOcr}</span>
            </div>
            <div class="nook-ocr-result-card">
              <div class="nook-ocr-result-header">
                <div class="nook-ocr-title-group">
                  <span class="nook-ocr-icon-symbol">${ICONS.ocr}</span>
                  <span class="nook-ocr-title-text">${oc.title}</span>
                  <button type="button" class="nook-ocr-rules-toggle" id="nookOcrRulesToggle" title="${oc.rules}">
                    <span style="opacity:0.8;">${ICONS.info}</span> <span>${this.showOcrRules ? oc.collapse : oc.rules}</span> <span id="nookRulesChevron">${this.showOcrRules ? '▴' : '▾'}</span>
                  </button>
                </div>
                ${this.isOcrScanning ? `
                  <span class="nook-ocr-scanning-badge">${oc.scanningBadge}</span>
                ` : `
                  <span class="nook-pill-badge">${oc.offlineBadge}</span>
                `}
              </div>
              <div class="nook-ocr-rules-banner" id="nookOcrRulesBanner" style="display:${this.showOcrRules ? 'flex' : 'none'};">
                <div class="nook-ocr-rule-line">${oc.ruleFormats}</div>
                <div class="nook-ocr-rule-line">${oc.ruleLanguages}</div>
                <div class="nook-ocr-rule-line">${oc.ruleLimits}</div>
              </div>
              <div class="nook-ocr-content-area">
                ${this.isOcrScanning ? `
                  <div class="nook-ocr-scanning-text">
                    <span class="nook-spinner"></span>
                    <span>${oc.scanningText}</span>
                  </div>
                ` : (item.ocrText ? `
                  <div class="nook-ocr-text">${this.escapeHTML(item.ocrText).replace(/\n/g, '<br>')}</div>
                  <div style="margin-top:12px;">
                    <button type="button" class="nook-ocr-copy-btn" id="nookCopyOcrBtn">
                      ${ICONS.copy} <span id="nookOcrCopyText">${oc.copyBtn}</span>
                    </button>
                  </div>
                ` : `
                  <div class="nook-ocr-not-scanned-box">
                    <div class="nook-ocr-not-scanned-text">${oc.notScanned}</div>
                    <button type="button" class="nook-btn-recognize" id="nookTriggerOcrBtn">
                      ${ICONS.ocr} ${oc.recognizeBtn}
                    </button>
                    <div class="nook-ocr-footer-hint">${oc.footerHint}</div>
                  </div>
                `)}
              </div>
            </div>
          </div>
        `;
      } else if (item.kind === 'color') {
        const cc = this.t('colorCard');
        contentHtml += `
          <div class="nook-color-card">
            <div class="nook-color-large-swatch" style="background:${item.colorHex};"></div>
            <div class="nook-color-values-box">
              <button type="button" class="nook-color-row" id="nookCopyHexRow" title="${cc.copyHex}">
                <span class="nook-color-label">HEX</span>
                <span class="nook-color-val">${item.colorHex}</span>
                <span class="nook-color-feedback" id="nookHexFeedback" style="display:none;">${cc.copied}</span>
                <span class="nook-color-icon-box">${ICONS.copy}</span>
              </button>
              <button type="button" class="nook-color-row" id="nookCopyRgbRow" title="${cc.copyRgb}">
                <span class="nook-color-label">RGB</span>
                <span class="nook-color-val">${item.rgbValue}</span>
                <span class="nook-color-feedback" id="nookRgbFeedback" style="display:none;">${cc.copied}</span>
                <span class="nook-color-icon-box">${ICONS.copy}</span>
              </button>
            </div>
            <div class="nook-color-hint">${cc.hint}</div>
          </div>
        `;
      } else if (item.kind === 'file') {
        const fc = this.t('fileCard');
        const files = item.fileList || [
          { name: item.summary.split('/').pop(), size: (item.metaLine ? item.metaLine.split('·')[1]?.trim() : '8.4 KB') || '8.4 KB', path: item.summary }
        ];
        const countHeader = files.length > 1
          ? fc.multiHeader(files.length, item.metaLine ? (item.metaLine.split('·')[2]?.trim() || '2.4 MB') : '2.4 MB')
          : `${files[0].size}`;
        contentHtml += `
          <div class="nook-file-section">
            <div class="nook-file-meta-header">${countHeader}</div>
            <div class="nook-file-card">
              ${files.map((f, idx) => `
                ${idx > 0 ? `<div class="nook-file-divider"></div>` : ''}
                <div class="nook-file-row">
                  <div class="nook-file-row-main">
                    <span class="nook-file-icon-box">
                      ${this.getFileIconSVG(f.name)}
                    </span>
                    <span class="nook-file-name">${this.escapeHTML(f.name)}</span>
                    <span class="nook-file-size">${f.size}</span>
                    <button type="button" class="nook-file-copy-btn" data-path="${this.escapeHTML(f.path)}" title="${fc.copyPath}">
                      ${ICONS.copy}
                    </button>
                  </div>
                  <div class="nook-file-path">${this.escapeHTML(f.path)}</div>
                </div>
              `).join('')}
            </div>
          </div>
        `;
      } else if (item.kind === 'url') {
        const uc = this.t('urlCard');
        const qrSvg = MiniQRCode.toSVG(item.summary, 120);
        contentHtml += `
          <div style="display:flex;flex-direction:column;gap:14px;">
            <div class="nook-url-card">
              <div class="nook-url-host-row">
                <div class="nook-url-host"><span style="color:var(--nook-tint-url);">${ICONS.link}</span> <span>github.com</span></div>
                <button type="button" class="nook-btn-tool" id="nookCopyUrlBtn"><span>${ICONS.copy}</span> ${uc.copy}</button>
              </div>
              <div class="nook-url-text">${this.escapeHTML(item.summary)}</div>
            </div>
            <div class="nook-qrcode-card">
              <div class="nook-qrcode-img-box">${qrSvg}</div>
            </div>
          </div>
        `;
      } else {
        const paragraphs = item.summary.split('\n\n');
        contentHtml += `
          <div class="nook-text-section">
            <div class="nook-text-body">
              ${paragraphs.map(p => `
                <p class="nook-text-paragraph">${this.formatTextBody(p, q)}</p>
              `).join('')}
            </div>
          </div>
        `;
      }

      body.innerHTML = contentHtml;
    }

    renderAppLauncher() {
      const launcher = this.container.querySelector('#nookAppLauncher');
      if (!launcher) return;
      const q = this.searchText.trim().toLowerCase();
      if (!q) { launcher.style.display = 'none'; return; }
      const apps = INSTALLED_APPS_DATA[this.currentLang] || INSTALLED_APPS_DATA['zh-Hans'];
      const matched = apps.filter(app => app.pinyin.startsWith(q) || app.name.toLowerCase().includes(q));
      if (matched.length === 0) { launcher.style.display = 'none'; return; }
      const topApp = matched[0];
      const al = this.t('appLauncher');
      launcher.innerHTML = `
        <div class="nook-app-launcher-header">
          <span>${al.header}</span> · <span class="nook-app-launcher-count">${matched.length}</span>
        </div>
        <div class="nook-row nook-app-row" id="nookLaunchAppRow" data-app-name="${this.escapeHTML(topApp.name)}">
          <div class="nook-row-tile">
            <div class="nook-app-row-icon">${APP_ICONS[topApp.icon]}</div>
          </div>
          <div class="nook-row-content">
            <div class="nook-row-title-line">
              <span class="nook-row-title">${this.highlightText(topApp.name, this.searchText.trim())}</span>
              <span class="nook-app-open-badge">${al.openBadge}</span>
            </div>
            <div class="nook-row-sub-line">
              <span class="nook-row-summary">${this.escapeHTML(topApp.path)}</span>
            </div>
          </div>
        </div>
      `;
    }

    /**
     * 顶栏左侧类型动作 (对齐 PreviewToolbar.swift:92-141 leadingActions)。
     * 仅 url / file 两种类型有按钮，且落在 Spacer 左侧、紧跟来源标识。
     */
    renderToolbarLeadActions(item) {
      const isHttpUrl = (s) => {
        try {
          const u = new URL(String(s || '').trim());
          return u.protocol === 'http:' || u.protocol === 'https:';
        } catch (e) {
          return false;
        }
      };
      if (item.kind === 'url') {
        if (!isHttpUrl(item.summary)) return '';
        return `
          <button type="button" class="nook-toolbar-btn" id="nookTbOpenBtn" title="${this.t('btnOpenBrowser')}" aria-label="${this.t('btnOpenBrowser')}">${ICONS.open}</button>
          <button type="button" class="nook-toolbar-btn${this.showQrCode ? ' is-active' : ''}" id="nookTbQrBtn" title="${this.t('btnQrTitle')}" aria-label="${this.t('btnQrTitle')}" aria-pressed="${this.showQrCode ? 'true' : 'false'}">${ICONS.qrcode}</button>
        `;
      }
      if (item.kind === 'file') {
        const paths = String(item.summary || '').split('\n').map(s => s.trim()).filter(Boolean);
        if (!paths.length) return '';
        // 站点无法触达用户磁盘，演示数据里出现「非当前用户 home」的路径即视作原文件已失效
        const filesExist = paths.every(p => p.startsWith('/Users/' + DEMO_USER_HOME + '/'));
        if (filesExist) {
          return `
            <button type="button" class="nook-toolbar-btn" id="nookTbOpenBtn" title="${this.t('btnOpen')}" aria-label="${this.t('btnOpen')}">${ICONS.open}</button>
            <button type="button" class="nook-toolbar-btn" id="nookTbFinderBtn" title="${this.t('btnFinder')}" aria-label="${this.t('btnFinder')}">${ICONS.folder}</button>
          `;
        }
        // 原文件已不存在：明示失效，且不再提供打开/访达按钮
        return `<span class="nook-preview-meta-pill">${this.t('fileMissingBadge')}</span>`;
      }
      return '';
    }

    /**
     * 顶栏标签 chip 区 (对齐 PreviewToolbar.swift:155-192 tagChips)：
     * 最多 3 枚 compact chip + "+N" 溢出面 + 末尾 `#` 按钮（打开标签编辑器）。
     */
    renderToolbarTagChips(item) {
      const tags = (item.tags || []).map(id => ({ id, name: this.getTagName(id) })).filter(t => t.name);
      const visible = tags.slice(0, 3);
      const hidden = tags.length - visible.length;
      return visible.map(t => `
        <button type="button" class="nook-preview-tag-chip" data-tag-id="${this.escapeHTML(t.id)}" title="${this.t('filterByTag')}">${this.escapeHTML(t.name)}</button>
      `).join('') + (hidden > 0 ? `<span class="nook-preview-tag-more">+${hidden}</span>` : '') + `
        <button type="button" class="nook-toolbar-btn" id="nookTbTagBtn" title="${this.t('tagBtnTitle')}" aria-label="${this.t('tagBtnTitle')}">${ICONS.hash}</button>
      `;
    }

    renderBatchState() {
      const batchBar = this.container.querySelector('#nookBatchBar');
      const hintsFooter = this.container.querySelector('#nookHintsFooter');
      const countEl = this.container.querySelector('#nookBatchCount');
      if (this.isBatchMode) {
        if (batchBar) batchBar.style.display = 'flex';
        if (hintsFooter) hintsFooter.style.display = 'none';
        if (countEl) countEl.textContent = this.t('batchSelected', this.selectedIds.size);
      } else {
        if (batchBar) batchBar.style.display = 'none';
        if (hintsFooter) hintsFooter.style.display = 'flex';
      }
    }

    bindEvents() {
      const win = this.container.querySelector('#nookWindow');
      const searchInput = this.container.querySelector('#nookSearchInput');
      const searchBar = this.container.querySelector('#nookSearchBar');
      const searchClear = this.container.querySelector('#nookSearchClear');

      if (searchInput) {
        // 聚焦搜索框 = 展开筛选面板（Spotlight/Raycast 式：点搜索框就能换类型/标签）
        searchInput.addEventListener('focus', () => {
          searchBar.classList.add('is-focused');
          this.isFilterPanelOpen = true;
          this.renderSearchChrome();
          this.renderFilterPanel();
        });
        searchInput.addEventListener('blur', () => searchBar.classList.remove('is-focused'));
        searchInput.addEventListener('input', (e) => {
          this.searchText = e.target.value;
          if (searchClear) searchClear.style.display = this.searchText ? 'flex' : 'none';
          // 面板内的标签搜索词与主搜索词共用一次输入（有筛选条件时先过滤标签）
          this.filterKeyword = this.searchText;
          this.renderSearchChrome();
          this.renderFilterPanel();
          this.renderRows();
          this.renderPreview();
          this.renderAppLauncher();
          this.updateStaticTexts();
        });
        searchInput.addEventListener('keydown', (e) => {
          if (e.key === 'Escape' && this.isFilterPanelOpen) {
            e.stopPropagation();
            this.isFilterPanelOpen = false;
            this.renderSearchChrome();
            this.renderFilterPanel();
          }
        });
      }

      if (searchClear) {
        searchClear.addEventListener('click', () => {
          this.searchText = "";
          this.filterKeyword = "";
          if (searchInput) { searchInput.value = ""; searchInput.focus(); }
          searchClear.style.display = 'none';
          this.renderSearchChrome();
          this.renderFilterPanel();
          this.renderRows();
          this.renderPreview();
          this.renderAppLauncher();
        });
      }

      const handleKey = (e) => {
        if (this.renamingId) {
          if (e.key === 'Enter') {
            const input = this.container.querySelector('#nookRenameInput');
            if (input) this.commitRename(this.renamingId, input.value);
            e.preventDefault();
            return;
          }
          if (e.key === 'Escape') {
            this.cancelRename();
            e.preventDefault();
            return;
          }
          return;
        }

        const isInputFocused = document.activeElement === searchInput;
        const meta = e.metaKey || e.ctrlKey;

        if (meta && e.key.toLowerCase() === 'f') {
          e.preventDefault();
          this.isFilterPanelOpen = true;
          if (searchInput) searchInput.focus();
          this.renderSearchChrome();
          this.renderFilterPanel();
          return;
        }

        if (meta && e.key === 'ArrowDown') {
          e.preventDefault();
          this.isFilterPanelOpen = !this.isFilterPanelOpen;
          this.renderSearchChrome();
          this.renderFilterPanel();
          return;
        }

        if (meta && e.key === '[') {
          e.preventDefault();
          this.cycleCategory(-1);
          return;
        }
        if (meta && e.key === ']') {
          e.preventDefault();
          this.cycleCategory(1);
          return;
        }

        if (meta && e.key.toLowerCase() === 't') {
          e.preventDefault();
          this.cycleTimeGroup();
          return;
        }

        if (meta && e.key.toLowerCase() === 's') {
          e.preventDefault();
          this.toggleFavoriteSelected();
          return;
        }

        if (meta && e.key.toLowerCase() === 'r') {
          e.preventDefault();
          if (this.selectedId) this.beginRename(this.selectedId);
          return;
        }

        if (meta && (e.key === 'Backspace' || e.key === 'Delete')) {
          e.preventDefault();
          if (this.isBatchMode && this.selectedIds.size > 0) {
            this.deleteBatch();
          } else {
            this.deleteSelected();
          }
          return;
        }

        if (meta && e.key.toLowerCase() === 'z') {
          e.preventDefault();
          this.undoLastDelete();
          return;
        }

        if (meta && e.key.toLowerCase() === 'c' && !isInputFocused) {
          e.preventDefault();
          this.copySelectedItem();
          return;
        }

        if (e.shiftKey && (e.key === 'ArrowDown' || e.key === 'ArrowUp')) {
          if (!this.isBatchMode) {
            this.isBatchMode = true;
            this.selectedIds.add(this.selectedId);
          }
          this.moveSelection(e.key === 'ArrowDown' ? 1 : -1, true);
          e.preventDefault();
          return;
        }

        if (e.key === 'ArrowDown' && !isInputFocused) {
          e.preventDefault();
          this.moveSelection(1, false);
          return;
        }
        if (e.key === 'ArrowUp' && !isInputFocused) {
          e.preventDefault();
          this.moveSelection(-1, false);
          return;
        }

        if (e.key === 'Enter') {
          e.preventDefault();
          if (this.isBatchMode && this.selectedIds.size > 0) {
            this.simulateBatchPaste();
            return;
          }
          this.simulatePaste(e.altKey, meta);
          return;
        }

        if (e.key === 'Escape') {
          if (this.isFilterPanelOpen) {
            this.isFilterPanelOpen = false;
            this.renderSearchChrome();
            this.renderFilterPanel();
            return;
          }
          if (this.isTimeMenuOpen) {
            this.toggleTimeDropdown(false);
            return;
          }
          if (this.isHelpOpen) {
            this.isHelpOpen = false;
            const popover = this.container.querySelector('#nookHelpPopover');
            const btn = this.container.querySelector('#nookHelpBtn');
            if (popover) popover.style.display = 'none';
            if (btn) btn.classList.remove('is-active');
            return;
          }
          if (this.isBatchMode) {
            this.isBatchMode = false;
            this.selectedIds.clear();
            this.render();
            return;
          }
          if (this.searchText) {
            this.searchText = "";
            if (searchInput) searchInput.value = "";
            this.render();
            return;
          }
          if (this.hasFilterChips()) {
            this.clearFilters();
            this.render();
            return;
          }
          this.showToast(this.t('toasts').escReset);
          return;
        }

        if (!meta && !e.altKey && !e.ctrlKey && e.key.length === 1 && !isInputFocused) {
          if (searchInput) {
            searchInput.focus();
            searchInput.value += e.key;
            this.searchText = searchInput.value;
            if (searchClear) searchClear.style.display = 'flex';
            this.renderRows();
            this.renderPreview();
            this.renderAppLauncher();
            e.preventDefault();
          }
        }
      };

      if (this.options.standalone) {
        window.addEventListener('keydown', handleKey);
      } else {
        win.addEventListener('keydown', handleKey);
      }

      document.addEventListener('click', (e) => {
        if (!this.container.contains(e.target)) {
          if (this.isFilterPanelOpen) {
            this.isFilterPanelOpen = false;
            this.renderSearchChrome();
            this.renderFilterPanel();
          }
          if (this.isTimeMenuOpen) {
            this.toggleTimeDropdown(false);
          }
          if (this.isHelpOpen) {
            this.isHelpOpen = false;
            const popover = this.container.querySelector('#nookHelpPopover');
            const btn = this.container.querySelector('#nookHelpBtn');
            if (popover) popover.style.display = 'none';
            if (btn) btn.classList.remove('is-active');
          }
        }
      });

      this.container.addEventListener('click', (e) => {
        // 搜索框内嵌胶囊：点击 ×（或胶囊本体）移除该筛选条件
        const embedChip = e.target.closest('.nook-embed-chip');
        if (embedChip) {
          e.stopPropagation();
          const kind = embedChip.getAttribute('data-chip-kind');
          const id = embedChip.getAttribute('data-chip-id');
          if (!kind) { // 「+N」角标：展开面板看全部条件
            this.isFilterPanelOpen = true;
            this.renderSearchChrome();
            this.renderFilterPanel();
            return;
          }
          if (kind === 'category') this.activeCategory = 0;
          else if (kind === 'tag') this.activeTag = null;
          this.afterFilterChange();
          return;
        }

        const clearBtn = e.target.closest('#nookFilterClearBtn');
        if (clearBtn) {
          e.stopPropagation();
          this.clearFilters();
          this.afterFilterChange();
          return;
        }

        const tagPill = e.target.closest('[data-tag-id]');
        if (tagPill) {
          e.stopPropagation();
          const tagId = tagPill.getAttribute('data-tag-id');
          this.activeTag = this.activeTag === tagId ? null : tagId;
          this.afterFilterChange();
          return;
        }

        // 类型瓷砖：空槽置灰但仍可点击（不触发切换），活动槽再点一次取消
        const typeTile = e.target.closest('.nook-type-tile[data-cat-id]');
        if (typeTile) {
          e.stopPropagation();
          if (typeTile.classList.contains('is-empty')) return;
          const catId = parseInt(typeTile.getAttribute('data-cat-id'), 10);
          this.activeCategory = this.activeCategory === catId ? 0 : catId;
          this.afterFilterChange();
          return;
        }

        const arrow = e.target.closest('#nookSlotArrowBtn');
        if (arrow) {
          e.stopPropagation();
          this.toggleTimeDropdown(false);
          this.toggleCategoryDropdown();
          return;
        }

        // 整块「组名 · 计数」都是跳转菜单入口（客户端 GroupHeaderView 的行为）
        const timeBtn = e.target.closest('#nookGroupMenuTrigger') || e.target.closest('#nookGroupCycleBtn');
        if (timeBtn) {
          e.stopPropagation();
          this.toggleCategoryDropdown(false);
          this.toggleTimeDropdown();
          return;
        }

        const timeOption = e.target.closest('[data-time-group-id]');
        if (timeOption) {
          e.stopPropagation();
          const targetGroup = timeOption.getAttribute('data-time-group-id');
          this.scrollToGroup(targetGroup);
          const title = timeOption.getAttribute('data-time-title');
          this.showToast(this.t('toasts').locateGroup(title));
          this.toggleTimeDropdown(false);
          return;
        }

        const row = e.target.closest('.nook-row');
        if (row) {
          const id = row.getAttribute('data-id');
          if (this.isBatchMode) {
            if (this.selectedIds.has(id)) this.selectedIds.delete(id);
            else this.selectedIds.add(id);
          }
          this.selectedId = id;
          this.renderRows();
          this.renderPreview();
          this.renderBatchState();
          return;
        }

        const favBtn = e.target.closest('#nookFavoriteBtn');
        if (favBtn) { this.toggleFavoriteSelected(); return; }

        const delBtn = e.target.closest('#nookDeleteBtn');
        if (delBtn) { this.deleteSelected(); return; }

        const undoBtn = e.target.closest('#nookUndoBtn');
        if (undoBtn) { this.undoLastDelete(); return; }

        const helpBtn = e.target.closest('#nookHelpBtn');
        if (helpBtn) {
          e.stopPropagation();
          this.isHelpOpen = !this.isHelpOpen;
          const popover = this.container.querySelector('#nookHelpPopover');
          if (popover) popover.style.display = this.isHelpOpen ? 'flex' : 'none';
          helpBtn.classList.toggle('is-active', this.isHelpOpen);
          return;
        }

        const sensToggle = e.target.closest('#nookSensitiveToggleBtn');
        if (sensToggle) {
          const item = this.getSelectedItem();
          if (item) this.toggleSensitiveReveal(item.id);
          return;
        }

        const codeTab = e.target.closest('.nook-code-tab');
        if (codeTab) {
          const seg = parseInt(codeTab.getAttribute('data-seg'), 10);
          const item = this.getSelectedItem();
          if (item) { this.jsonSegments[item.id] = seg; this.renderPreview(); }
          return;
        }

        const copyCodeBtn = e.target.closest('#nookCopyCodeBtn');
        if (copyCodeBtn) {
          const item = this.getSelectedItem();
          if (item) this.copyTextToClipboard(item.summary, this.t('toasts').codeCopied);
          return;
        }

        const copyOcrBtn = e.target.closest('#nookCopyOcrBtn');
        if (copyOcrBtn) {
          const item = this.getSelectedItem();
          if (item && item.ocrText) {
            this.copyTextToClipboard(item.ocrText, this.t('toasts').ocrCopied);
            const btnText = copyOcrBtn.querySelector('#nookOcrCopyText');
            if (btnText) {
              const origText = btnText.textContent;
              btnText.textContent = this.t('colorCard').copied;
              copyOcrBtn.classList.add('is-copied');
              setTimeout(() => {
                btnText.textContent = origText;
                copyOcrBtn.classList.remove('is-copied');
              }, 1600);
            }
          }
          return;
        }

        const ocrBtn = e.target.closest('#nookTriggerOcrBtn') || e.target.closest('#nookLiveTextBtn');
        if (ocrBtn) { this.triggerOcrScan(); return; }

        const rulesToggle = e.target.closest('#nookOcrRulesToggle');
        if (rulesToggle) {
          this.showOcrRules = !this.showOcrRules;
          const banner = this.container.querySelector('#nookOcrRulesBanner');
          const chevron = this.container.querySelector('#nookRulesChevron');
          const btnSpan = rulesToggle.querySelector('span:nth-child(2)');
          const oc = this.t('ocrCard');
          if (banner) {
            banner.style.display = this.showOcrRules ? 'flex' : 'none';
            if (chevron) chevron.textContent = this.showOcrRules ? '▴' : '▾';
            if (btnSpan) btnSpan.textContent = this.showOcrRules ? oc.collapse : oc.rules;
          }
          return;
        }

        const tbOpenBtn = e.target.closest('#nookTbOpenBtn');
        if (tbOpenBtn) {
          this.showToast(this.t('toasts').openSimulated);
          return;
        }
        const tbFinderBtn = e.target.closest('#nookTbFinderBtn');
        if (tbFinderBtn) {
          this.showToast(this.t('toasts').revealFinderSimulated);
          return;
        }
        const tbQrBtn = e.target.closest('#nookTbQrBtn');
        if (tbQrBtn) {
          // 二维码按钮为开关态（PreviewToolbar.swift: isActive: showQRCode）
          this.showQrCode = !this.showQrCode;
          this.renderPreview();
          this.showToast(this.t('toasts').qrShown);
          return;
        }
        const tbTagBtn = e.target.closest('#nookTbTagBtn');
        if (tbTagBtn) {
          this.showToast(this.t('tagBtnTitle'));
          return;
        }
        const tbTagChip = e.target.closest('.nook-preview-tag-chip');
        if (tbTagChip) {
          // 点击 chip 按该标签过滤（与筛选面板的标签胶囊同一行为）
          e.stopPropagation();
          const tagId = tbTagChip.getAttribute('data-tag-id');
          this.activeTag = this.activeTag === tagId ? null : tagId;
          this.afterFilterChange();
          return;
        }
        const copyUrlBtn = e.target.closest('#nookCopyUrlBtn');
        if (copyUrlBtn) {
          const item = this.getSelectedItem();
          if (item) this.copyTextToClipboard(item.summary, this.t('toasts').urlCopied);
          return;
        }

        const hexBtn = e.target.closest('#nookCopyHexRow') || e.target.closest('#nookHexCopyBtn');
        if (hexBtn) {
          const item = this.getSelectedItem();
          if (item && item.colorHex) {
            this.copyTextToClipboard(item.colorHex, this.t('toasts').hexCopied(item.colorHex));
            const fb = this.container.querySelector('#nookHexFeedback');
            if (fb) { fb.style.display = 'inline'; setTimeout(() => fb.style.display = 'none', 1600); }
          }
          return;
        }
        const rgbBtn = e.target.closest('#nookCopyRgbRow') || e.target.closest('#nookRgbCopyBtn');
        if (rgbBtn) {
          const item = this.getSelectedItem();
          if (item && item.rgbValue) {
            this.copyTextToClipboard(item.rgbValue, this.t('toasts').rgbCopied(item.rgbValue));
            const fb = this.container.querySelector('#nookRgbFeedback');
            if (fb) { fb.style.display = 'inline'; setTimeout(() => fb.style.display = 'none', 1600); }
          }
          return;
        }

        const fileCopyBtn = e.target.closest('.nook-file-copy-btn');
        if (fileCopyBtn) {
          const path = fileCopyBtn.getAttribute('data-path');
          if (path) {
            this.copyTextToClipboard(path, this.t('toasts').pathCopied(path.split('/').pop()));
            fileCopyBtn.innerHTML = ICONS.check;
            fileCopyBtn.classList.add('is-copied');
            setTimeout(() => {
              fileCopyBtn.innerHTML = ICONS.copy;
              fileCopyBtn.classList.remove('is-copied');
            }, 1600);
          }
          return;
        }

        const revealFinderBtn = e.target.closest('#nookRevealFinderBtn');
        if (revealFinderBtn) {
          this.showToast(this.t('toasts').revealFinderSimulated);
          return;
        }

        const batchMerge = e.target.closest('#nookBatchMergeBtn');
        if (batchMerge) { this.simulateBatchPaste(); return; }

        const batchDel = e.target.closest('#nookBatchDeleteBtn');
        if (batchDel) { this.deleteBatch(); return; }

        const launchRow = e.target.closest('#nookLaunchAppRow');
        if (launchRow) { this.simulateAppLaunch(launchRow.getAttribute('data-app-name')); return; }
      });

      this.container.addEventListener('dblclick', (e) => {
        const titleEl = e.target.closest('.nook-row-title');
        if (titleEl) {
          const row = titleEl.closest('.nook-row');
          if (row) this.beginRename(row.getAttribute('data-id'));
        }
      });
    }

    moveSelection(delta, isMulti) {
      const list = this.getFilteredItems();
      if (list.length === 0) return;
      let currIdx = list.findIndex(it => it.id === this.selectedId);
      if (currIdx === -1) currIdx = 0;
      let nextIdx = currIdx + delta;
      if (nextIdx < 0) nextIdx = 0;
      if (nextIdx >= list.length) nextIdx = list.length - 1;

      this.selectedId = list[nextIdx].id;
      this.renderRows();
      this.renderPreview();
      this.scrollSelectedIntoView();

      if (isMulti) {
        this.selectedIds.add(this.selectedId);
        this.renderBatchState();
      }
    }

    scrollSelectedIntoView() {
      const scroll = this.container.querySelector('#nookListScroll');
      const selectedEl = this.container.querySelector(`.nook-row[data-id="${this.selectedId}"]`);
      if (!scroll || !selectedEl) return;

      const sTop = scroll.scrollTop;
      const sHeight = scroll.clientHeight;
      const elTop = selectedEl.offsetTop;
      const elHeight = selectedEl.offsetHeight;

      if (elTop < sTop) {
        scroll.scrollTop = elTop - 4;
      } else if (elTop + elHeight > sTop + sHeight) {
        scroll.scrollTop = elTop + elHeight - sHeight + 4;
      }
    }

    /** 兼容旧调用点：原「第 4 槽」分类下拉已退役，改开合搜索框筛选面板 */
    toggleCategoryDropdown(force) {
      this.isFilterPanelOpen = (typeof force === 'boolean') ? force : !this.isFilterPanelOpen;
      if (this.isFilterPanelOpen) this.toggleTimeDropdown(false);
      this.renderSearchChrome();
      this.renderFilterPanel();
    }

    /** 筛选条件变更后的统一收尾：重绘胶囊、面板与列表（面板保持展开便于连续勾选） */
    afterFilterChange() {
      this.isFilterPanelOpen = true;
      this.renderSearchChrome();
      this.renderFilterPanel();
      this.renderRows();
      this.renderAppLauncher();
      this.renderPreview();
    }

    toggleTimeDropdown(force) {
      this.isTimeMenuOpen = (typeof force === 'boolean') ? force : !this.isTimeMenuOpen;
      const dropdown = this.container.querySelector('#nookTimeDropdown');
      if (!dropdown) return;
      if (!this.isTimeMenuOpen) {
        dropdown.style.display = 'none';
        return;
      }
      this.toggleCategoryDropdown(false);

      const list = this.getFilteredItems();
      const groups = [];
      const seen = new Set();
      list.forEach(it => {
        const grp = it.timeGroup || 'today';
        const title = it.groupTitle || this.t('today');
        if (!seen.has(grp)) {
          seen.add(grp);
          const count = list.filter(i => (i.timeGroup || 'today') === grp).length;
          groups.push({ id: grp, title, count });
        }
      });

      const selected = this.getSelectedItem();
      const currGroup = selected ? (selected.timeGroup || 'today') : 'today';

      let html = '';
      groups.forEach(g => {
        const isSelected = g.id === currGroup;
        html += `
          <button type="button" class="nook-dropdown-item ${isSelected ? 'is-selected' : ''}" data-time-group-id="${g.id}" data-time-title="${g.title}">
            <span style="font-weight: ${isSelected ? '600' : '400'};">${g.title}</span>
            <span class="nook-dropdown-count">${g.count}</span>
          </button>
        `;
      });
      if (!groups.length) {
        html = `<div class="nook-filter-empty" style="padding:8px 10px;">${this.t('timeMenuEmpty')}</div>`;
      }
      dropdown.innerHTML = html;
      dropdown.style.display = 'flex';
    }

    /**
     * ⌘[ / ⌘] 在「全部 + 有内容的类型」间循环。
     * 空类型槽（如回收站）不进循环——否则会切到一个空列表。
     */
    cycleCategory(step) {
      const ids = this.getCycleCategoryIds();
      const currIdx = ids.indexOf(this.activeCategory);
      const nextIdx = currIdx === -1
        ? (step > 0 ? 0 : ids.length - 1)
        : (currIdx + step + ids.length) % ids.length;
      this.activeCategory = ids[nextIdx];
      this.render();
      this.renderSearchChrome();
      const catName = this.getCategoryName(this.activeCategory);
      this.showToast(this.t('toasts').category(catName || this.getCategoryName(0)));
    }

    toggleFavoriteSelected() {
      const item = this.getSelectedItem();
      if (!item) return;
      item.isFavorite = !item.isFavorite;
      this.render();
      this.showToast(item.isFavorite ? this.t('toasts').favorited(item.title) : this.t('toasts').unfavorited(item.title));
    }

    deleteSelected() {
      const item = this.getSelectedItem();
      if (!item) return;
      const idx = this.items.findIndex(it => it.id === item.id);
      if (idx !== -1) {
        this.deletedStack.push({ item, index: idx });
        this.items.splice(idx, 1);
        this.startUndoToast();
        this.render();
        this.showToast(this.t('toasts').deletedOne(item.title));
      }
    }

    deleteBatch() {
      if (this.selectedIds.size === 0) return;
      const deleted = [];
      this.items = this.items.filter((it, idx) => {
        if (this.selectedIds.has(it.id)) {
          deleted.push({ item: it, index: idx });
          return false;
        }
        return true;
      });
      this.deletedStack.push(...deleted);
      this.selectedIds.clear();
      this.isBatchMode = false;
      this.startUndoToast();
      this.render();
      this.showToast(this.t('toasts').deletedBatch(deleted.length));
    }

    startUndoToast() {
      const toast = this.container.querySelector('#nookUndoToast');
      const prog = this.container.querySelector('#nookUndoProgress');
      const text = this.container.querySelector('.nook-undo-toast-text');
      if (!toast || !prog) return;

      if (text) {
        text.textContent = this.t('undoToast', this.deletedStack.length || 1);
      }

      clearTimeout(this.undoTimer);
      toast.style.display = 'flex';
      prog.style.width = '100%';
      prog.style.transition = 'width 10s linear';

      requestAnimationFrame(() => {
        prog.style.width = '0%';
      });

      this.undoTimer = setTimeout(() => {
        toast.style.display = 'none';
        this.deletedStack = [];
      }, 10000);
    }

    undoLastDelete() {
      if (this.deletedStack.length === 0) return;
      const last = this.deletedStack.pop();
      this.items.splice(last.index, 0, last.item);
      this.selectedId = last.item.id;

      if (this.deletedStack.length === 0) {
        clearTimeout(this.undoTimer);
        const toast = this.container.querySelector('#nookUndoToast');
        if (toast) toast.style.display = 'none';
      }

      this.render();
      this.showToast(this.t('toasts').undoDeleted(last.item.title));
    }

    beginRename(id) {
      this.renamingId = id;
      this.renderRows();
    }

    commitRename(id, newTitle) {
      const item = this.items.find(it => it.id === id);
      if (item && newTitle.trim()) {
        item.title = newTitle.trim();
        this.showToast(this.t('toasts').renameUpdated(item.title));
      }
      this.renamingId = null;
      this.render();
    }

    cancelRename() {
      this.renamingId = null;
      this.renderRows();
    }

    toggleSensitiveReveal(id) {
      const isRev = !this.sensitiveRevealed[id];
      this.sensitiveRevealed[id] = isRev;

      if (isRev) {
        clearTimeout(this.sensitiveTimers[id]);
        this.showToast(this.t('toasts').sensitiveRevealed);
        this.sensitiveTimers[id] = setTimeout(() => {
          this.sensitiveRevealed[id] = false;
          this.renderPreview();
          this.showToast(this.t('toasts').sensitiveAutoLocked);
        }, 30000);
      } else {
        clearTimeout(this.sensitiveTimers[id]);
        this.showToast(this.t('toasts').sensitiveMasked);
      }
      this.renderPreview();
    }

    triggerOcrScan() {
      if (this.isOcrScanning) return;
      const item = this.getSelectedItem();
      if (!item) return;

      this.isOcrScanning = true;
      this.renderPreview();
      this.showToast(this.t('toasts').ocrLoading);

      setTimeout(() => {
        this.isOcrScanning = false;
        if (item.rawOcrText) {
          item.ocrText = item.rawOcrText;
        }
        this.renderPreview();
        this.showToast(this.t('toasts').ocrDone);
      }, 1200);
    }

    copySelectedItem() {
      const item = this.getSelectedItem();
      if (!item) return;
      const text = item.isSensitive && this.sensitiveRevealed[item.id] ? item.plainText : item.summary;
      this.copyTextToClipboard(text, this.t('toasts').copiedItem(item.title));
    }

    simulatePaste(plainTextOnly = false, keepOpen = false) {
      const item = this.getSelectedItem();
      if (!item) return;
      const text = item.isSensitive && this.sensitiveRevealed[item.id] ? item.plainText : item.summary;
      this.copyTextToClipboard(text, null);

      if (plainTextOnly) {
        this.showToast(this.t('toasts').pastePlain(item.title));
      } else if (keepOpen) {
        this.showToast(this.t('toasts').pasteKeep(item.title));
      } else {
        this.showToast(this.t('toasts').pasteQuick(item.title));
      }
    }

    simulateBatchPaste() {
      const texts = [];
      this.items.forEach(it => {
        if (this.selectedIds.has(it.id)) texts.push(it.summary);
      });
      const joined = texts.join('\n');
      this.copyTextToClipboard(joined, null);
      this.showToast(this.t('toasts').pasteBatch(texts.length));
      this.isBatchMode = false;
      this.selectedIds.clear();
      this.render();
    }

    simulateAppLaunch(appName) {
      this.showToast(this.t('toasts').appLaunched(appName));
    }

    renderTimeRail() {
      const rail = this.container.querySelector('#nookTimeRail');
      if (!rail) return;
      const list = this.getFilteredItems();
      const groups = [];
      const seen = new Set();
      list.forEach(it => {
        const grp = it.timeGroup || 'today';
        const title = it.groupTitle || this.t('today');
        if (!seen.has(grp)) {
          seen.add(grp);
          const count = list.filter(i => (i.timeGroup || 'today') === grp).length;
          groups.push({ id: grp, title, count });
        }
      });

      const selectedItem = this.getSelectedItem();
      const currentGroup = selectedItem ? (selectedItem.timeGroup || 'today') : 'today';

      let html = '';
      groups.forEach(g => {
        const isActive = g.id === currentGroup;
        html += `<div class="nook-rail-dot ${isActive ? 'is-active' : ''}" data-group="${g.id}" title="${g.title} · ${g.count}"></div>`;
      });
      html += `<div class="nook-rail-hud" id="nookRailHud" style="display:none;"></div>`;
      rail.innerHTML = html;

      // 悬停气泡 HUD 展现
      const hud = rail.querySelector('#nookRailHud');
      rail.querySelectorAll('.nook-rail-dot').forEach(dot => {
        dot.addEventListener('mouseenter', () => {
          const gId = dot.getAttribute('data-group');
          const g = groups.find(it => it.id === gId);
          if (hud && g) {
            hud.textContent = `${g.title} · ${g.count}`;
            hud.style.top = `${dot.offsetTop - 8}px`;
            hud.style.display = 'block';
          }
        });
        dot.addEventListener('mouseleave', () => {
          if (hud) hud.style.display = 'none';
        });
        dot.addEventListener('click', (e) => {
          e.stopPropagation();
          const gId = dot.getAttribute('data-group');
          const g = groups.find(it => it.id === gId);
          if (g) {
            this.scrollToGroup(g.id);
            this.showToast(this.t('toasts').locateGroup(g.title));
          }
        });
      });
    }

    cycleTimeGroup() {
      const list = this.getFilteredItems();
      const groups = [];
      const seen = new Set();
      list.forEach(it => {
        const grp = it.timeGroup || 'today';
        if (!seen.has(grp)) {
          seen.add(grp);
          groups.push({ id: grp, title: it.groupTitle || this.t('today') });
        }
      });
      if (groups.length <= 1) return;

      const selected = this.getSelectedItem();
      const currGroup = selected ? (selected.timeGroup || 'today') : 'today';
      const currIdx = groups.findIndex(g => g.id === currGroup);
      const nextIdx = (currIdx + 1) % groups.length;
      const nextGroup = groups[nextIdx];

      this.scrollToGroup(nextGroup.id);
      this.showToast(this.t('toasts').locateGroup(nextGroup.title));
    }

    scrollToGroup(group) {
      const list = this.getFilteredItems();
      const target = list.find(it => (it.timeGroup || 'today') === group);
      if (target) {
        this.selectedId = target.id;
        this.render();
        const scroll = this.container.querySelector('#nookListScroll');
        const el = this.container.querySelector(`.nook-row[data-id="${target.id}"]`) ||
                   this.container.querySelector(`.nook-subgroup-header[data-time-group="${group}"]`);
        if (scroll && el) {
          scroll.scrollTop = Math.max(0, el.offsetTop - 6);
        }
      }
    }

    resetDemoData() {
      this.items = getDemoItems(this.currentLang);
      this.selectedId = this.items[0].id;
      this.selectedIds.clear();
      this.isBatchMode = false;
      this.clearFilters();
      this.isFilterPanelOpen = false;
      this.filterKeyword = "";
      this.searchText = "";
      this.deletedStack = [];
      const searchInput = this.container.querySelector('#nookSearchInput');
      if (searchInput) searchInput.value = "";
      this.render();
      this.showToast(this.t('toasts').resetDemo);
    }

    setTheme(theme) {
      this.currentTheme = theme;
      this.updateThemeVisuals();
    }

    copyTextToClipboard(text, toastMsg) {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).catch(() => {});
      }
      if (toastMsg) this.showToast(toastMsg);
    }

    showToast(message) {
      const hud = this.container.querySelector('#nookPasteHud');
      const text = this.container.querySelector('#nookPasteHudText');
      if (!hud || !text) return;

      text.textContent = message;
      hud.classList.add('is-visible');

      clearTimeout(this.toastTimer);
      this.toastTimer = setTimeout(() => {
        hud.classList.remove('is-visible');
      }, 2200);

      if (this.options.onToast) this.options.onToast(message);
    }

    escapeHTML(str) {
      return (str || '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
    }

    highlightText(text, query) {
      if (!query || !text) return this.escapeHTML(text);
      const safe = this.escapeHTML(text);
      const q = query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const regex = new RegExp(`(${q})`, 'gi');
      return safe.replace(regex, '<mark class="nook-highlight">$1</mark>');
    }

    formatTextBody(text, query) {
      if (!text) return '';
      let safe = this.escapeHTML(text);
      if (query) {
        const q = query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        const regex = new RegExp(`(${q})`, 'gi');
        safe = safe.replace(regex, '<mark class="nook-highlight">$1</mark>');
      }
      return safe.replace(/\n/g, '<br>');
    }

    getFileIconSVG(filename) {
      const ext = (filename || '').split('.').pop().toLowerCase();
      let badgeBg = '#0A84FF';
      let badgeText = 'DOC';
      if (ext === 'pdf') {
        badgeBg = '#EF4444';
        badgeText = 'PDF';
      } else if (ext === 'sql') {
        badgeBg = '#3B82F6';
        badgeText = 'SQL';
      } else if (ext === 'dmg' || ext === 'zip') {
        badgeBg = '#F59E0B';
        badgeText = ext.toUpperCase();
      }
      return `
        <svg viewBox="0 0 20 22" width="18" height="20" fill="none">
          <path d="M2.5 1A1.5 1.5 0 0 0 1 2.5v17A1.5 1.5 0 0 0 2.5 21h15a1.5 1.5 0 0 0 1.5-1.5V6.5L14.5 1H2.5z" fill="#E2E8F0"/>
          <path d="M14 1v5.5h5.5" fill="#CBD5E1"/>
          <rect x="2" y="11" width="16" height="8" rx="1.5" fill="${badgeBg}"/>
          <text x="10" y="17.2" fill="#FFFFFF" font-family="-apple-system, sans-serif" font-size="6.5" font-weight="bold" text-anchor="middle" letter-spacing="0.5">${badgeText}</text>
        </svg>
      `;
    }

    formatCodeLines(code) {
      const lines = (code || '').split('\n');
      return lines.map((line, idx) => {
        let highlighted = this.escapeHTML(line)
          .replace(/"([^"]+)":/g, '<span class="nook-syn-key">"$1"</span>:')
          .replace(/: "([^"]+)"/g, ': <span class="nook-syn-string">"$1"</span>')
          .replace(/\b(true|false|null)\b/g, '<span class="nook-syn-bool">$1</span>')
          .replace(/\b(\d+)\b/g, '<span class="nook-syn-num">$1</span>')
          .replace(/\b(pub|fn|let|struct|impl|match|return)\b/g, '<span class="nook-syn-key">$1</span>');

        return `
          <div class="nook-code-line">
            <span class="nook-line-num">${idx + 1}</span>
            <span class="nook-line-text">${highlighted}</span>
          </div>
        `;
      }).join('');
    }
  }

  window.NookClipPrototype = NookClipPrototype;

})(window);
