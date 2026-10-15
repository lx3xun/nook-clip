/**
 * NookClip 落地页交互脚本
 * 涵盖：多语言切换 (i18n)、外观主题切换、产品截图深浅色联动、一键复制构建命令、移动端抽屉菜单
 */

document.addEventListener('DOMContentLoaded', () => {
  // 1. 多语言国际化系统 (i18n)
  initI18n();

  // 2. 外观主题系统管理 (Theme Management)
  const root = document.documentElement;
  const themeToggleBtn = document.getElementById('themeToggleBtn');
  const previewImg = document.getElementById('productPreviewImg');
  const previewBtns = document.querySelectorAll('.preview-mode-btn');

  // 初始化主题：读取本地存储，未设置则采用 auto 跟随系统
  const savedTheme = localStorage.getItem('nookclip-theme');
  if (savedTheme === 'light' || savedTheme === 'dark') {
    setTheme(savedTheme, false);
  } else {
    setTheme('auto', false);
  }

  // 监听系统主题变化（当用户选择 auto 模式时）
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', (e) => {
    if (root.getAttribute('data-theme') === 'auto') {
      syncPreviewWithSystem(e.matches);
    }
  });

  // 主题切换按钮点击
  if (themeToggleBtn) {
    themeToggleBtn.addEventListener('click', () => {
      const current = root.getAttribute('data-theme');
      let nextTheme = 'dark';

      if (current === 'dark') {
        nextTheme = 'light';
      } else if (current === 'light') {
        nextTheme = 'dark';
      } else {
        // 当前是 auto，依据系统偏好反转
        const isSystemDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
        nextTheme = isSystemDark ? 'light' : 'dark';
      }

      setTheme(nextTheme, true);
    });
  }

  function setTheme(theme, persist = true) {
    root.setAttribute('data-theme', theme);
    if (persist) {
      localStorage.setItem('nookclip-theme', theme);
    }

    // 同步更新截图展示
    const effectiveIsDark = (theme === 'dark') ||
      (theme === 'auto' && window.matchMedia('(prefers-color-scheme: dark)').matches);

    updateMockupPreview(effectiveIsDark ? 'dark' : 'light');
  }

  function syncPreviewWithSystem(isDark) {
    updateMockupPreview(isDark ? 'dark' : 'light');
  }

  // 3. 产品交互展示窗模式切换 (Mockup Mode Switcher)
  previewBtns.forEach((btn) => {
    btn.addEventListener('click', () => {
      const mode = btn.getAttribute('data-preview-mode');
      updateMockupPreview(mode);
    });
  });

  function updateMockupPreview(mode) {
    if (!previewImg) return;

    if (mode === 'light') {
      previewImg.src = 'assets/nookclip-light.png';
      previewImg.alt = 'NookClip 浅色模式界面真实截图';
    } else {
      previewImg.src = 'assets/nookclip-dark.png';
      previewImg.alt = 'NookClip 深色模式界面真实截图';
    }

    // 更新 Tab 按钮激活态
    previewBtns.forEach((btn) => {
      const btnMode = btn.getAttribute('data-preview-mode');
      const isActive = btnMode === mode;
      btn.classList.toggle('is-active', isActive);
      btn.setAttribute('aria-checked', isActive ? 'true' : 'false');
    });
  }

  // 4. 一键复制源码构建命令 (Copy Command)
  const copyBuildCmdBtn = document.getElementById('copyBuildCmdBtn');
  if (copyBuildCmdBtn) {
    const commandText = 'git clone https://github.com/lx3xun/nook-clip.git && cd nook-clip && zsh scripts/build.sh app --universal';
    const copyTextSpan = copyBuildCmdBtn.querySelector('.copy-text');

    copyBuildCmdBtn.addEventListener('click', async () => {
      try {
        if (navigator.clipboard && window.isSecureContext) {
          await navigator.clipboard.writeText(commandText);
        } else {
          // 降级使用传统方法
          const textarea = document.createElement('textarea');
          textarea.value = commandText;
          textarea.style.position = 'fixed';
          textarea.style.left = '-9999px';
          document.body.appendChild(textarea);
          textarea.select();
          document.execCommand('copy');
          document.body.removeChild(textarea);
        }

        // 成功反馈状态
        copyBuildCmdBtn.classList.add('copied');
        const currentLang = document.documentElement.lang || 'zh-Hans';
        const dict = (window.I18N_DATA && window.I18N_DATA[currentLang]) || {};
        if (copyTextSpan) copyTextSpan.textContent = dict.copied_cmd || '已复制！';

        setTimeout(() => {
          copyBuildCmdBtn.classList.remove('copied');
          if (copyTextSpan) copyTextSpan.textContent = dict.copy_cmd || '复制';
        }, 2000);
      } catch (err) {
        console.error('复制命令失败:', err);
      }
    });
  }

  // 5. 移动端抽屉菜单 (Mobile Drawer Navigation)
  const mobileMenuBtn = document.getElementById('mobileMenuBtn');
  const mobileMenu = document.getElementById('mobileMenu');

  if (mobileMenuBtn && mobileMenu) {
    mobileMenuBtn.addEventListener('click', () => {
      const isExpanded = mobileMenuBtn.getAttribute('aria-expanded') === 'true';
      const nextState = !isExpanded;

      mobileMenuBtn.setAttribute('aria-expanded', String(nextState));
      mobileMenu.hidden = !nextState;
    });

    // 点击链接后自动收起菜单
    const mobileLinks = mobileMenu.querySelectorAll('.mobile-nav-link');
    mobileLinks.forEach((link) => {
      link.addEventListener('click', () => {
        mobileMenu.hidden = true;
        mobileMenuBtn.setAttribute('aria-expanded', 'false');
      });
    });
  }

  // 6. 多语言初始化实现
  function initI18n() {
    if (!window.I18N_DATA) return;

    const langMenuBtn = document.getElementById('langMenuBtn');
    const langDropdown = document.getElementById('langDropdown');
    const langOptions = document.querySelectorAll('.lang-option');
    const currentLangLabel = document.getElementById('currentLangLabel');

    // 优先读取 URL query 参数 (?lang=en / ?lang=zh-Hant / ?lang=zh-Hans)
    const urlParams = new URLSearchParams(window.location.search);
    const paramLang = urlParams.get('lang');

    let initialLang = 'zh-Hans';
    if (paramLang && window.I18N_DATA[normalizeLang(paramLang)]) {
      initialLang = normalizeLang(paramLang);
    } else {
      const savedLang = localStorage.getItem('nookclip-lang');
      if (savedLang && window.I18N_DATA[savedLang]) {
        initialLang = savedLang;
      } else {
        // 自动识别系统偏好语言
        const navLang = navigator.language || '';
        if (/zh-TW|zh-HK|zh-MO|zh-Hant/i.test(navLang)) {
          initialLang = 'zh-Hant';
        } else if (/zh/i.test(navLang)) {
          initialLang = 'zh-Hans';
        } else {
          initialLang = 'en';
        }
      }
    }

    applyLanguage(initialLang, false);

    // 桌面端语言下拉菜单交互
    if (langMenuBtn && langDropdown) {
      langMenuBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        const isHidden = langDropdown.hidden;
        langDropdown.hidden = !isHidden;
        langMenuBtn.setAttribute('aria-expanded', String(isHidden));
      });

      document.addEventListener('click', (e) => {
        if (!langMenuBtn.contains(e.target) && !langDropdown.contains(e.target)) {
          langDropdown.hidden = true;
          langMenuBtn.setAttribute('aria-expanded', 'false');
        }
      });
    }

    // 语言选项点击事件（包含桌面端下拉与移动端按钮）
    langOptions.forEach((btn) => {
      btn.addEventListener('click', () => {
        const targetLang = btn.getAttribute('data-lang');
        applyLanguage(targetLang, true);

        if (langDropdown) {
          langDropdown.hidden = true;
          if (langMenuBtn) langMenuBtn.setAttribute('aria-expanded', 'false');
        }
      });
    });

    function normalizeLang(lang) {
      if (/zh-TW|zh-HK|zh-Hant/i.test(lang)) return 'zh-Hant';
      if (/zh/i.test(lang)) return 'zh-Hans';
      if (/en/i.test(lang)) return 'en';
      return lang;
    }

    function applyLanguage(lang, persist = true) {
      const dict = window.I18N_DATA[lang];
      if (!dict) return;

      if (persist) {
        localStorage.setItem('nookclip-lang', lang);
      }

      document.documentElement.lang = lang;
      document.title = dict.meta_title;
      const metaDesc = document.querySelector('meta[name="description"]');
      if (metaDesc) metaDesc.content = dict.meta_desc;

      if (currentLangLabel) {
        currentLangLabel.textContent = dict.lang_short;
      }

      // 遍历更新所有 data-i18n 元素
      document.querySelectorAll('[data-i18n]').forEach((el) => {
        const key = el.getAttribute('data-i18n');
        if (dict[key] !== undefined) {
          el.innerHTML = dict[key];
        }
      });

      // 同步所有选项按钮的 active 状态
      langOptions.forEach((btn) => {
        const isActive = btn.getAttribute('data-lang') === lang;
        btn.classList.toggle('is-active', isActive);
      });
    }
  }
});
