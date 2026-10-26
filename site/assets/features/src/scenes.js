/**
 * NookClip 三功能动态介绍 —— 逐帧可寻址的动画时间轴
 *
 * 设计要点：全部动效都由 __seek(t) 纯函数式算出，不使用 CSS transition/animation，
 * 所以任何时刻都能精确复现同一帧，方便 headless Chrome 逐帧截图再合成 GIF/MP4。
 */
(function () {
  'use strict';

  const W = 1240;
  const H = 860;

  // ---------------------------------------------------------------- 缓动 / 工具
  const E = {
    lin: (t) => t,
    out: (t) => 1 - Math.pow(1 - t, 3),
    in: (t) => t * t * t,
    io: (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2),
    out2: (t) => 1 - Math.pow(1 - t, 2),
    back: (t) => {
      const c1 = 1.70158, c3 = c1 + 1;
      return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2);
    },
    spring: (t) => 1 - Math.exp(-7 * t) * Math.cos(8.5 * t),
  };

  const clamp = (v, a = 0, b = 1) => (v < a ? a : v > b ? b : v);
  const lerp = (a, b, t) => a + (b - a) * t;

  /** t 落在 [t0, t0+dur] 的归一化进度（带缓动） */
  function tw(t, t0, dur, ease = 'io') {
    if (dur <= 0) return t >= t0 ? 1 : 0;
    return (E[ease] || E.io)(clamp((t - t0) / dur));
  }
  /** 0→1→0 的三角脉冲窗 */
  function win(t, t0, dur, fadeIn = 160, fadeOut = 220) {
    const p = (t - t0) / dur;
    if (p < 0 || p > 1) return 0;
    const i = clamp((t - t0) / fadeIn);
    const o = clamp((t0 + dur - t) / fadeOut);
    return Math.min(i, o);
  }

  const css = (el, o) => { for (const k in o) el.style[k] = o[k]; };
  const q = (root, sel) => root.querySelector(sel);
  const qa = (root, sel) => Array.from(root.querySelectorAll(sel));
  const show = (el, v) => { el.style.opacity = v; };

  // ---------------------------------------------------------------- 图标
  const I = {
    search: '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.6 15.6 20 20"/></svg>',
    doc: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3h7l5 5v13H6z"/><path d="M13 3v5h5"/><path d="M9 13h6M9 17h4"/></svg>',
    image: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="4.5" width="17" height="15" rx="2.5"/><circle cx="9" cy="10" r="1.6"/><path d="M4.5 17.5 10 12l4 4 2.5-2.5 3 3"/></svg>',
    link: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.4 2.4 2.4 14.6 0 17-2.4-2.4-2.4-14.6 0-17z"/></svg>',
    code: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 7 4 12l5 5M15 7l5 5-5 5"/></svg>',
    json: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M8.5 4c-2 0-2.5 1.4-2.5 3s.4 3-2 3c2.4 0 2 1.4 2 3s.5 3 2.5 3"/><path d="M15.5 4c2 0 2.5 1.4 2.5 3s-.4 3 2 3c-2.4 0-2 1.4-2 3s-.5 3-2.5 3"/></svg>',
    terminal: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4.5" width="18" height="15" rx="2.5"/><path d="M7 10l2.6 2.4L7 14.8M12.5 15h4"/></svg>',
    star: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2.6l2.9 6 6.6.9-4.8 4.6 1.2 6.5L12 17.5 6.1 20.6l1.2-6.5L2.5 9.5l6.6-.9z"/></svg>',
    pin: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 3h6l-1 5 4 3v2H6v-2l4-3z"/><path d="M12 13v8"/></svg>',
    scrub: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2.8 4.8 5.5v6.1c0 4.2 3 7.9 7.2 9.6 4.2-1.7 7.2-5.4 7.2-9.6V5.5z"/><path d="M8.6 11.2l2.2 2.2 4.4-4.6"/></svg>',
    shield: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2.8 4.8 5.5v6.1c0 4.2 3 7.9 7.2 9.6 4.2-1.7 7.2-5.4 7.2-9.6V5.5z"/><path d="M12 8.4v4.2M12 15.6v.6"/></svg>',
    trash: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9.5 7V4.6h5V7M6.6 7l.9 12.4h9l.9-12.4"/></svg>',
    copy: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="8.5" y="3" width="11.5" height="13" rx="2"/><path d="M15.5 19.5H6a2 2 0 0 1-2-2V8"/></svg>',
    stack: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="3.5" width="17" height="4.6" rx="1.4"/><rect x="3.5" y="10.2" width="17" height="4.6" rx="1.4"/><rect x="3.5" y="16.9" width="17" height="3.6" rx="1.2" opacity=".45"/></svg>',
    tag: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 3.5H20.5V13L12 21.5 2.5 12z"/><circle cx="16.4" cy="7.6" r="1.4"/></svg>',
    play: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M6 3.5 20 12 6 20.5z"/></svg>',
    check: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M4.5 12.8 9.5 18 20 6.5"/></svg>',
    x: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"><path d="M5.5 5.5 18.5 18.5M18.5 5.5 5.5 18.5"/></svg>',
    pencil: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 20l.9-4.2L16.4 4.3a1.9 1.9 0 0 1 2.7 0l.6.6a1.9 1.9 0 0 1 0 2.7L8.2 19.1z"/></svg>',
    save: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 5.5A1.5 1.5 0 0 1 5.5 4h9L20 9.5v9A1.5 1.5 0 0 1 18.5 20h-13A1.5 1.5 0 0 1 4 18.5z"/><path d="M8 4v5.5h6V4M8 20v-5.5h8V20"/></svg>',
    lock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4.8" y="10.4" width="14.4" height="10.2" rx="2.2"/><path d="M8.4 10.4V7.6a3.6 3.6 0 0 1 7.2 0v2.8"/></svg>',
    unlock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4.8" y="10.4" width="14.4" height="10.2" rx="2.2"/><path d="M8.4 10.4V7.6a3.6 3.6 0 0 1 6.9-1.3"/></svg>',
    up: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M6 15l6-6 6 6"/></svg>',
    down: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6 6 6-6"/></svg>',
    gripR: '<svg viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M2 8 8 2M6 8h2V6"/></svg>',
    gripL: '<svg viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M8 8 2 2M4 8H2V6"/></svg>',
    ocr: '<svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M2 5V3.5A1.5 1.5 0 0 1 3.5 2H5M11 2h1.5A1.5 1.5 0 0 1 14 3.5V5M14 11v1.5a1.5 1.5 0 0 1-1.5 1.5H11M5 14H3.5A1.5 1.5 0 0 1 2 12.5V11"/><path d="M4.5 6.5h7M4.5 9.5h7"/></svg>',
    filter: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3"/></svg>',
  };

  const CAT_COLOR = {
    text: '#0A84FF', image: '#BF5AF2', file: '#FF9F0A', url: '#30D158',
    code: '#5E5CE6', json: '#40C8E0', color: '#FF6482',
  };
  const APP_ICON = (n) => `../../../../site/assets/apps/${n}.png`;

  // ---------------------------------------------------------------- 列表数据
  // 场景 A：发布说明的四条内容，正好演示「按复制顺序贴完」
  const ROWS_A = [
    { cat: 'text', title: '【NookClip 1.4 更新】', app: 'notes', appName: '备忘录', detail: '更新日志', time: '今天 11:42' },
    { cat: 'text', title: '新增：顺序粘贴栈（⌥⏎）', app: 'notes', appName: '备忘录', detail: '更新日志', time: '今天 11:41' },
    { cat: 'text', title: '新增：语义脱敏粘贴（⌃⏎）', app: 'notes', appName: '备忘录', detail: '更新日志', time: '今天 11:40' },
    { cat: 'text', title: '新增：屏幕置顶贴条（⌘P）', app: 'notes', appName: '备忘录', detail: '更新日志', time: '今天 11:39' },
    { cat: 'text', title: '进阶效率快捷键速查卡（常驻备忘）', app: 'notes', appName: '备忘录', detail: '效率…', time: '今天 11:29', star: true },
    { cat: 'image', title: '图片与离线 Vision OCR 演示', app: 'screenshot', appName: '截图', detail: '640 × 320', time: '今天 11:10' },
    { cat: 'color', title: 'macOS 系统强调蓝（色彩胶囊演示）', app: 'nook', appName: 'Figma', detail: '#007AFF', time: '今天 10:40', swatch: '#007AFF' },
    { cat: 'text', title: 'OpenAI API 密钥（隐私加密保护演示）', app: 'terminal', appName: 'Terminal', detail: 'sk-proj-…56GCM', time: '今天 10:38', sensitive: true },
    { cat: 'json', title: '代码高亮与 JSON 格式化演示', app: 'xcode', appName: 'Xcode', detail: '{"app":…}', time: '今天 10:36', star: true },
    { cat: 'link', title: 'GitHub PR 合并指引', app: 'safari', appName: 'Safari', detail: 'github.co…ull/75421', time: '昨天 05:49', star: true },
  ];

  // 场景 B：一份含 6 处敏感信息的部署配置
  const ROWS_B = [
    { cat: 'text', title: '欢迎使用 NookClip — 30 秒上手指南', app: 'nook', appName: 'NookClip', detail: '核心…', time: '今天 11:44', star: true },
    { cat: 'link', title: 'GitHub PR 合并指引', app: 'safari', appName: 'Safari', detail: 'github.co…ull/75421', time: '今天 11:31', star: true },
    { cat: 'text', title: 'prod.env（部署配置备份）', app: 'terminal', appName: 'Terminal', detail: '6 行 · 含密钥', time: '今天 11:26', sensitive: true },
    { cat: 'code', title: 'SwiftUI 状态管理实践小结', app: 'xcode', appName: 'Xcode', detail: '使用 @O…', time: '今天 11:02' },
    { cat: 'text', title: '进阶效率快捷键速查卡（常驻备忘）', app: 'notes', appName: '备忘录', detail: '效率…', time: '今天 10:58', star: true },
    { cat: 'image', title: '图片与离线 Vision OCR 演示', app: 'screenshot', appName: '截图', detail: '640 × 320', time: '今天 10:40' },
    { cat: 'json', title: '代码高亮与 JSON 格式化演示', app: 'xcode', appName: 'Xcode', detail: '{"app":…}', time: '今天 10:36', star: true },
    { cat: 'color', title: 'macOS 系统强调蓝（色彩胶囊演示）', app: 'nook', appName: 'Figma', detail: '#007AFF', time: '今天 10:20', swatch: '#007AFF' },
    { cat: 'link', title: 'Rust 并发无锁设计', app: 'vscode', appName: 'Visual Studio Code', detail: '…', time: '昨天 13:01' },
    { cat: 'file', title: 'NookClip-1.4.dmg', app: 'finder', appName: '访达', detail: '12.4 MB', time: '昨天 09:12' },
  ];

  // 场景 C：一条长文本，适合钉在屏幕上当备忘
  const ROWS_C = [
    { cat: 'text', title: '进阶效率快捷键速查卡（常驻备忘）', app: 'notes', appName: '备忘录', detail: '效率…', time: '今天 11:29', star: true },
    { cat: 'image', title: '图片与离线 Vision OCR 演示', app: 'screenshot', appName: '截图', detail: '640 × 320', time: '今天 11:10' },
    { cat: 'color', title: 'macOS 系统强调蓝（色彩胶囊演示）', app: 'nook', appName: 'Figma', detail: '#007AFF', time: '今天 10:40', swatch: '#007AFF' },
    { cat: 'text', title: 'OpenAI API 密钥（隐私加密保护演示）', app: 'terminal', appName: 'Terminal', detail: 'sk-proj-…56GCM', time: '今天 10:38', sensitive: true },
    { cat: 'json', title: '代码高亮与 JSON 格式化演示', app: 'xcode', appName: 'Xcode', detail: '{"app":…}', time: '今天 10:36', star: true },
    { cat: 'link', title: 'GitHub PR 合并指引', app: 'safari', appName: 'Safari', detail: 'github.co…ull/75421', time: '昨天 05:49', star: true },
    { cat: 'code', title: 'SwiftUI 状态管理实践小结', app: 'xcode', appName: 'Xcode', detail: '使用 @O…', time: '昨天 13:01' },
    { cat: 'file', title: 'NookClip-1.4.dmg', app: 'finder', appName: '访达', detail: '12.4 MB', time: '昨天 09:12' },
    { cat: 'text', title: '欢迎使用 NookClip — 30 秒上手指南', app: 'nook', appName: 'NookClip', detail: '核心…', time: '10月13日', star: true },
    { cat: 'link', title: 'Rust 并发无锁设计', app: 'vscode', appName: 'Visual Studio Code', detail: '…', time: '10月12日' },
  ];

  // ---------------------------------------------------------------- 面板 HTML
  function iconFor(r) {
    if (r.cat === 'color' && r.swatch) return `<div class="pilldot" style="background:${r.swatch};width:17px;height:17px;border-radius:5px"></div>`;
    const map = { text: I.doc, image: I.image, link: I.link, code: I.code, json: I.json, file: I.doc, color: I.doc };
    return map[r.cat] || I.doc;
  }

  function rowsHTML(rows) {
    return rows.map((r, i) => `
      <div class="row" data-row="${i}">
        <div class="tick">${I.check}</div>
        <div class="ico" style="background:${CAT_COLOR[r.cat] || '#0A84FF'}">${iconFor(r)}
          <div class="badge"><img src="${APP_ICON(r.app)}" alt=""></div>
        </div>
        <div class="mid">
          <div class="t1">${r.title}</div>
          <div class="t2"><span>${r.appName}</span><span class="dot">·</span><span>${r.detail}</span>${r.sensitive ? '<span class="tag">私密</span>' : ''}${(r.tags || []).map(t => `<span class="rtag">#${t}</span>`).join('')}</div>
        </div>
        <div class="meta">
          ${r.cat === 'json' ? '<span class="tag json">JSON</span>' : ''}
          ${r.star ? `<span class="star">${I.star}</span>` : ''}
          <span class="time">${r.time}</span>
        </div>
      </div>`).join('');
  }

  function panelHTML(rows, opts) {
    const o = Object.assign({}, opts);
    return `
    <div class="panel">
      <div class="p-main">
        <div class="col-list">
          <div class="search">
            ${I.search}
            ${o.searchChips || ''}
            <div class="ph" ${o.searchVal ? 'style="display:none"' : ''}>${o.searchPlaceholder || '搜索剪贴板或应用…'}</div>
            ${o.searchVal || ''}
            <div class="skbd">⌘F</div>
          </div>
          ${o.filterPanel || ''}
          <div class="chips">
            <div class="chip on"><span>▦</span><span>全部</span><span class="cnt">72</span></div>
            <div class="chip">★<span>收藏</span></div>
            <div class="chip">▤<span>文本</span></div>
            <div class="chip">◎<span>链接</span><span class="car">▾</span></div>
          </div>
          <div class="grouphead"><span>今天 · 60</span><span class="car">▾</span></div>
          <div class="rows">${rowsHTML(rows)}</div>
          <div class="p-footer">
            <span class="k"><span class="kbd">↑</span><span class="kbd">↓</span></span> 选择
            <span class="k"><span class="kbd">⏎</span></span> 粘贴
            <span class="k"><span class="kbd">⌘</span><span class="kbd">[</span><span class="kbd">]</span></span> 分类
            <span style="margin-left:auto">?</span>
          </div>
          <div class="batchbar">
            <div class="l1"><span>已选中 <b class="bnum">0</b> 项</span><span class="hint">⇧↑/⇧↓ 扩展选择</span><span class="hint">Esc 退出</span></div>
            <div class="l2">
              <div class="bmain"><span>合并粘贴</span><span class="kb">⏎</span></div>
              <div class="bico" data-act="stack">${I.stack}</div>
              <div class="bico" data-act="tag">${I.tag}</div>
              <div class="bico" data-act="del">${I.trash}</div>
            </div>
          </div>
        </div>
        <div class="col-preview">
          <div class="toolbar">
            <img class="srcimg" src="${APP_ICON(o.srcApp || 'notes')}" alt="">
            <span class="srcname">${o.srcName || '备忘录'}</span>
            <span class="sep"></span>
            <span class="meta2">${o.srcMeta || '今天 11:42 · 复制 2 次'}</span>
            <span class="sp"></span>
            ${o.showScrub === false ? '' : `<div class="tbtn" data-act="scrub">${I.scrub}<span>脱敏粘贴</span><span class="kb">⌃⏎</span></div>`}
            ${o.showPin === false ? '' : `<div class="tbtn" data-act="pin">${I.pin}<span>钉在屏幕</span><span class="kb">⌘P</span></div>`}
            <div class="ticon" data-act="star">${I.star}</div>
            <div class="ticon" data-act="del">${I.trash}</div>
          </div>
          <div class="banner-slot">
            <div class="banner">
              ${I.shield ? `<span class="sh">${I.shield}</span>` : ''}
              <span class="bt">检测到 <b style="color:#FF9F0A">6</b> 处敏感信息（API 密钥、数据库连接串、邮箱…）</span>
              <span class="sp"></span>
              <span class="act" data-act="banner">脱敏粘贴<span class="kb">⌃⏎</span></span>
            </div>
          </div>
          <div class="pbody">
            <div class="pv-default"></div>
            <div class="pv-batch">
              <div style="font-size:15px;font-weight:600;color:#F5F5F7">已选中 <b class="bnum2">0</b> 项</div>
              <div style="font-size:12px;color:#A1A1A6;margin-top:6px">按 ⏎ 合并成一条粘贴 · 或用工具栏的顺序粘贴</div>
            </div>
          </div>
        </div>
      </div>
    </div>`;
  }

  // ---------------------------------------------------------------- 目标应用窗口
  function docHTML(title, sub) {
    return `
    <div class="docwin">
      <div class="dtitle">
        <div class="dots"><div class="d" style="background:#FF5F57"></div><div class="d" style="background:#FEBC2E"></div><div class="d" style="background:#28C840"></div></div>
        <div class="tname">${title}</div>
        <div style="width:39px"></div>
      </div>
      <div class="dbody"></div>
    </div>`;
  }

  // ---------------------------------------------------------------- 顺序粘贴浮窗
  function pillHTML(rows) {
    const list = rows.map((r, i) => `
      <div class="prow" data-prow="${i}">
        <div class="play">${I.play}</div>
        <div class="mk"></div>
        <div class="tt">${r}</div>
        <div class="pb">粘贴</div>
      </div>`).join('');
    return `
    <div class="pill">
      <div class="ph">
        <div class="rec"></div>
        <div class="prog"></div>
        <div class="done" style="display:none">${I.check}<span>已贴完成</span></div>
        <div class="sp"></div>
        <div class="obadge">顺序</div>
        <div class="x">${I.x}</div>
      </div>
      <div class="plist">${list}</div>
      <div class="pf">
        <span class="kbd">⏎</span><span class="kbd">Esc</span>
        <span class="sp2"></span>
        <span class="hint">高亮即下一条 · ⌘V 贴出 · 点行跳转 · Esc 结束</span>
      </div>
    </div>`;
  }

  // ---------------------------------------------------------------- 贴条
  function noteHTML() {
    return `
    <div class="note">
      <div class="nh">
        <div class="src">备忘录</div>
        <div class="tbadge">文本</div>
        <div class="sp"></div>
        <div class="ctrl">
          <div class="ib" data-nact="edit">${I.pencil}</div>
          <div class="ib" data-nact="copy">${I.copy}</div>
          <div class="ib" data-nact="save">${I.save}</div>
          <div class="pct">96%</div>
          <div class="slider"><div class="track"></div><div class="fill"></div><div class="knob"></div></div>
          <div class="ib" data-nact="lock">${I.unlock}</div>
          <div class="ib" data-nact="collapse">${I.up}</div>
          <div class="ib" data-nact="close">${I.x}</div>
        </div>
      </div>
      <div class="nb"></div>
      <div class="grip" style="left:4px">${I.gripL}</div>
      <div class="grip" style="right:4px;justify-content:flex-end">${I.gripR}</div>
      <div class="nfoot"><div class="nhint"></div></div>
      <div class="lockchip">${I.lock}</div>
    </div>`;
  }

  // ---------------------------------------------------------------- 舞台通用件
  function shellHTML() {
    return `
      <div class="wall"></div>
      <div class="menubar">
        <div class="ml"><span></span><span class="appicon">N</span><span class="bold">NookClip</span><span>编辑</span><span>视图</span><span>历史</span><span>窗口</span><span>帮助</span></div>
        <div class="mr"><span class="extra"></span><span>周五 11:42</span></div>
      </div>
      <div class="world"></div>
      <div class="toast"></div>
      <div class="caption">
        <div class="num">01</div>
        <div class="tt"></div>
        <div class="dd"></div>
      </div>
      <div class="brand"><div class="bi">N</div><span>NookClip · 剪贴板里的三层效率</span></div>`;
  }

  /** 相机：{cx,cy,s} → world transform */
  function camera(world) {
    return (cam) => {
      world.style.transform =
        `translate(${(W / 2 - cam.cx * cam.s).toFixed(2)}px, ${(H / 2 - cam.cy * cam.s).toFixed(2)}px) scale(${cam.s.toFixed(4)})`;
    };
  }

  /** 关键帧插值：frames = [{t, cx, cy, s, e?}] */
  function camTrack(frames) {
    return (t) => {
      if (t <= frames[0].t) return frames[0];
      for (let i = 1; i < frames.length; i += 1) {
        if (t <= frames[i].t) {
          const a = frames[i - 1], b = frames[i];
          const p = E[b.e || 'io'](clamp((t - a.t) / (b.t - a.t)));
          return { cx: lerp(a.cx, b.cx, p), cy: lerp(a.cy, b.cy, p), s: lerp(a.s, b.s, p) };
        }
      }
      return frames[frames.length - 1];
    };
  }

  function measureWorld(world, els) {
    const prev = world.style.transform;
    world.style.transform = 'none';
    const wr = world.getBoundingClientRect();
    const out = {};
    for (const k in els) {
      if (!els[k]) continue;
      const r = els[k].getBoundingClientRect();
      out[k] = { x: r.left - wr.left + r.width / 2, y: r.top - wr.top + r.height / 2, w: r.width, h: r.height };
    }
    world.style.transform = prev;
    return out;
  }

  function makeCursor(stage) {
    const el = document.createElement('div');
    el.className = 'cursor';
    el.innerHTML = `<svg viewBox="0 0 24 24" width="22" height="22"><path d="M5.6 2.1 19 12.6l-6.6.7 3.5 7.4-2.9 1.4-3.4-7.5L5.2 18.5Z" fill="#ffffff" stroke="#15161a" stroke-width="1.15" stroke-linejoin="round"/></svg><div class="rip"></div>`;
    stage.appendChild(el);
    const rip = el.querySelector('.rip');
    return {
      el,
      at(x, y, op) { el.style.transform = `translate(${x}px,${y}px)`; el.style.opacity = op; },
      ripple(p) {
        if (p <= 0 || p >= 1) { rip.style.opacity = 0; return; }
        rip.style.opacity = (1 - p) * 0.85;
        rip.style.transform = `scale(${0.45 + p * 2.2})`;
      },
    };
  }

  function makeKeyToast(stage) {
    const el = document.createElement('div');
    el.className = 'keytoast';
    stage.appendChild(el);
    return {
      el,
      // pos 可选：{ x, y } 视口坐标，给了就贴在目标上方当 tooltip，否则居顶
      show(keys, label, p, pos) {
        if (p <= 0) { el.style.opacity = 0; return; }
        el.innerHTML = keys.map((k) => `<div class="big">${k}</div>`).join('') + `<div class="lbl">${label}</div>`;
        el.style.opacity = p;
        if (pos) {
          el.style.left = `${pos.x}px`;
          el.style.top = `${pos.y}px`;
          el.style.transform = `translate(-50%, -100%) translateY(${(1 - p) * 8}px) scale(${0.96 + p * 0.04})`;
        } else {
          el.style.left = '50%';
          el.style.top = '96px';
          el.style.transform = `translate(-50%, 0) translateY(${(1 - p) * 8}px) scale(${0.96 + p * 0.04})`;
        }
      },
    };
  }

  function makeToast(stage) {
    const el = document.createElement('div');
    el.className = 'toast';
    stage.appendChild(el);
    return {
      el,
      show(html, p) {
        if (p <= 0) { el.style.opacity = 0; return; }
        el.innerHTML = html;
        el.style.opacity = p;
        el.style.transform = `translateX(-50%) translateY(${(1 - p) * 10}px)`;
      },
    };
  }

  function setCaption(cap, num, title, desc, p) {
    cap.style.opacity = p;
    if (p <= 0) return;
    cap.querySelector('.num').textContent = num;
    cap.querySelector('.tt').textContent = title;
    cap.querySelector('.dd').innerHTML = desc;
    cap.style.transform = `translateX(-50%) translateY(${(1 - p) * 10}px)`;
  }

  // ---------------------------------------------------------------- 场景 A：顺序粘贴
  function buildA(stage) {
    const DUR = 9200;
    stage.innerHTML = shellHTML();
    const world = q(stage, '.world');
    const wall = q(stage, '.wall');
    world.innerHTML = panelHTML(ROWS_A, {
      srcApp: 'notes', srcName: '备忘录', srcMeta: '今天 11:42 · 复制 2 次',
    }) + docHTML('NookClip 1.4 发布说明.md', '');
    world.style.transformOrigin = '0 0';

    const panelEl = q(world, '.panel');
    const rows = qa(world, '.rows .row');
    const batchbar = q(world, '.batchbar');
    const bnum = q(world, '.bnum');
    const bnum2 = q(world, '.bnum2');
    const pvBatch = q(world, '.pv-batch');
    const pvDefault = q(world, '.pv-default');
    const stackBtn = q(world, '.bico[data-act="stack"]');
    const doc = q(world, '.docwin');
    const docBody = q(world, '.dbody');
    const pill = document.createElement('div');
    pill.innerHTML = pillHTML([
      '【NookClip 1.4 更新】',
      '新增：顺序粘贴栈（⌥⏎）',
      '新增：语义脱敏粘贴（⌃⏎）',
      '新增：屏幕置顶贴条（⌘P）',
    ]);
    const pillEl = pill.firstElementChild;
    stage.appendChild(pillEl);
    pillEl.style.left = `${(W - 340) / 2}px`;
    pillEl.style.top = 'auto';
    pillEl.style.bottom = '150px';

    // 预览默认内容（选中第一条）
    pvDefault.innerHTML = '<div class="bodyhead">【NookClip 1.4 更新】</div><div class="plain"><b>1.4 版三件事：</b><br>顺序粘贴栈 · 语义脱敏粘贴 · 屏幕置顶贴条<br><br>下面三条会依次贴进发布说明里。</div>';

    const prowEls = qa(pillEl, '.prow');
    const progEl = q(pillEl, '.prog');
    const doneEl = q(pillEl, '.done');
    const recEl = q(pillEl, '.rec');
    const orderEl = q(pillEl, '.obadge');
    const closeBtn = q(pillEl, '.x');

    const cur = makeCursor(stage);
    const keyToast = makeKeyToast(stage);
    const toast = makeToast(stage);
    const caption = q(stage, '.caption');
    const cam = camera(world);

    // 选中行 & 顺序粘贴按钮的世界坐标
    const M = measureWorld(world, {
      stack: stackBtn,
      row0: rows[0], row1: rows[1], row2: rows[2], row3: rows[3],
      batch: q(world, '.bmain'),
    });

    const camAt = camTrack([
      { t: 0, cx: 520, cy: 424, s: 1.07 },
      { t: 700, cx: 512, cy: 428, s: 0.985 },
      { t: 2600, cx: 505, cy: 440, s: 0.99 },
      { t: 3250, cx: 560, cy: 470, s: 0.965 },
      { t: 4050, cx: 1466, cy: 462, s: 0.96 },
      { t: 9200, cx: 1470, cy: 458, s: 0.965 },
    ]);

    const SEL = [0, 1, 2, 3];
    const SEL_T0 = 900, SEL_DT = 300;

    // 每次粘贴的时间片
    const CYCLE_T0 = 4150, CYCLE_DT = 860;

    const LINES = [
      '【NookClip 1.4 更新】',
      '新增：顺序粘贴栈（⌥⏎）',
      '新增：语义脱敏粘贴（⌃⏎）',
      '新增：屏幕置顶贴条（⌘P）',
    ];

    function apply(t) {
      const camNow = camAt(t);
      cam(camNow);

      // 世界整体入场
      world.style.opacity = 1;

      // ---------------- 多选
      let selCount = 0;
      for (let i = 0; i < 4; i += 1) {
        const p = tw(t, SEL_T0 + i * SEL_DT, 220, 'out');
        const on = p > 0;
        rows[i].classList.toggle('multi', on);
        if (on) {
          selCount += 1;
          rows[i].classList.remove('sel');
          const tick = q(rows[i], '.tick');
          tick.style.opacity = p;
          tick.style.transform = `translateY(-50%) scale(${lerp(0.4, 1, E.back(clamp(p)))})`;
          rows[i].style.background = `rgba(10,132,255,${0.10 + 0.16 * p})`;
        } else {
          q(rows[i], '.tick').style.opacity = 0;
          rows[i].style.background = 'transparent';
        }
      }
      if (t < SEL_T0) { rows[0].classList.add('sel'); rows[0].classList.remove('multi'); rows[0].style.background = ''; }

      // 面板落位（开场即在场，不做全黑淡入）
      const enter = tw(t, 0, 420, 'out');
      panelEl.style.transform = `translateY(${(1 - enter) * -14}px) scale(${lerp(0.985, 1, enter)})`;

      // 点完「顺序粘贴」后主面板收起，屏幕上只剩浮窗与目标应用
      const pgA = 1 - tw(t, 3200, 560, 'io');
      panelEl.style.opacity = pgA;
      panelEl.style.transform = `translateY(${(1 - enter) * -14}px) scale(${lerp(0.985, 1, enter) * lerp(1, 0.975, 1 - pgA)})`;

      // 批量栏升起
      const bb = tw(t, 2000, 260, 'out');
      batchbar.style.height = `${bb * 54}px`;
      batchbar.style.flexBasis = `${bb * 54}px`;
      batchbar.style.opacity = bb;
      // 批量模式下快捷键提示行让位（真实 App 里两者不同时出现）
      q(world, '.p-footer').style.opacity = 1 - bb;
      bnum.textContent = selCount;
      bnum2.textContent = selCount;
      pvBatch.style.opacity = bb;
      pvDefault.style.opacity = 1 - bb;

      // 顺序粘贴按钮 hover + 点击
      const hovStack = tw(t, 2650, 180, 'out') * (1 - tw(t, 3050, 160, 'out') * 0.35);
      stackBtn.style.background = `rgba(255,255,255,${0.075 * hovStack})`;
      stackBtn.style.color = hovStack > 0.4 ? '#F5F5F7' : '#A1A1A6';
      const pressStack = win(t, 2980, 200, 60, 140);
      stackBtn.style.transform = `scale(${1 - pressStack * 0.12})`;

      // ---------------- 光标轨迹（世界坐标 → 视口坐标）
      const toV = (p) => ({
        x: (p.x - camNow.cx) * camNow.s + W / 2,
        y: (p.y - camNow.cy) * camNow.s + H / 2,
      });
      // 路径：行0 → 行3 → 顺序粘贴按钮 → 淡出
      const c1 = toV(M.row0), c2 = toV(M.row3), c3 = toV(M.stack);
      const pm1 = tw(t, 560, 500, 'io');
      const pm2 = tw(t, 1050, 900, 'io');
      const pm3 = tw(t, 2350, 620, 'io');
      let cxp = lerp(c1.x, c2.x, pm1);
      let cyp = lerp(c1.y - 28, c2.y + 4, pm1);
      if (pm1 >= 1) { cxp = lerp(c2.x, c3.x, pm2); cyp = lerp(c2.y + 4, c3.y, pm2); }
      if (pm2 >= 1) { cxp = c3.x; cyp = c3.y; }
      if (pm3 > 0) { cxp = lerp(c2.x, c3.x, pm3); cyp = lerp(c2.y + 4, c3.y, pm3); }
      const cOp = Math.min(tw(t, 520, 320, 'out'), 1 - tw(t, 3350, 420, 'out'));
      cur.at(cxp, cyp, cOp);
      cur.ripple((t - 2990) / 420);

      // 键帽提示：点击前的 ⌥⏎（位置贴着「顺序粘贴」按钮）
      const tipStack = win(t, 2100, 900, 200, 260);

      // ---------------- 目标应用窗口
      const dp = tw(t, 3100, 480, 'out');
      doc.style.opacity = dp;
      doc.style.transform = `translateY(${(1 - dp) * -18}px) scale(${0.98 + dp * 0.02})`;
      doc.style.left = '1080px';
      doc.style.top = '150px';
      doc.style.width = '780px';
      doc.style.height = '620px';

      // 文档内容：粘贴累积
      let txt = '';
      let caretOn = false;
      for (let i = 0; i < 4; i += 1) {
        const cs = CYCLE_T0 + i * CYCLE_DT;
        const tp = tw(t, cs + 190, 250, 'out'); // 打字进度
        const before = LINES.slice(0, i).join('\n');
        if (i === 0) {
          if (t >= cs + 190) caretOn = true;
        } else if (t >= cs + 190) caretOn = true;
        if (t < cs + 190) {
          txt = LINES.slice(0, i).join('\n') + (i > 0 ? '\n' : '');
          caretOn = false;
        } else {
          const line = LINES[i];
          const n = Math.round(line.length * tp);
          const head = i > 0 ? LINES.slice(0, i).join('\n') + '\n' : '';
          txt = head + line.slice(0, n);
          caretOn = tp >= 1 ? t : true;
        }
      }
      if (t < CYCLE_T0) { txt = ''; caretOn = false; }
      const blink = Math.floor(t / 520) % 2 === 0;
      docBody.innerHTML = '<div class="hd" style="display:none"></div>' +
        txt.split('\n').map((l, i) =>
          `<div style="min-height:1.9em">${escapeHtml(l)}${caretOn && blink && i === txt.split('\n').length - 1 ? '<span class="caret"></span>' : ''}</div>`
        ).join('');
      if (!txt) docBody.innerHTML = '<span class="caret"></span>';

      // ---------------- 浮窗
      const pp = tw(t, 3700, 340, 'out');
      const pOut = tw(t, 8100, 420, 'out');
      pillEl.style.opacity = pp * (1 - pOut);
      pillEl.style.transform = `translateY(${(1 - pp) * 14 + pOut * 10}px) scale(${lerp(0.96, 1, pp)})`;

      // 行入场（spring）
      for (let i = 0; i < 4; i += 1) {
        const sp = tw(t, 3760 + i * 70, 460, 'spring');
        prowEls[i].style.opacity = clamp(sp);
        prowEls[i].style.transform = `scale(${lerp(0.92, 1, sp)})`;
      }

      // 粘贴进度状态
      let done = 0, current = 0;
      for (let i = 0; i < 4; i += 1) {
        const cs = CYCLE_T0 + i * CYCLE_DT;
        const isDone = t >= cs + 620;
        const isCur = !isDone && t >= cs - 120 && t < cs + 620;
        const rowEl = prowEls[i];
        const mk = q(rowEl, '.mk');
        const tt = q(rowEl, '.tt');
        const pb = q(rowEl, '.pb');
        const playEl = q(rowEl, '.play svg');
        if (isDone) {
          done = i + 1;
          mk.innerHTML = I.check;
          mk.style.color = '#30D158';
          tt.style.color = '#6E6E73';
          tt.style.textDecoration = 'line-through';
          tt.style.textDecorationColor = 'rgba(110,110,115,.8)';
          tt.style.fontWeight = '400';
          playEl.style.opacity = 0;
          pb.style.opacity = 0;
          rowEl.style.background = 'transparent';
          const d0 = tw(t, cs + 620, 240, 'out');
          mk.style.transform = `scale(${lerp(1.5, 1, d0)})`;
        } else {
          mk.innerHTML = String(i + 1);
          mk.style.color = isCur ? '#388BFD' : '#6E6E73';
          mk.style.transform = 'scale(1)';
          tt.style.textDecoration = 'none';
          tt.style.color = isCur ? '#F5F5F7' : '#A1A1A6';
          tt.style.fontWeight = isCur ? '600' : '400';
          playEl.style.opacity = isCur ? 1 : 0;
          pb.style.opacity = 1;
          pb.style.color = '#6E6E73';
          rowEl.style.background = 'transparent';
          if (isCur) current = i;
        }
      }
      progEl.textContent = `已贴 ${done} / 4`;
      progEl.style.display = done >= 4 ? 'none' : 'block';
      doneEl.style.display = done >= 4 ? 'flex' : 'none';
      recEl.style.opacity = 0.35 + 0.65 * (0.5 + 0.5 * Math.sin((t / 900) * Math.PI * 2));
      recEl.style.display = done >= 4 ? 'none' : 'block';
      orderEl.style.opacity = 1;

      // 键帽提示：先 ⌥⏎（贴着「顺序粘贴」按钮），之后每次 ⏎ 贴下一条
      const cyc = CYCLE_T0 + current * CYCLE_DT;
      const kp = done < 4 ? win(t, cyc - 150, 420, 90, 150) : 0;
      if (kp > 0) {
        keyToast.show(['⏎'], `贴出第 ${current + 1} 条`, kp);
      } else if (tipStack > 0) {
        keyToast.show(['⌥', '⏎'], '顺序粘贴', tipStack);
      } else {
        keyToast.show([], '', 0);
      }

      // 完成后的提示
      toast.show(`<span class="ok">${I.check}</span><span>4 条已按复制顺序贴完</span>`, win(t, 7740, 1500, 220, 320));

      // 字幕
      setCaption(caption, '01', '顺序粘贴 · ⌥⏎',
        '一次框选多条，按复制顺序一条条贴完', 0);
      // 两段字幕切换
      const capA = { num: '01', title: '顺序粘贴 · ⌥⏎', desc: '一次框选多条，贴在别的应用里' };
      const capB = { num: '01', title: '顺序粘贴 · ⌥⏎', desc: '按复制顺序贴完 · 不用来回切换' };
      const swap = tw(t, 4250, 500, 'io');
      if (swap < 1) {
        setCaption(caption, capA.num, capA.title, capA.desc, 1);
      } else {
        setCaption(caption, capB.num, capB.title, capB.desc, 1);
      }
      caption.style.opacity = Math.min(tw(t, 620, 400, 'out'), 1);
      wall.style.filter = '';
    }

    function escapeHtml(s) {
      return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    return { duration: DUR, apply };
  }

  // ---------------------------------------------------------------- 场景 B：脱敏粘贴
  function buildB(stage) {
    const DUR = 8200;
    stage.innerHTML = shellHTML();
    const world = q(stage, '.world');
    world.innerHTML = panelHTML(ROWS_B, {
      srcApp: 'terminal', srcName: 'Terminal', srcMeta: '今天 11:26 · 复制 1 次',
    }) + docHTML('部署说明.md', '');
    world.style.transformOrigin = '0 0';

    const rows = qa(world, '.rows .row');
    const bannerSlot = q(world, '.banner-slot');
    const banner = q(world, '.banner');
    const scrubBtn = q(world, '.tbtn[data-act="scrub"]');
    const pinBtn = q(world, '.tbtn[data-act="pin"]');
    const pvDefault = q(world, '.pv-default');
    const doc = q(world, '.docwin');
    const docBody = q(world, '.dbody');
    const cur = makeCursor(stage);
    const keyToast = makeKeyToast(stage);
    const toast = makeToast(stage);
    const caption = q(stage, '.caption');
    const cam = camera(world);
    doc.style.left = '1080px';
    doc.style.top = '150px';
    doc.style.width = '780px';
    doc.style.height = '620px';

    // 原始 env 文本 + 敏感片段
    const RAW = [
      { pre: 'DATABASE_URL=postgres://deploy:', hit: 'Xk9#mQ2v', ph: '<DB_PASSWORD_1>', post: '@10.20.30.40:5432/prod', hits: [{ v: '10.20.30.40', ph: '<IP_1>' }] },
      { pre: 'OPENAI_API_KEY=', hit: 'sk-proj-8fj2Kq9wLm3Tn7Bv', ph: '<API_KEY_1>', post: '' },
      { pre: 'SMTP_USER=', hit: 'zhang.wei@nookclip.dev', ph: '<EMAIL_1>', post: '' },
      { pre: 'ADMIN_PHONE=', hit: '138 6492 7503', ph: '<PHONE_1>', post: '' },
      { pre: 'S3_BUCKET=s3://', hit: 'nookclip-prod-backup', ph: '<BUCKET_1>', post: '/' },
    ];
    // 只有前 5 行敏感；第一行两处
    const HEAD = '# prod.env（部署配置备份）';

    function htmlOf(mode) {
      // mode: 'raw' | 'hit' | 'ph'
      const mk = (tok) => {
        if (mode === 'ph') return `<span class="tok ph">${tok.ph}</span>`;
        if (mode === 'hit') return `<span class="tok hit">${escapeHtml(tok.hit)}</span>`;
        return escapeHtml(tok.hit);
      };
      const lines = RAW.map((r) => {
        const post = r.post;
        let postHtml = escapeHtml(post);
        if (r.hits && r.hits.length) {
          for (const h of r.hits) {
            const sub = mode === 'ph'
              ? `<span class="tok ph">${h.ph}</span>`
              : mode === 'hit'
                ? `<span class="tok hit">${escapeHtml(h.v)}</span>`
                : escapeHtml(h.v);
            postHtml = postHtml.replace(escapeHtml(h.v), sub);
          }
        }
        return escapeHtml(r.pre) + mk(r) + postHtml;
      });
      return `<div class="bodyhead" style="font-family:var(--mono);font-size:15px;margin-bottom:10px;color:#F5F5F7">${escapeHtml(HEAD)}</div><div class="bodytext">${lines.join('<br>')}</div>`;
    }

    function redactedText() {
      return [HEAD].concat(RAW.map((r) => {
        let post = r.post;
        if (r.hits) for (const h of r.hits) post = post.split(h.v).join(h.ph);
        return r.pre + r.ph + post;
      })).join('\n');
    }

    const M = measureWorld(world, {
      row2: qa(world, '.rows .row')[2],
      scrub: scrubBtn,
      banner: banner,
    });

    const camAt = camTrack([
      { t: 0, cx: 520, cy: 424, s: 1.07 },
      { t: 640, cx: 512, cy: 428, s: 0.985 },
      { t: 2900, cx: 520, cy: 440, s: 0.99 },
      { t: 3900, cx: 1466, cy: 462, s: 0.96 },
      { t: 8200, cx: 1470, cy: 458, s: 0.965 },
    ]);

    const T_SELECT = 1250;
    const T_BANNER = 1720;
    const T_CLICK = 2760;
    const T_HIT = 3060;
    const T_PH = 3760;
    const T_DOC = 4200;

    function apply(t) {
      const camNow = camAt(t);
      cam(camNow);
      world.style.opacity = 1;

      // 点完「脱敏粘贴」后主面板收起
      const pgB = 1 - tw(t, 3040, 560, 'io');
      q(world, '.panel').style.opacity = pgB;
      q(world, '.panel').style.transform = `scale(${lerp(1, 0.975, 1 - pgB)})`;

      const toV = (p) => ({ x: (p.x - camNow.cx) * camNow.s + W / 2, y: (p.y - camNow.cy) * camNow.s + H / 2 });

      // 选中行（点第 3 条）
      const selP = tw(t, T_SELECT, 220, 'out');
      for (let i = 0; i < rows.length; i += 1) {
        const on = i === 2 && t >= T_SELECT;
        const prevOn = i === 0 && t < T_SELECT;
        rows[i].classList.toggle('sel', on || prevOn);
        rows[i].style.background = '';
      }

      // 预览：默认欢迎 → env 原文
      const swap = tw(t, T_SELECT + 140, 300, 'out');
      pvDefault.style.opacity = 1 - swap;
      if (t < T_SELECT + 140) {
        pvDefault.innerHTML = '<div class="bodyhead" style="font-family:-apple-system,sans-serif;font-size:19px">欢迎使用 NookClip</div><div class="plain"><b>30 秒上手：</b>⌘⇧V 呼出面板 · ↑↓ 选条目 · ⏎ 粘贴<br>⌥⏎ 纯文本 · ⌃⏎ 脱敏 · ⌘P 钉在屏幕</div>';
      } else {
        pvDefault.style.opacity = 0;
      }

      // 脱敏预览层（独立 DOM，插入在 pbody 里）
      let pvScrub = q(world, '.pv-scrub');
      if (!pvScrub) {
        pvScrub = document.createElement('div');
        pvScrub.className = 'pv-scrub';
        pvScrub.style.position = 'absolute';
        pvScrub.style.inset = '14px 16px';
        q(world, '.pbody').appendChild(pvScrub);
      }
      pvScrub.style.opacity = swap;

      // 三阶段渲染：原文 → 高亮 → 占位符
      if (t < T_HIT) {
        pvScrub.innerHTML = htmlOf('raw');
      } else if (t < T_PH) {
        pvScrub.innerHTML = htmlOf('hit');
      } else {
        // 逐个替换：每 88ms 把一处琥珀高亮换成绿色占位符
        const seqs = [
          { v: 'Xk9#mQ2v', ph: '<DB_PASSWORD_1>' },
          { v: 'sk-proj-8fj2Kq9wLm3Tn7Bv', ph: '<API_KEY_1>' },
          { v: 'zhang.wei@nookclip.dev', ph: '<EMAIL_1>' },
          { v: '138 6492 7503', ph: '<PHONE_1>' },
          { v: '10.20.30.40', ph: '<IP_1>' },
          { v: 'nookclip-prod-backup', ph: '<BUCKET_1>' },
        ];
        let html = htmlOf('hit');
        const stepMs = 88;
        for (let i = 0; i < seqs.length; i += 1) {
          const p = tw(t, T_PH + i * stepMs, 200, 'out');
          if (p >= 1) {
            html = html.split(`<span class="tok hit">${escapeHtml(seqs[i].v)}</span>`).join(`<span class="tok ph">${seqs[i].ph}</span>`);
          }
        }
        pvScrub.innerHTML = html;
      }

      // 横幅
      const bp = tw(t, T_BANNER, 320, 'out');
      bannerSlot.style.height = `${bp * 36}px`;
      banner.style.opacity = bp;
      banner.style.transform = `translateY(${(1 - bp) * -6}px)`;

      // 按钮 hover / 按下
      const hov = tw(t, 2180, 200, 'out') * (1 - tw(t, 3060, 200, 'out') * 0.3);
      scrubBtn.classList.toggle('hov', hov > 0.35);
      const press = win(t, T_CLICK - 20, 220, 60, 150);
      scrubBtn.style.transform = `scale(${1 - press * 0.06})`;

      // 光标
      const c1 = toV(M.row2), c2 = toV(M.scrub);
      const pm1 = tw(t, 300, 620, 'io');
      const pm2 = tw(t, 1500, 620, 'io');
      let cxp, cyp;
      if (t < 1500) { cxp = lerp(M.row2.x - 240, c1.x - 60, pm1); cyp = lerp(c1.y + 120, c1.y + 2, pm1); }
      else { cxp = lerp(c1.x - 60, c2.x, pm2); cyp = lerp(c1.y + 2, c2.y, pm2); }
      const cOp = Math.min(tw(t, 260, 300, 'out'), 1 - tw(t, 3120, 400, 'out'));
      cur.at(cxp, cyp, cOp);
      cur.ripple((t - T_CLICK) / 420);

      keyToast.show(['⌃', '⏎'], '语义脱敏粘贴', win(t, 2320, 900, 180, 240));

      // 目标窗口
      const dp = tw(t, T_DOC - 1100, 520, 'out');
      doc.style.opacity = dp;
      doc.style.transform = `translateY(${(1 - dp) * -18}px)`;
      const rtext = redactedText();
      const tp = tw(t, T_DOC - 700, 880, 'out');
      const shown = rtext.slice(0, Math.round(rtext.length * tp));
      const lines = shown.split('\n');
      docBody.innerHTML = lines.map((l, i) =>
        `<div style="min-height:1.9em">${escapeHtml(l).replace(/&lt;([A-Z_0-9]+)&gt;/g, '<span style="background:rgba(48,209,88,.14);color:#4ADE80;border-radius:3px;padding:0 2px;font-weight:600">&lt;$1&gt;</span>')}</div>`
      ).join('');
      q(world, '.dtitle .tname').textContent = '部署说明.md';

      toast.show(`<span class="ok">${I.check}</span><span>已脱敏 6 处后粘贴 · 明文从未进入系统剪贴板</span>`,
        win(t, T_DOC + 1000, 1800, 240, 320));

      // 字幕
      const A = { num: '02', title: '语义脱敏粘贴 · ⌃⏎', desc: '把配置发给别人前，先把密钥和手机号藏起来' };
      const B = { num: '02', title: '语义脱敏粘贴 · ⌃⏎', desc: '映射表只留在内存里 · 闲置 30 分钟自动清除' };
      const s = tw(t, T_DOC + 700, 520, 'io');
      const c = s < 1 ? A : B;
      setCaption(caption, c.num, c.title, c.desc, Math.min(tw(t, 560, 400, 'out'), 1), s < 1 ? A : B);
    }

    function setCaption(el, num, title, desc, p) {
      el.style.opacity = p;
      if (p <= 0) return;
      el.querySelector('.num').textContent = num;
      el.querySelector('.tt').textContent = title;
      el.querySelector('.dd').textContent = desc;
      el.style.transform = `translateX(-50%) translateY(${(1 - p) * 10}px)`;
    }

    function escapeHtml(s) {
      return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    return { duration: DUR, apply };
  }

  // ---------------------------------------------------------------- 场景 C：贴条窗
  function buildC(stage) {
    const DUR = 9000;
    stage.innerHTML = shellHTML();
    const world = q(stage, '.world');
    world.innerHTML = panelHTML(ROWS_C, {
      srcApp: 'notes', srcName: '备忘录', srcMeta: '今天 11:29 · 复制 2 次',
    });
    world.style.transformOrigin = '0 0';

    const panelEl = q(world, '.panel');
    const pinBtn = q(world, '.tbtn[data-act="pin"]');
    const scrubBtn = q(world, '.tbtn[data-act="scrub"]');
    q(world, '.banner').style.display = 'none';
    q(world, '.banner-slot').style.height = '0px';
    const rows = qa(world, '.rows .row');
    rows[0].classList.add('sel');

    const CHEAT = `进阶效率快捷键速查卡

粘贴
⌥⏎   纯文本粘贴
⌘⏎   贴完保持面板
⇧↑↓  扩展多选

导航
⌘[ ⌘]  切换分类
⌘T    跳转时间分组

整理
⌘S   收藏豁免清理
⌘R   为条目设别名
⌘⌫   删除　⌘Z 撤销`;

    q(world, '.pv-default').innerHTML =
      `<div class="bodyhead">进阶效率快捷键速查卡（常驻备忘）</div><div class="bodytext">${CHEAT.split('\n').map(escapeHtml).join('<br>')}</div>`;

    // 背景应用窗口（靶子）：让"钉在屏幕上"有明确的层次参照
    const bgAppWrap = document.createElement('div');
    bgAppWrap.innerHTML = `<div class="bgapp">
      <div class="dtitle">
        <div class="dots"><div class="d" style="background:#FF5F57"></div><div class="d" style="background:#FEBC2E"></div><div class="d" style="background:#28C840"></div></div>
        <div class="tname">产品周会 · 待办.md</div>
        <div style="width:39px"></div>
      </div>
      <div class="dbody">
        <h2>本周待办</h2>
        <p>1 · 把 1.4 的发布说明补完，重点写清三个新功能的入口快捷键。</p>
        <p>2 · 主面板列表在 310pt 宽度下的四个文字按钮会挤成省略号，改成一主三辅。</p>
        <p>3 · 贴条默认不透明度统一成 96%，⌥+滚轮可以随时调。</p>
        <div class="ln" style="width:86%"></div>
        <div class="ln" style="width:72%"></div>
        <div class="ln" style="width:79%"></div>
        <p style="margin-top:14px;color:#6E6E73">下次同步：周五 15:00</p>
      </div>
    </div>`;
    const bgapp = bgAppWrap.firstElementChild;
    world.appendChild(bgapp);
    bgapp.style.left = '620px';
    bgapp.style.top = '40px';
    bgapp.style.width = '780px';
    bgapp.style.height = '700px';

    // 贴条（世界元素，浮在背景应用之上）
    const noteWrap = document.createElement('div');
    noteWrap.innerHTML = noteHTML();
    const noteEl = noteWrap.firstElementChild;
    world.appendChild(noteEl);
    noteEl.style.left = '780px';
    noteEl.style.top = '118px';
    noteEl.style.width = '340px';
    q(noteEl, '.nb').textContent = CHEAT;

    const cur = makeCursor(stage);
    const keyToast = makeKeyToast(stage);
    const toast = makeToast(stage);
    const caption = q(stage, '.caption');
    const cam = camera(world);

    const M = measureWorld(world, {
      pin: pinBtn,
      scrub: scrubBtn,
      row0: rows[0],
    });

    const camAt = camTrack([
      { t: 0, cx: 520, cy: 424, s: 1.07 },
      { t: 640, cx: 512, cy: 428, s: 0.985 },
      { t: 1500, cx: 560, cy: 440, s: 0.97 },
      { t: 2500, cx: 760, cy: 400, s: 0.86 },
      { t: 3400, cx: 955, cy: 400, s: 1.30 },
      { t: 9000, cx: 960, cy: 396, s: 1.32 },
    ]);

    const T_CLICK_PIN = 1560;
    const T_HOVER = 3000;
    const T_PCT = 3850;
    const T_SLIDER = 4000;
    const T_DRAG0 = 4250, T_DRAG1 = 5300;
    const T_RETRACT = 6000;
    const T_LOCK = 6300;
    const T_CHIP = 7900;

    const NOTE_FINAL_LEFT = 780, NOTE_TOP = 118, NOTE_W = 340;

    function apply(t) {
      const camNow = camAt(t);
      cam(camNow);
      world.style.opacity = 1;

      const toV = (p) => ({ x: (p.x - camNow.cx) * camNow.s + W / 2, y: (p.y - camNow.cy) * camNow.s + H / 2 });

      // 面板按下「钉在屏幕」
      const hovPin = tw(t, 980, 200, 'out') * (1 - tw(t, 1700, 260, 'out') * 0.4);
      pinBtn.classList.toggle('hov', hovPin > 0.35);
      const press = win(t, T_CLICK_PIN - 20, 220, 60, 150);
      pinBtn.style.transform = `scale(${1 - press * 0.06})`;

      // 面板退后（贴条已上屏，主面板让位但仍在）
      const pg = 1 - tw(t, 2450, 900, 'io') * 1.0;
      panelEl.style.opacity = pg;
      const back = 1 - pg;
      panelEl.style.transform = `scale(${lerp(1, 0.97, back)}) translateX(${lerp(0, -90, back)}px)`;

      // 背景应用窗口入场 + 跟着面板一起退后
      const bgp = tw(t, 1900, 620, 'out');
      bgapp.style.opacity = bgp;
      bgapp.style.transform = `translateY(${(1 - bgp) * -14}px) scale(${lerp(0.98, 1, bgp)})`;

      // 贴条入场
      const np = tw(t, T_CLICK_PIN + 60, 620, 'spring');
      const outP = 0;
      noteEl.style.opacity = clamp(np) * (1 - outP);
      noteEl.style.transform =
        `translateY(${(1 - clamp(np)) * -16}px) scale(${lerp(0.94, 1, clamp(np))})`;
      noteEl.style.left = `${NOTE_FINAL_LEFT}px`;
      noteEl.style.top = `${NOTE_TOP}px`;

      // 悬停 → 控制条
      const hovNote = tw(t, T_HOVER, 220, 'out') * (1 - tw(t, 7820, 260, 'out'));
      q(noteEl, '.ctrl').style.opacity = hovNote;
      q(noteEl, '.grip').style.opacity = hovNote * 0.55;
      qa(noteEl, '.grip')[1].style.opacity = hovNote * 0.55;

      // 不透明度：96% → 62%（整窗 alpha，和真实 NSWindow.alphaValue 一致）
      const dragP = tw(t, T_DRAG0, T_DRAG1 - T_DRAG0, 'io');
      const opacityVal = lerp(0.96, 0.68, dragP);
      noteEl.style.opacity = clamp(np) * opacityVal;
      // 材质感：浓度越低，背后的内容越糊（macOS 面板材质的近似）
      noteEl.style.backdropFilter = `blur(${((1 - opacityVal) * 16).toFixed(2)}px)`;

      const expanded = t >= T_SLIDER && t < T_RETRACT;
      const pctEl = q(noteEl, '.pct');
      const sliderEl = q(noteEl, '.slider');
      const ex = tw(t, T_SLIDER, 180, 'out') * (1 - tw(t, T_RETRACT, 200, 'out'));
      pctEl.style.display = ex > 0.5 ? 'none' : 'flex';
      sliderEl.style.display = ex > 0.02 ? 'flex' : 'none';
      sliderEl.style.opacity = ex;
      sliderEl.style.transform = `scale(${lerp(0.92, 1, ex)})`;
      const sT = tw(t, T_SLIDER, 180, 'out');
      pctEl.textContent = `${Math.round(opacityVal * 100)}%`;
      if (ex > 0.02) {
        const frac = (opacityVal - 0.2) / 0.8;
        const knobX = frac * 78;
        q(sliderEl, '.fill').style.width = `${knobX}px`;
        q(sliderEl, '.knob').style.left = `${knobX}px`;
      }

      // 锁 / 点击穿透
      const lockOn = t >= T_LOCK;
      q(noteEl, '.ctrl .ib[data-nact="lock"]').innerHTML = lockOn ? I.lock : I.unlock;
      q(noteEl, '.ctrl .ib[data-nact="lock"]').style.color = lockOn ? '#388BFD' : '#A1A1A6';
      const hintEl = q(noteEl, '.nhint');
      const hintP = t >= T_LOCK && t < T_CHIP ? 1 : 0;
      hintEl.style.opacity = hintP;
      hintEl.textContent = '点右上角小锁，或按 ⌥⌘P 取消穿透';

      const chipEl = q(noteEl, '.lockchip');
      const cp = tw(t, T_CHIP, 320, 'back');
      chipEl.style.opacity = t >= T_CHIP ? 1 : 0;
      chipEl.style.transform = `scale(${lerp(0.6, 1, clamp(cp))})`;

      // 光标
      const cPin = toV(M.pin);
      const cNote = toV({ x: NOTE_FINAL_LEFT + NOTE_W / 2, y: NOTE_TOP + 150 });
      const cPct = toV({ x: NOTE_FINAL_LEFT + NOTE_W - 96, y: NOTE_TOP + 14 });
      const cLock = toV({ x: NOTE_FINAL_LEFT + NOTE_W - 22, y: NOTE_TOP + 14 });
      const pm1 = tw(t, 240, 620, 'io');
      let cxp = lerp(cPin.x + 240, cPin.x, pm1);
      let cyp = lerp(cPin.y + 160, cPin.y, pm1);
      if (t > 1800) { cxp = lerp(cPin.x, cNote.x, tw(t, 1850, 900, 'io')); cyp = lerp(cPin.y, cNote.y, tw(t, 1850, 900, 'io')); }
      if (t > T_HOVER) { cxp = lerp(cNote.x, cPct.x, tw(t, T_HOVER, 700, 'io')); cyp = lerp(cNote.y, cPct.y, tw(t, T_HOVER, 700, 'io')); }
      if (t > T_PCT + 100) {
        const d = tw(t, T_DRAG0, T_DRAG1 - T_DRAG0, 'io');
        const kx = lerp(0, (0.62 - 0.2) / 0.8 * 78, d);
        cxp = cPct.x + kx - 39 + 6;
        cyp = cPct.y + 2;
      }
      if (t > 6000) { cxp = lerp(cxp, cLock.x, tw(t, 6050, 500, 'io')); cyp = lerp(cyp, cLock.y, tw(t, 6050, 500, 'io')); }
      if (t > 7900) {
        // 穿透后光标从贴条上穿过（不再改变悬停态）
        const p = tw(t, 7900, 900, 'io');
        cxp = lerp(cLock.x, cLock.x - 300, p);
        cyp = lerp(cLock.y, cLock.y + 210, p);
      }
      const cOp = Math.min(tw(t, 200, 300, 'out'), 1 - tw(t, 8700, 300, 'out'));
      cur.at(cxp, cyp, cOp);
      cur.ripple((t - T_CLICK_PIN) / 420);
      cur.ripple(Math.max(cur.ripple0 || 0, (t - T_LOCK) / 420));

      keyToast.show(['⌘', 'P'], '钉在屏幕', win(t, 900, 900, 180, 240));
      toast.show(`<span class="ok">${I.check}</span><span>已钉在屏幕上 · 跨桌面常驻</span>`, win(t, 1950, 1400, 220, 320));

      const A = { num: '03', title: '屏幕置顶贴条 · ⌘P', desc: '把一段文字钉在屏幕上，随时抬头就能看' };
      const B = { num: '03', title: '屏幕置顶贴条 · ⌘P', desc: '浓度可调 · 可折叠 · 可点击穿透' };
      const s = tw(t, 3200, 520, 'io');
      setCaption(caption, A.num, A.title, s < 1 ? A.desc : B.desc, Math.min(tw(t, 540, 400, 'out'), 1));
      caption.style.opacity = Math.min(tw(t, 540, 400, 'out'), 1);
    }

    function setCaption(el, num, title, desc, p) {
      el.style.opacity = p;
      if (p <= 0) return;
      el.querySelector('.num').textContent = num;
      el.querySelector('.tt').textContent = title;
      el.querySelector('.dd').textContent = desc;
      el.style.transform = `translateX(-50%) translateY(${(1 - p) * 10}px)`;
    }

    function escapeHtml(s) {
      return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    return { duration: DUR, apply };
  }

  // ---------------------------------------------------------------- 场景 D：类型与标签筛选
  const ROWS_D = [
    { cat: 'code', title: 'LockFreeQueue 无锁并发队列', app: 'vscode', appName: 'VS Code', detail: 'Rust · 24 行', time: '今天 11:30', tags: ['后端'] },
    { cat: 'code', title: 'DBPool 连接池配置 (WAL + FTS5)', app: 'xcode', appName: 'Xcode', detail: 'Rust · 12 行', time: '今天 11:15', tags: ['后端', '数据库'] },
    { cat: 'text', title: 'Tailwind CSS 色彩系统规范', app: 'figma', appName: 'Figma', detail: '设计文档', time: '今天 11:05', tags: ['前端', '设计'] },
    { cat: 'code', title: 'SwiftUI 自定义拖动悬浮面板', app: 'xcode', appName: 'Xcode', detail: 'Swift · 85 行', time: '今天 10:48', tags: ['前端'] },
    { cat: 'link', title: 'GitHub PR: FTS5 拼音分词优化', app: 'safari', appName: 'Safari', detail: 'github.com/…', time: '今天 10:20', tags: ['后端', '文档'] },
    { cat: 'text', title: 'API Key 凭据存储安全备忘', app: 'notes', appName: '备忘录', detail: 'AES-256-GCM', time: '昨天 17:30', tags: ['安全'] },
    { cat: 'image', title: '架构分层关系示意图.png', app: 'screenshot', appName: '截图', detail: '1280 × 720', time: '昨天 15:10', tags: ['文档'] },
  ];

  function buildD(stage) {
    const DUR = 8600;
    stage.innerHTML = shellHTML();
    const world = q(stage, '.world');

    const filterPanelSnippet = `
      <div class="filter-panel">
        <div class="filter-sec-title"><span>按类型</span><span style="opacity:0.6;font-size:9.5px">8 槽位固定</span></div>
        <div class="type-grid">
          <div class="type-tile on" data-type="all"><div class="t-ico" style="background:#0A84FF">${I.doc}</div><span class="t-name">全部</span></div>
          <div class="type-tile" data-type="fav"><div class="t-ico" style="background:#FFD60A">${I.star}</div><span class="t-name">收藏</span></div>
          <div class="type-tile" data-type="text"><div class="t-ico" style="background:#0A84FF">${I.doc}</div><span class="t-name">文本</span></div>
          <div class="type-tile" data-type="link"><div class="t-ico" style="background:#30D158">${I.link}</div><span class="t-name">链接</span></div>
          <div class="type-tile" data-type="code"><div class="t-ico" style="background:#5E5CE6">${I.code}</div><span class="t-name">代码</span></div>
          <div class="type-tile" data-type="file"><div class="t-ico" style="background:#FF9F0A">${I.doc}</div><span class="t-name">文件</span></div>
          <div class="type-tile" data-type="color"><div class="t-ico" style="background:#FF6482"><div class="pilldot" style="background:#FF6482;width:10px;height:10px;border-radius:2px"></div></div><span class="t-name">色值</span></div>
          <div class="type-tile" data-type="sec"><div class="t-ico" style="background:#FF9F0A">${I.lock}</div><span class="t-name">私密</span></div>
        </div>
        <div class="filter-div"></div>
        <div class="filter-sec-title"><span>按标签</span><span style="opacity:0.6;font-size:9.5px">横切筛选</span></div>
        <div class="tag-flow">
          <div class="tag-pill" data-tag="backend"><span class="hash">#</span><span>后端</span><span class="cnt">3</span></div>
          <div class="tag-pill" data-tag="frontend"><span class="hash">#</span><span>前端</span><span class="cnt">2</span></div>
          <div class="tag-pill" data-tag="docs"><span class="hash">#</span><span>文档</span><span class="cnt">2</span></div>
          <div class="tag-pill" data-tag="sec"><span class="hash">#</span><span>安全</span><span class="cnt">1</span></div>
          <div class="tag-pill" data-tag="design"><span class="hash">#</span><span>设计</span><span class="cnt">1</span></div>
        </div>
      </div>`;

    const searchChipsSnippet = `
      <div class="search-chips">
        <span class="embed-chip chip-code" style="display:none"><span style="display:inline-flex">${I.code}</span><span>代码</span><span class="x">✕</span></span>
        <span class="embed-chip tag chip-tag" style="display:none"><span class="hash">#</span><span>后端</span><span class="x">✕</span></span>
      </div>`;

    world.innerHTML = panelHTML(ROWS_D, {
      srcApp: 'vscode', srcName: 'Visual Studio Code', srcMeta: '今天 11:30 · 复制 3 次',
      filterPanel: filterPanelSnippet,
      searchChips: searchChipsSnippet,
      showScrub: false,
    });
    world.style.transformOrigin = '0 0';

    const panelEl = q(world, '.panel');
    const rows = qa(world, '.rows .row');
    const pvDefault = q(world, '.pv-default');
    const filterPanelEl = q(world, '.filter-panel');
    const chipCode = q(world, '.chip-code');
    const chipTag = q(world, '.chip-tag');
    const phEl = q(world, '.search .ph');
    const tileAll = q(world, '.type-tile[data-type="all"]');
    const tileCode = q(world, '.type-tile[data-type="code"]');
    const pillBackend = q(world, '.tag-pill[data-tag="backend"]');

    pvDefault.innerHTML = `
      <div class="bodyhead">LockFreeQueue 无锁并发队列</div>
      <div class="plain" style="margin-bottom:12px">
        <span class="tag" style="background:rgba(94,92,230,.2);color:#9D9BFF;padding:2px 7px;border-radius:4px;font-size:11px;font-weight:600">Rust</span>
        <span class="tag" style="background:rgba(255,255,255,.08);color:#CBD5E1;padding:2px 7px;border-radius:4px;font-size:11px;margin-left:4px">#后端</span>
      </div>
      <div class="bodytext">
<span class="syn-fn">pub struct</span> <span class="syn-key">LockFreeQueue</span>&lt;T&gt; {
    head: <span class="syn-key">AtomicPtr</span>&lt;Node&lt;T&gt;&gt;,
    tail: <span class="syn-key">AtomicPtr</span>&lt;Node&lt;T&gt;&gt;,
}

<span class="syn-fn">impl</span>&lt;T&gt; <span class="syn-key">LockFreeQueue</span>&lt;T&gt; {
    <span class="syn-fn">pub fn</span> <span class="syn-key">new</span>() -&gt; <span class="syn-key">Self</span> {
        <span class="syn-key">Self</span> { head: AtomicPtr::default(), tail: AtomicPtr::default() }
    }
}</div>`;

    rows[0].classList.add('sel');

    const cur = makeCursor(stage);
    const keyToast = makeKeyToast(stage);
    const toast = makeToast(stage);
    const caption = q(stage, '.caption');
    const cam = camera(world);

    const M = measureWorld(world, {
      search: q(world, '.search'),
      tileCode,
      pillBackend,
      row0: rows[0],
    });

    const camAt = camTrack([
      { t: 0, cx: 500, cy: 420, s: 1.05 },
      { t: 900, cx: 480, cy: 390, s: 1.09 },
      { t: 4000, cx: 490, cy: 410, s: 1.08 },
      { t: 8600, cx: 500, cy: 420, s: 1.05 },
    ]);

    function apply(t) {
      const camNow = camAt(t);
      cam(camNow);
      world.style.opacity = 1;

      const enter = tw(t, 0, 400, 'out');
      panelEl.style.transform = `translateY(${(1 - enter) * -12}px) scale(${lerp(0.985, 1, enter)})`;

      // 筛选面板滑出 (600ms 开始)
      const fpP = tw(t, 650, 360, 'out') * (1 - tw(t, 7200, 320, 'out'));
      filterPanelEl.style.opacity = fpP;
      filterPanelEl.style.transform = `translateY(${(1 - fpP) * -8}px)`;

      // 代码槽位激活
      const isCodeOn = t >= 1750 && t < 7200;
      tileCode.classList.toggle('on', isCodeOn);
      tileAll.classList.toggle('on', !isCodeOn);

      // 内嵌代码胶囊
      const codeChipP = tw(t, 1800, 240, 'spring') * (1 - tw(t, 7200, 200, 'out'));
      chipCode.style.display = codeChipP > 0.05 ? 'inline-flex' : 'none';
      chipCode.style.transform = `scale(${lerp(0.5, 1, clamp(codeChipP))})`;

      // 后端标签激活
      const isBackendOn = t >= 3150 && t < 6000;
      pillBackend.classList.toggle('on', isBackendOn);

      // 内嵌后端标签胶囊
      const tagChipP = tw(t, 3200, 240, 'spring') * (1 - tw(t, 6000, 200, 'out'));
      chipTag.style.display = tagChipP > 0.05 ? 'inline-flex' : 'none';
      chipTag.style.transform = `scale(${lerp(0.5, 1, clamp(tagChipP))})`;

      phEl.style.display = (codeChipP > 0.05 || tagChipP > 0.05) ? 'none' : 'block';

      // 行过滤逻辑
      const filterCodeP = tw(t, 1800, 260, 'io') * (1 - tw(t, 7200, 260, 'io'));
      const filterTagP = tw(t, 3200, 260, 'io') * (1 - tw(t, 6000, 260, 'io'));

      // row 2, 4, 5, 6 在代码过滤时折叠
      [2, 4, 5, 6].forEach((idx) => {
        const h = lerp(54, 0, filterCodeP);
        rows[idx].style.height = `${h}px`;
        rows[idx].style.opacity = 1 - filterCodeP;
        rows[idx].style.overflow = 'hidden';
      });

      // row 3 (SwiftUI 前端代码) 在后端标签过滤时折叠
      const h3 = lerp(lerp(54, 0, filterCodeP > 0 ? 0 : 0), 0, filterTagP);
      rows[3].style.height = `${lerp(54, 0, filterTagP)}px`;
      rows[3].style.opacity = 1 - filterTagP;
      rows[3].style.overflow = 'hidden';

      // 光标轨迹
      const toV = (p) => ({
        x: (p.x - camNow.cx) * camNow.s + W / 2,
        y: (p.y - camNow.cy) * camNow.s + H / 2,
      });
      const cSearch = toV(M.search);
      const cCode = toV(M.tileCode);
      const cBack = toV(M.pillBackend);
      const cRow0 = toV(M.row0);

      let cxp = cSearch.x + 80;
      let cyp = cSearch.y + 120;
      if (t > 1000) { cxp = lerp(cxp, cCode.x, tw(t, 1050, 650, 'io')); cyp = lerp(cyp, cCode.y, tw(t, 1050, 650, 'io')); }
      if (t > 2400) { cxp = lerp(cCode.x, cBack.x, tw(t, 2450, 650, 'io')); cyp = lerp(cCode.y, cBack.y, tw(t, 2450, 650, 'io')); }
      if (t > 3800) { cxp = lerp(cBack.x, cRow0.x + 40, tw(t, 3850, 700, 'io')); cyp = lerp(cBack.y, cRow0.y, tw(t, 3850, 700, 'io')); }

      const cOp = Math.min(tw(t, 300, 300, 'out'), 1 - tw(t, 8200, 300, 'out'));
      cur.at(cxp, cyp, cOp);
      cur.ripple((t - 1750) / 380);
      cur.ripple(Math.max(cur.ripple0 || 0, (t - 3150) / 380));

      keyToast.show(['⌘', '↓'], '展开筛选面板', win(t, 600, 750, 150, 200));
      keyToast.show(['⌘', 'L'], '编辑标签', win(t, 4700, 800, 150, 200));
      keyToast.show(['⌫'], '移除标签筛选', win(t, 5800, 750, 150, 200));
      keyToast.show(['Esc'], '分层复位', win(t, 7000, 750, 150, 200));

      toast.show(`<span class="ok">${I.check}</span><span>已为「LockFreeQueue」关联 #后端 标签</span>`, win(t, 4850, 1000, 180, 250));

      const capA = { num: '04', title: '类型与标签筛选 · ⌘↓', desc: '8 槽位固定类型 + 标签横切，组合快速缩窄' };
      const capB = { num: '04', title: '快捷键打标与复位 · ⌘L / ⌫', desc: '⌘L 随时打标 · 退格键 ⌫ / Esc 逐层回退筛选条件' };
      const s = tw(t, 3600, 480, 'io');
      setCaption(caption, capA.num, capA.title, s < 1 ? capA.desc : capB.desc, Math.min(tw(t, 500, 350, 'out'), 1));
    }

    return { duration: DUR, apply };
  }

  // ---------------------------------------------------------------- 场景 E：离线图片文字识别与搜索
  const ROWS_E = [
    { cat: 'image', title: '终端报错截图.png', app: 'screenshot', appName: '截图', detail: '860 × 420', time: '今天 11:10' },
    { cat: 'text', title: 'NookClip 架构演进与设计说明.md', app: 'notes', appName: '备忘录', detail: '核心…', time: '今天 10:45', star: true },
    { cat: 'code', title: 'PostgreSQL 迁移脚本.sql', app: 'vscode', appName: 'VS Code', detail: 'SQL · 12 行', time: '今天 10:30' },
    { cat: 'link', title: 'Rust 官方异步并发指南', app: 'safari', appName: 'Safari', detail: 'rust-lang.org', time: '昨天 18:20' },
    { cat: 'json', title: '配置表 prod.json', app: 'xcode', appName: 'Xcode', detail: 'JSON', time: '昨天 16:15', star: true },
  ];

  function buildE(stage) {
    const DUR = 8800;
    stage.innerHTML = shellHTML();
    const world = q(stage, '.world');

    const searchValSnippet = `<span class="sval" style="display:none"></span><span class="scursor" style="display:none"></span>`;

    world.innerHTML = panelHTML(ROWS_E, {
      srcApp: 'screenshot', srcName: '截图', srcMeta: '今天 11:10 · 860 × 420 PNG',
      searchVal: searchValSnippet,
      showScrub: false,
    });
    world.style.transformOrigin = '0 0';

    const panelEl = q(world, '.panel');
    const rows = qa(world, '.rows .row');
    const pvDefault = q(world, '.pv-default');
    const sValEl = q(world, '.search .sval');
    const sCursorEl = q(world, '.search .scursor');
    const phEl = q(world, '.search .ph');

    rows[0].classList.add('sel');

    pvDefault.innerHTML = `
      <div class="ocr-img-box">
        <div class="ocr-img-terminal">
          <span class="time">[FATAL] 11:09:42 worker-03</span><br>
          <span class="err">DatabasePoolException</span>: Connection pool <span class="term-hl">timeout</span> (15000ms)<br>
          <span style="color:#94A3B8">&nbsp;&nbsp;at Pool.acquireConnection (src/db/pool.rs:142)</span><br>
          <span style="color:#64748B">&nbsp;&nbsp;at Server.handleRequest (src/server.rs:89)</span>
        </div>
        <button class="ocr-livetext-btn">${I.ocr}<span>识别文字</span></button>
      </div>
      <div class="ocr-card">
        <div class="ocr-card-head">
          <div class="tt">${I.ocr}<span>提取文字</span></div>
          <span class="badge ocr-badge">尚未提取</span>
        </div>
        <div class="ocr-body-text" style="font-size:12px;color:#A1A1A6;line-height:1.6">
          尚未提取文字 · 全程在本机离线处理，数据不出设备
        </div>
      </div>`;

    const btnExtract = q(pvDefault, '.ocr-livetext-btn');
    const badgeEl = q(pvDefault, '.ocr-badge');
    const ocrBodyEl = q(pvDefault, '.ocr-body-text');
    const termHlEl = q(pvDefault, '.term-hl');

    const cur = makeCursor(stage);
    const keyToast = makeKeyToast(stage);
    const toast = makeToast(stage);
    const caption = q(stage, '.caption');
    const cam = camera(world);

    const M = measureWorld(world, {
      search: q(world, '.search'),
      btnExtract,
      row0: rows[0],
    });

    const camAt = camTrack([
      { t: 0, cx: 620, cy: 390, s: 1.08 },
      { t: 2600, cx: 630, cy: 400, s: 1.10 },
      { t: 3600, cx: 500, cy: 390, s: 1.06 },
      { t: 8800, cx: 510, cy: 390, s: 1.06 },
    ]);

    function apply(t) {
      const camNow = camAt(t);
      cam(camNow);
      world.style.opacity = 1;

      const enter = tw(t, 0, 400, 'out');
      panelEl.style.transform = `translateY(${(1 - enter) * -12}px) scale(${lerp(0.985, 1, enter)})`;

      // 点击识别文字按钮
      const hovBtn = tw(t, 1200, 300, 'out') * (1 - tw(t, 1750, 100, 'out'));
      btnExtract.style.transform = `scale(${1 - win(t, 1720, 160, 40, 100) * 0.12})`;

      // 识别中状态 (1750 ~ 2500)
      if (t >= 1750 && t < 2550) {
        btnExtract.innerHTML = `${I.ocr}<span>识别中…</span>`;
        badgeEl.textContent = '正在离线识别…';
        badgeEl.style.background = 'rgba(255,159,10,0.18)';
        badgeEl.style.color = '#FF9F0A';
        badgeEl.style.borderColor = 'rgba(255,159,10,0.3)';
      } else if (t >= 2550) {
        btnExtract.innerHTML = `${I.check}<span>已识别</span>`;
        btnExtract.style.background = '#248A3D';
        badgeEl.textContent = '离线 OCR';
        badgeEl.style.background = 'rgba(48,209,88,0.15)';
        badgeEl.style.color = '#30D158';
        badgeEl.style.borderColor = 'rgba(48,209,88,0.26)';

        ocrBodyEl.innerHTML = `
          <div class="ocr-text-box">DatabasePoolException: Connection pool <span class="box-hl">timeout</span> (15000ms)</div>
          <button class="ocr-copy-btn">${I.copy}<span>一键复制识别文字</span></button>`;
      }

      // 搜索框模拟输入 "timeout" (4600 ~ 5800)
      const word = 'timeout';
      if (t >= 4400) {
        phEl.style.display = 'none';
        sValEl.style.display = 'inline';
        sCursorEl.style.display = 'inline-block';
        const typeP = clamp((t - 4600) / 1000);
        const chars = Math.floor(typeP * word.length);
        sValEl.textContent = word.slice(0, chars);
      } else {
        phEl.style.display = 'block';
        sValEl.style.display = 'none';
        sCursorEl.style.display = 'none';
      }

      // 搜索高亮命中 (t >= 5800)
      const isHit = t >= 5800;
      if (isHit) {
        // 隐藏不匹配行
        [1, 2, 3, 4].forEach((idx) => {
          const p = tw(t, 5800, 260, 'io');
          rows[idx].style.height = `${lerp(54, 0, p)}px`;
          rows[idx].style.opacity = 1 - p;
          rows[idx].style.overflow = 'hidden';
        });

        q(rows[0], '.t2').innerHTML = `<span>截图</span><span class="dot">·</span><span>860 × 420</span><span class="rtag" style="background:rgba(255,214,10,.25);color:#FFD60A;font-weight:600">命中 timeout</span>`;

        const termHl = q(pvDefault, '.term-hl');
        if (termHl) termHl.className = 'term-hl hl';
        const boxHl = q(pvDefault, '.box-hl');
        if (boxHl) boxHl.className = 'box-hl hl';
      }

      // 光标
      const toV = (p) => ({
        x: (p.x - camNow.cx) * camNow.s + W / 2,
        y: (p.y - camNow.cy) * camNow.s + H / 2,
      });
      const cBtn = toV(M.btnExtract);
      const cSearch = toV(M.search);

      let cxp = cBtn.x - 120;
      let cyp = cBtn.y + 60;
      if (t > 1000) { cxp = lerp(cxp, cBtn.x, tw(t, 1050, 600, 'io')); cyp = lerp(cyp, cBtn.y, tw(t, 1050, 600, 'io')); }
      if (t > 3200) { cxp = lerp(cBtn.x, cSearch.x + 80, tw(t, 3250, 800, 'io')); cyp = lerp(cBtn.y, cSearch.y, tw(t, 3250, 800, 'io')); }
      if (t > 6800) { cxp = lerp(cSearch.x + 80, cSearch.x + 180, tw(t, 6850, 600, 'io')); cyp = lerp(cSearch.y, cSearch.y + 40, tw(t, 6850, 600, 'io')); }

      const cOp = Math.min(tw(t, 300, 300, 'out'), 1 - tw(t, 8400, 300, 'out'));
      cur.at(cxp, cyp, cOp);
      cur.ripple((t - 1750) / 380);

      toast.show(`<span class="ok">${I.check}</span><span>离线 OCR 提取完成 · 已建全文索引</span>`, win(t, 2580, 1200, 180, 250));
      keyToast.show(['⏎'], '复制提取文本', win(t, 7200, 800, 150, 200));

      const capA = { num: '05', title: '离线图片文字识别 · Vision OCR', desc: '在图片卡片上点「识别文字」，本机离线毫秒级提取文本' };
      const capB = { num: '05', title: '搜图内文字 · SQLite FTS5', desc: '识别结果自动写入全文索引，打字直接搜出截图里的报错' };
      const s = tw(t, 4200, 480, 'io');
      setCaption(caption, capA.num, capA.title, s < 1 ? capA.desc : capB.desc, Math.min(tw(t, 500, 350, 'out'), 1));
    }

    return { duration: DUR, apply };
  }

  // ---------------------------------------------------------------- 入口
  const SCENES = { a: buildA, b: buildB, c: buildC, d: buildD, e: buildE };

  function init() {
    const params = new URLSearchParams(location.search);
    const key = (params.get('scene') || 'a').toLowerCase();
    const build = SCENES[key] || SCENES.a;
    const stage = document.getElementById('stage');
    stage.style.width = W + 'px';
    stage.style.height = H + 'px';
    const scene = build(stage);
    window.__duration = scene.duration;
    window.__seek = (t) => scene.apply(clamp(Number(t) || 0, 0, scene.duration));
    window.__seek(0);
    window.__ready = true;
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
