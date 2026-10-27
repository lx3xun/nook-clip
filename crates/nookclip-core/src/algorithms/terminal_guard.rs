//! 终端安全粘贴护栏（Terminal Safe-Paste）
//!
//! 解决的问题：把命令粘进终端时，「末尾多余的换行」会让命令一落即执行；
//! 多行命令、`sudo`、`rm -rf` 这类内容在用户还没看清时就已经跑起来了。
//!
//! 分工：本模块只做**纯判定**（是不是终端、有没有风险、安全文本长什么样），
//! 零副作用、不碰剪贴板。弹窗确认、写入剪贴板、模拟 ⌘V 全部留在客户端
//! （macOS Swift / Windows Tauri），两端共用同一套规则，避免行为漂移。
//!
//! 两档保护：
//! 1. 静默档：单行普通命令带末尾回车 → 只提示、不弹窗，去掉末尾回车后粘贴，
//!    命令停在光标处等用户自己按回车（`strips_trailing_newline == true`）。
//! 2. 确认档：多行命令或命中高危词 → `requires_confirmation == true`，
//!    客户端必须弹窗让用户看到完整内容后再决定（安全粘贴 / 原样粘贴 / 取消）。

use regex::Regex;
use std::sync::LazyLock;

/// 已知独立终端、SSH 客户端与终端工作台应用的 Bundle ID。
///
/// 匹配策略分三层：
/// 1. `TERMINAL_BUNDLE_IDS`：主流终端、SSH 客户端与终端优先工作台精确匹配；
/// 2. `matches_terminal_keywords`：按 Bundle ID 与应用显示名称做终端特征词兜底，
///    新装小众终端无需发版即可自动纳入保护；
/// 3. `INTEGRATED_TERMINAL_BUNDLE_IDS`：VS Code、Cursor、Xcode、JetBrains 等带内置终端的
///    IDE 与 AI 编程工具（可通过设置页开关独立控制是否纳入拦截）。
pub const TERMINAL_BUNDLE_IDS: &[&str] = &[
    // macOS 自带
    "com.apple.Terminal",
    "org.macosforge.xquartz.X11",
    // iTerm2
    "com.googlecode.iterm2",
    "com.googlecode.iterm2-beta",
    "com.googlecode.iterm2.nightly",
    // Otty
    "io.appmakes.otty",
    // Orca
    "com.stablyai.orca",
    "com.orca",
    // Warp（正式版 / 预览版 / 老 ID）
    "dev.warp.Warp-Stable",
    "dev.warp.Warp",
    "dev.warp.Warp-Preview",
    "com.warp.Warp",
    // Ghostty
    "com.mitchellh.ghostty",
    // Alacritty
    "io.alacritty",
    "org.alacritty",
    // kitty
    "net.kovidgoyal.kitty",
    // WezTerm
    "com.github.wez.wezterm",
    // Wave Terminal
    "dev.waveterm.Wave",
    "sh.wave",
    // Rio
    "com.raphaelamorim.rio",
    // Contour
    "org.contour-terminal.contour",
    // Tabby
    "org.tabby",
    "org.tabby.Tabby",
    "org.eugeny.tabby",
    // Hyper
    "co.zeit.hyper",
    "com.hyper.Hyper",
    // Termius（官网 / App Store / DMG 变体）
    "com.termius.mac",
    "com.termius-dmg.mac",
    "pro.termius.mac",
    // Prompt / Blink
    "com.panic.Prompt",
    "com.panic.Prompt3",
    "ee.tatu.Blink",
    "sh.blink.blink",
    // 跨平台 SSH / 运维终端
    "com.lemonmojo.RoyalTSX.App",
    "com.vandyke.SecureCRT",
    "com.finalshell",
    "cn.finalshell.FinalShell",
    "finalshell",
    "kingToolbox.WindTerm",
    "fi.kk.WindTerm",
    "org.electerm.electerm",
    "com.electerm.electerm",
    "org.extraterm.extraterm",
    "com.electron.extraterm",
    "com.github.Swordfish90.cool-retro-term",
    "com.emtec.zoc8",
    "com.emtec.zoc7",
    "me.baye.ServerCat",
    "com.ishell.app",
    "cn.ishell.app",
    "cn.xterminal.app",
    "com.xterminal.app",
    "io.coressh.shell",
    "io.coressh.shell-setapp",
    "net.macterm.MacTerm",
    "com.github.railsware.upterm",
    "io.fig.terminal",
    // 容器 / 虚拟机控制台
    "dev.kdrag0n.MacVirt",
    "com.utmapp.UTM",
    "com.docker.docker",
];

/// 带内置终端面板的 IDE 与 AI 编程工具 Bundle ID。
pub const INTEGRATED_TERMINAL_BUNDLE_IDS: &[&str] = &[
    // VS Code 系列
    "com.microsoft.VSCode",
    "com.microsoft.VSCodeInsiders",
    "com.visualstudio.code.oss",
    "com.vscodium",
    // Cursor / Windsurf / Trae / Zed
    "com.todesktop.230313mzl4w4u92",
    "com.cursor.Cursor",
    "com.exafunction.windsurf",
    "com.codeium.windsurf",
    "com.trae.app",
    "cn.trae.app",
    "com.bytedance.trae",
    "dev.zed.Zed",
    "dev.zed.Zed-Preview",
    // AI 编程桌面端
    "com.deepseek.dsh",
    "dev.webcodex.desktop",
    "com.tencent.workbuddy.mac",
    // Apple Xcode / 编辑器
    "com.apple.dt.Xcode",
    "com.panic.Nova",
    "com.sublimetext.4",
    "com.sublimetext.3",
    "io.lapce",
];

/// Bundle ID 或应用名称中一旦出现即可判定为终端的子串特征词（全小写）。
const TERMINAL_SUBSTRING_KEYWORDS: &[&str] = &[
    "terminal",
    "iterm",
    "otty",
    "waveterm",
    "ghostty",
    "alacritty",
    "wezterm",
    "termius",
    "finalshell",
    "windterm",
    "securecrt",
    "electerm",
    "extraterm",
    "royaltsx",
    "xterminal",
    "macterm",
    "coressh",
    "servercat",
    "mobaxterm",
    "xshell",
    "putty",
    "konsole",
    "urxvt",
    "rxvt",
    "tilix",
    "guake",
    "yakuake",
    "zellij",
    "tmux",
    "cool-retro-term",
];

/// 按 `.` / `-` / `_` / 空格分词后精确命中的短词（避免短词作为普通单词子串误判）。
const TERMINAL_TOKEN_KEYWORDS: &[&str] = &[
    "warp",
    "kitty",
    "tabby",
    "orca",
    "rio",
    "contour",
    "xterm",
    "ishell",
    "zoc",
    "blink",
    "prompt",
    "prompt3",
    "upterm",
];

/// 高危内容分类。`key()` 是与客户端约定的稳定标识（本地化文案由客户端提供）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TerminalHazard {
    /// 多行命令（去掉末尾回车后仍跨行，粘进终端会连续执行前几行）
    Multiline,
    /// 提权执行
    Sudo,
    /// 递归强制删除
    RmRecursiveForce,
    /// 格式化文件系统
    Mkfs,
    /// 直接写块设备 / dd 镜像
    DiskWrite,
    /// 下载即执行（curl | sh 之类）
    PipeToShell,
    /// 把权限放开到 777
    ChmodWideOpen,
    /// git 强制推送（会覆盖远端历史）
    GitForcePush,
    /// 破坏性 SQL（DROP TABLE / TRUNCATE）
    SqlDestructive,
    /// fork 炸弹
    ForkBomb,
    /// 关机 / 重启
    PowerControl,
}

impl TerminalHazard {
    /// 稳定标识：客户端拿它查本地化文案，**不要随意改名**（跨端契约）。
    pub fn key(self) -> &'static str {
        match self {
            TerminalHazard::Multiline => "multiline",
            TerminalHazard::Sudo => "sudo",
            TerminalHazard::RmRecursiveForce => "rm_rf",
            TerminalHazard::Mkfs => "mkfs",
            TerminalHazard::DiskWrite => "disk_write",
            TerminalHazard::PipeToShell => "pipe_to_shell",
            TerminalHazard::ChmodWideOpen => "chmod_777",
            TerminalHazard::GitForcePush => "git_force_push",
            TerminalHazard::SqlDestructive => "sql_drop",
            TerminalHazard::ForkBomb => "fork_bomb",
            TerminalHazard::PowerControl => "power_control",
        }
    }
}

/// 一次「要不要拦」的完整判定结果。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TerminalPasteAssessment {
    /// 目标应用是不是终端（否 = 调用方应完全忽略本结果）
    pub is_terminal: bool,
    /// 是否需要弹窗确认；false 且 `strips_trailing_newline` 为 true 时走静默档
    pub requires_confirmation: bool,
    /// 命中的高危分类（按固定顺序，去重）
    pub hazards: Vec<TerminalHazard>,
    /// 去掉末尾回车后剩余的非空行数（1 = 单行）
    pub line_count: u32,
    /// 「安全粘贴」用的文本：去掉末尾所有换行；多行时再用 ` && ` 串成一行。
    /// 这样整段内容只是被填进终端的输入行，用户自己按回车才会执行。
    pub single_line_text: String,
    /// 仅去掉末尾换行的文本（保留原有换行结构；确认弹窗里的预览与「原样粘贴」用）
    pub safe_text: String,
    /// 多行内容能否可靠合并成一行（含 heredoc / 续行反斜杠 / 行尾管道时不能，
    /// 硬合并会改变语义）。false 时 `single_line_text` 退化为仅去末尾换行。
    pub can_merge_single_line: bool,
    /// 原文末尾确实有换行（静默档据此弹一句轻提示）
    pub strips_trailing_newline: bool,
}

impl TerminalPasteAssessment {
    /// 非终端目标：原样放行，客户端不需要做任何处理。
    fn passthrough(text: &str) -> Self {
        Self {
            is_terminal: false,
            requires_confirmation: false,
            hazards: Vec::new(),
            line_count: count_command_lines(text),
            single_line_text: text.to_string(),
            safe_text: text.to_string(),
            can_merge_single_line: false,
            strips_trailing_newline: false,
        }
    }
}

// MARK: - 正则（静态编译，粘贴路径上不重复构建）

/// `sudo` 独立词（`sudoers`、`/etc/sudoers` 不算）
static SUDO_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\bsudo\b").unwrap());

/// 递归 + 强制删除：`-rf` / `-fr` / `-Rf` / `-r -f` / `--recursive --force` / `find ... -delete`。
/// `rm -r dir`、`rm file` 这类不带 force 的删除不拦（日常高频，拦了全是噪音）。
static RM_RF_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)\brm\s+(?:-[a-z]*(?:r[a-z]*f|f[a-z]*r)|-[a-z]*r\b[^\n]*\s-[a-z]*f\b|-[a-z]*f\b[^\n]*\s-[a-z]*r\b|--recursive\s+--force|--force\s+--recursive)|\bfind\b[^\n]+\s-delete\b",
    )
    .unwrap()
});

static MKFS_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\bmkfs(?:\.\w+)?\b").unwrap());

/// 直接写块设备：`> /dev/sda`、`of=/dev/disk2`、`dd ... if=`
static DISK_WRITE_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(?:>\s*/dev/(?:sd|disk|rdisk|nvme)|\bof=/dev/|\bdd\s+[^\n]*\bif=)").unwrap()
});

/// 下载即执行：`curl ... | sh` / `wget ... | sudo bash` / `... | python3`
static PIPE_TO_SHELL_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)\b(?:curl|wget)\b[^\n|]*\|\s*(?:sudo\s+)?(?:ba|z|k|da)?sh\b|\b(?:curl|wget)\b[^\n|]*\|\s*(?:python3?|perl|ruby)\b",
    )
    .unwrap()
});

/// `chmod 777` / `chmod -R 777`（含 `0777` 写法）
static CHMOD_777_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)\bchmod\s+(?:-R\s+)?0?777\b").unwrap());

/// `git push --force` / `git push -f` / `git reset --hard` / `git clean -fd`。
/// 注意：`--force-with-lease` 是安全写法，调用前会先把它从文本里剔除（见 `detect_hazards`），
/// 因为 Rust 正则不支持后行断言，无法在一条正则里排除它。
static GIT_FORCE_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)\bgit\s+(?:push\b[^\n]*(?:\s-f\b|\s--force\b)|reset\s+--hard\b|clean\s+-[a-z]*f[a-z]*\b)",
    )
    .unwrap()
});

static SQL_DESTRUCTIVE_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b(?:drop\s+(?:table|database|schema)|truncate\s+table)\b").unwrap()
});

/// fork 炸弹：`:(){ :|:& };:`
static FORK_BOMB_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r":\s*\(\s*\)\s*\{[^}]*\}\s*;\s*:").unwrap());

static POWER_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b(?:shutdown|reboot|halt|poweroff)\b|\b(?:killall|pkill)\s+-9\b").unwrap()
});

// MARK: - 文本工具

/// 去掉末尾所有换行符（`\n`、`\r`、`\r\n` 组合）。
///
/// 这是终端防误触的核心动作：终端收到「文本 + 回车」就等于「命令 + 执行」，
/// 去掉末尾回车后，命令只是被填进输入行，用户自己按回车才执行。
pub fn strip_trailing_line_breaks(text: &str) -> String {
    text.trim_end_matches(['\n', '\r']).to_string()
}

/// 统计「有意义」的行数：忽略空行与纯空白行。
/// 判多行命令看的是这个数，而不是 `text.lines().count()` ——
/// 后者会把末尾残留空行也算进去，导致单行命令被误判成多行。
fn count_command_lines(text: &str) -> u32 {
    let body = text.trim_end_matches(['\n', '\r']);
    body.lines().filter(|line| !line.trim().is_empty()).count() as u32
}

/// 多行内容能否安全合并成一行。
///
/// 合并用的是 ` && `（前一行成功才执行下一行），这对「cd /tmp / git pull」
/// 这类命令串是对的；但下面这些写法一旦合并就改了语义，必须放弃合并、
/// 让用户在弹窗里逐行看清自己决定：
/// - heredoc（`<<EOF`）：合并后结束标记就找不到了；
/// - 行尾反斜杠续行：本来就是一行，合并会多插一个 `&&`；
/// - 行尾管道 `|`、`&&`、`||`、`;`、`&`：这些是显式连接符，自己已经表达了串联；
/// - shell 块结构（`for … do` / `if … then` / `{`）：硬合并会把块拆散；
/// - 注释行（`#`）：合并后整行连同后面的命令一起被注释掉，等于静默丢命令。
fn can_merge_lines(lines: &[&str]) -> bool {
    lines.iter().all(|raw| {
        let line = raw.trim();
        if line.is_empty() {
            return true;
        }
        // heredoc 起始 / 注释行
        if line.contains("<<") || line.starts_with('#') {
            return false;
        }
        for suffix in ["\\", "|", "&&", "||", ";", "&", "(", "{"] {
            if line.ends_with(suffix) {
                return false;
            }
        }
        for keyword in ["then", "do", "else", "elif", "fi", "done", "esac", "}", ")"] {
            if line == keyword || line.starts_with(&format!("{keyword} ")) {
                return false;
            }
        }
        true
    })
}

// MARK: - 判定入口

/// 按特征词（子串 + 分词）判断字符串是否带有明确终端标识。
fn matches_terminal_keywords(candidate: &str) -> bool {
    let lower = candidate.trim().to_ascii_lowercase();
    if lower.is_empty() {
        return false;
    }
    if TERMINAL_SUBSTRING_KEYWORDS.iter().any(|kw| lower.contains(kw)) {
        return true;
    }
    lower
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|tok| !tok.is_empty())
        .any(|tok| TERMINAL_TOKEN_KEYWORDS.contains(&tok))
}

/// 目标应用是否是已知独立终端（精确白名单 + 终端关键词兜底）。
pub fn is_terminal_bundle_id(bundle_id: &str) -> bool {
    let needle = bundle_id.trim();
    if needle.is_empty() {
        return false;
    }
    if TERMINAL_BUNDLE_IDS
        .iter()
        .any(|known| known.eq_ignore_ascii_case(needle))
    {
        return true;
    }
    matches_terminal_keywords(needle)
}

/// 目标应用是否是带内置终端的 IDE / AI 编程工具。
pub fn is_integrated_terminal_app(bundle_id: &str, app_name: &str) -> bool {
    let bid = bundle_id.trim();
    if !bid.is_empty() {
        if INTEGRATED_TERMINAL_BUNDLE_IDS
            .iter()
            .any(|known| known.eq_ignore_ascii_case(bid))
        {
            return true;
        }
        let lower_bid = bid.to_ascii_lowercase();
        if lower_bid.starts_with("com.jetbrains.")
            || lower_bid.starts_with("com.google.android.studio")
            || lower_bid.contains("vscode")
            || lower_bid.contains("vscodium")
            || lower_bid.contains("cursor")
            || lower_bid.contains("windsurf")
            || lower_bid.contains("webcodex")
            || lower_bid.contains("workbuddy")
        {
            return true;
        }
    }

    let lower_name = app_name.trim().to_ascii_lowercase();
    if lower_name.is_empty() {
        return false;
    }
    [
        "visual studio code",
        "vscode",
        "vscodium",
        "cursor",
        "windsurf",
        "trae",
        "zed",
        "deepseek harness",
        "webcodex",
        "workbuddy",
        "xcode",
        "intellij",
        "pycharm",
        "webstorm",
        "goland",
        "clion",
        "rustrover",
        "phpstorm",
        "rubymine",
        "datagrip",
        "rider",
        "android studio",
    ]
    .iter()
    .any(|kw| lower_name.contains(kw))
}

/// 综合 Bundle ID、应用显示名称与「是否保护编辑器内置终端」开关判断目标是否受护栏保护。
pub fn is_terminal_target(
    bundle_id: &str,
    app_name: &str,
    include_ide_terminals: bool,
) -> bool {
    if is_terminal_bundle_id(bundle_id) || matches_terminal_keywords(app_name) {
        return true;
    }
    include_ide_terminals && is_integrated_terminal_app(bundle_id, app_name)
}

/// 识别文本里所有高危内容。与「是不是终端」无关，纯文本判定
/// （单独暴露是为了让测试和未来的 Windows 端能独立复用）。
pub fn detect_hazards(text: &str) -> Vec<TerminalHazard> {
    if text.trim().is_empty() {
        return Vec::new();
    }

    // `--force-with-lease` 先剔除，避免被 `--force` 规则连坐误伤
    let normalized = text.replace("--force-with-lease", " ");

    let mut hazards = Vec::new();
    if count_command_lines(text) >= 2 {
        hazards.push(TerminalHazard::Multiline);
    }
    if SUDO_RE.is_match(&normalized) {
        hazards.push(TerminalHazard::Sudo);
    }
    if RM_RF_RE.is_match(&normalized) {
        hazards.push(TerminalHazard::RmRecursiveForce);
    }
    if MKFS_RE.is_match(&normalized) {
        hazards.push(TerminalHazard::Mkfs);
    }
    if DISK_WRITE_RE.is_match(&normalized) {
        hazards.push(TerminalHazard::DiskWrite);
    }
    if PIPE_TO_SHELL_RE.is_match(&normalized) {
        hazards.push(TerminalHazard::PipeToShell);
    }
    if CHMOD_777_RE.is_match(&normalized) {
        hazards.push(TerminalHazard::ChmodWideOpen);
    }
    if GIT_FORCE_RE.is_match(&normalized) {
        hazards.push(TerminalHazard::GitForcePush);
    }
    if SQL_DESTRUCTIVE_RE.is_match(&normalized) {
        hazards.push(TerminalHazard::SqlDestructive);
    }
    if FORK_BOMB_RE.is_match(&normalized) {
        hazards.push(TerminalHazard::ForkBomb);
    }
    if POWER_RE.is_match(&normalized) {
        hazards.push(TerminalHazard::PowerControl);
    }
    hazards
}

/// 终端粘贴的统一判定入口（仅传 `bundle_id`，仅对独立终端及关键词匹配生效）。
///
/// 客户端带应用名与 IDE 内置终端开关时，请调用 `assess_terminal_paste_with_context`。
pub fn assess_terminal_paste(bundle_id: &str, text: &str) -> TerminalPasteAssessment {
    assess_terminal_paste_with_context(bundle_id, "", text, false)
}

/// 带应用名称与「是否保护编辑器内置终端」开关的完整判定入口。
///
/// - 非受保护目标：`is_terminal = false`，其余字段无意义，调用方直接走原有粘贴路径；
/// - 终端 + 低风险单行：`strips_trailing_newline = true`（原文末尾有回车时），
///   调用方应粘贴 `safe_text` 并给一句轻提示，**不弹窗**；
/// - 终端 + 多行/高危：`requires_confirmation = true`，调用方必须弹窗。
pub fn assess_terminal_paste_with_context(
    bundle_id: &str,
    app_name: &str,
    text: &str,
    include_ide_terminals: bool,
) -> TerminalPasteAssessment {
    if !is_terminal_target(bundle_id, app_name, include_ide_terminals) {
        return TerminalPasteAssessment::passthrough(text);
    }

    let safe_text = strip_trailing_line_breaks(text);
    let hazards = detect_hazards(&safe_text);

    // 安全粘贴形态：多行且可安全串联 → 用 ` && ` 拼成一行，
    // 整段内容只是被填进输入行，用户按回车才会执行。
    // 不可安全串联（heredoc / 块结构 / 显式连接符）时退化为仅去末尾换行——
    // 宁可让用户自己逐行确认，也不擅自改写命令语义。
    let lines: Vec<&str> = safe_text.lines().filter(|l| !l.trim().is_empty()).collect();
    let can_merge_single_line = lines.len() >= 2 && can_merge_lines(&lines);
    let single_line_text = if can_merge_single_line {
        lines.iter().map(|l| l.trim()).collect::<Vec<_>>().join(" && ")
    } else {
        safe_text.clone()
    };

    TerminalPasteAssessment {
        is_terminal: true,
        requires_confirmation: !hazards.is_empty(),
        hazards,
        line_count: lines.len() as u32,
        single_line_text,
        safe_text: safe_text.clone(),
        can_merge_single_line,
        strips_trailing_newline: safe_text != text,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TERMINAL: &str = "com.apple.Terminal";
    const ITERM: &str = "com.googlecode.iterm2";
    const CHROME: &str = "com.google.Chrome";

    fn keys(a: &TerminalPasteAssessment) -> Vec<&'static str> {
        a.hazards.iter().map(|h| h.key()).collect()
    }

    // MARK: 终端识别

    #[test]
    fn test_known_terminals_are_recognized() {
        assert!(is_terminal_bundle_id(TERMINAL));
        assert!(is_terminal_bundle_id(ITERM));
        assert!(is_terminal_bundle_id("dev.warp.Warp-Stable"));
        assert!(is_terminal_bundle_id("com.mitchellh.ghostty"));
        // 大小写不敏感（部分应用上报的 ID 并不规范）
        assert!(is_terminal_bundle_id("COM.APPLE.TERMINAL"));
    }

    #[test]
    fn test_non_terminals_are_not_recognized() {
        assert!(!is_terminal_bundle_id(CHROME));
        assert!(!is_terminal_bundle_id("com.microsoft.VSCode"));
        assert!(!is_terminal_bundle_id(""));
        assert!(!is_terminal_bundle_id("   "));
    }

    #[test]
    fn test_non_terminal_target_is_passthrough() {
        let text = "sudo rm -rf /\n";
        let a = assess_terminal_paste(CHROME, text);
        assert!(!a.is_terminal);
        assert!(!a.requires_confirmation);
        assert!(a.hazards.is_empty());
        // 非终端不改写原文：浏览器/编辑器里粘贴必须保持原样
        assert_eq!(a.safe_text, text);
        assert!(!a.strips_trailing_newline);
    }

    // MARK: 静默档

    #[test]
    fn test_single_line_trailing_newline_is_stripped_silently() {
        let a = assess_terminal_paste(TERMINAL, "ls -la\n");
        assert!(a.is_terminal);
        assert!(!a.requires_confirmation, "普通单行命令不应弹窗");
        assert!(a.strips_trailing_newline);
        assert_eq!(a.safe_text, "ls -la");
        assert_eq!(a.line_count, 1);
    }

    #[test]
    fn test_multiple_trailing_newlines_are_all_stripped() {
        let a = assess_terminal_paste(ITERM, "git status\n\n\r\n");
        assert!(!a.requires_confirmation);
        assert_eq!(a.safe_text, "git status");
        assert_eq!(a.line_count, 1, "末尾空行不应被算成多行命令");
    }

    #[test]
    fn test_single_line_without_newline_needs_no_rewrite() {
        let a = assess_terminal_paste(TERMINAL, "npm run dev");
        assert!(!a.requires_confirmation);
        assert!(!a.strips_trailing_newline);
        assert_eq!(a.safe_text, "npm run dev");
    }

    #[test]
    fn test_strip_trailing_line_breaks_handles_crlf_and_cr() {
        assert_eq!(strip_trailing_line_breaks("cmd\n"), "cmd");
        assert_eq!(strip_trailing_line_breaks("cmd\r\n"), "cmd");
        assert_eq!(strip_trailing_line_breaks("cmd\r"), "cmd");
        assert_eq!(strip_trailing_line_breaks("cmd\n\n\n"), "cmd");
        // 只削尾部，正文中间的换行必须保留
        assert_eq!(strip_trailing_line_breaks("a\nb\n"), "a\nb");
        assert_eq!(strip_trailing_line_breaks(""), "");
    }

    // MARK: 确认档

    #[test]
    fn test_multiline_command_requires_confirmation() {
        let a = assess_terminal_paste(TERMINAL, "cd /tmp\ngit clone https://x/y.git\n");
        assert!(a.requires_confirmation);
        assert!(keys(&a).contains(&"multiline"));
        assert_eq!(a.line_count, 2);
        assert_eq!(a.safe_text, "cd /tmp\ngit clone https://x/y.git");
    }

    #[test]
    fn test_sudo_requires_confirmation() {
        let a = assess_terminal_paste(ITERM, "sudo apt install foo");
        assert!(a.requires_confirmation);
        assert_eq!(keys(&a), vec!["sudo"]);
    }

    #[test]
    fn test_rm_recursive_force_requires_confirmation() {
        for cmd in [
            "rm -rf /tmp/x",
            "rm -fr build",
            "rm -Rf build",
            "rm -rfv node_modules",
        ] {
            let a = assess_terminal_paste(TERMINAL, cmd);
            assert!(keys(&a).contains(&"rm_rf"), "未识别: {cmd}");
        }
    }

    #[test]
    fn test_plain_rm_is_allowed() {
        for cmd in ["rm file.txt", "rm -r build", "rm --interactive file"] {
            let a = assess_terminal_paste(TERMINAL, cmd);
            assert!(!a.requires_confirmation, "普通删除不应拦: {cmd}");
        }
    }

    #[test]
    fn test_pipe_to_shell_requires_confirmation() {
        let a = assess_terminal_paste(TERMINAL, "curl -fsSL https://x/install.sh | sh");
        assert!(keys(&a).contains(&"pipe_to_shell"));

        let b = assess_terminal_paste(TERMINAL, "wget -qO- https://x/i | sudo bash");
        assert!(keys(&b).contains(&"pipe_to_shell"));
    }

    #[test]
    fn test_curl_without_pipe_is_allowed() {
        let a = assess_terminal_paste(TERMINAL, "curl -O https://x/a.tar.gz");
        assert!(!a.requires_confirmation);
    }

    #[test]
    fn test_disk_write_and_mkfs_and_dd_are_flagged() {
        assert!(keys(&assess_terminal_paste(TERMINAL, "mkfs.ext4 /dev/sdb1")).contains(&"mkfs"));
        assert!(keys(&assess_terminal_paste(TERMINAL, "dd if=/dev/zero of=/dev/disk2"))
            .contains(&"disk_write"));
        assert!(keys(&assess_terminal_paste(TERMINAL, "cat a.iso > /dev/rdisk2"))
            .contains(&"disk_write"));
    }

    #[test]
    fn test_chmod_777_is_flagged() {
        assert!(keys(&assess_terminal_paste(TERMINAL, "chmod -R 777 /var/www")).contains(&"chmod_777"));
        assert!(keys(&assess_terminal_paste(TERMINAL, "chmod 0777 script.sh")).contains(&"chmod_777"));
        // 644 是正常权限，不能误伤
        assert!(!assess_terminal_paste(TERMINAL, "chmod 644 file").requires_confirmation);
    }

    #[test]
    fn test_git_force_push_is_flagged_but_force_with_lease_is_not() {
        assert!(keys(&assess_terminal_paste(TERMINAL, "git push --force origin main"))
            .contains(&"git_force_push"));
        assert!(keys(&assess_terminal_paste(TERMINAL, "git push -f")).contains(&"git_force_push"));
        let safe = assess_terminal_paste(TERMINAL, "git push --force-with-lease origin main");
        assert!(!safe.requires_confirmation, "--force-with-lease 是安全写法，不应拦");
    }

    #[test]
    fn test_destructive_sql_is_flagged() {
        assert!(keys(&assess_terminal_paste(TERMINAL, "DROP TABLE users;")).contains(&"sql_drop"));
        assert!(keys(&assess_terminal_paste(TERMINAL, "truncate table logs")).contains(&"sql_drop"));
        assert!(!assess_terminal_paste(TERMINAL, "select * from users").requires_confirmation);
    }

    #[test]
    fn test_fork_bomb_and_power_control_are_flagged() {
        assert!(keys(&assess_terminal_paste(TERMINAL, ":(){ :|:& };:")).contains(&"fork_bomb"));
        assert!(keys(&assess_terminal_paste(TERMINAL, "sudo shutdown -h now")).contains(&"sudo"));
        assert!(keys(&assess_terminal_paste(TERMINAL, "reboot")).contains(&"power_control"));
    }

    #[test]
    fn test_hazards_are_deduplicated_and_ordered() {
        let a = assess_terminal_paste(TERMINAL, "sudo rm -rf /tmp/x\nsudo reboot\n");
        let ks = keys(&a);
        assert_eq!(ks.first(), Some(&"multiline"), "多行排在最前");
        // sudo 只出现一次
        assert_eq!(ks.iter().filter(|k| **k == "sudo").count(), 1);
        assert!(ks.contains(&"rm_rf"));
        assert!(ks.contains(&"power_control"));
    }

    #[test]
    fn test_empty_and_whitespace_text_is_safe() {
        for text in ["", "   ", "\n\n"] {
            let a = assess_terminal_paste(TERMINAL, text);
            assert!(!a.requires_confirmation, "空内容不该弹窗");
            assert_eq!(a.line_count, 0);
        }
    }

    #[test]
    fn test_prose_with_trailing_newline_is_only_rewritten() {
        // 段落文本粘进终端：只削末尾回车，不弹窗
        let a = assess_terminal_paste(TERMINAL, "这是一段说明文字\n");
        assert!(!a.requires_confirmation);
        assert!(a.strips_trailing_newline);
        assert_eq!(a.safe_text, "这是一段说明文字");
    }

    #[test]
    fn test_sudoers_path_is_not_false_positive() {
        assert!(!SUDO_RE.is_match("/etc/sudoers.d/foo"));
        assert!(!SUDO_RE.is_match("sudoers"));
        assert!(SUDO_RE.is_match("sudo ls"));
        assert!(SUDO_RE.is_match("ls && sudo reboot"));
    }

    // MARK: 单行合并形态

    #[test]
    fn test_multiline_safe_commands_merge_into_one_line() {
        let a = assess_terminal_paste(TERMINAL, "cd /tmp\ngit pull\nnpm test\n");
        assert!(a.can_merge_single_line);
        assert_eq!(a.single_line_text, "cd /tmp && git pull && npm test");
        // 合并只影响「单行形态」，多行原文仍保留在 safe_text
        assert_eq!(a.safe_text, "cd /tmp\ngit pull\nnpm test");
        assert!(a.requires_confirmation, "多行仍要确认");
        assert!(keys(&a).contains(&"multiline"));
    }

    #[test]
    fn test_heredoc_is_never_merged() {
        let text = "cat > notes.md <<EOF\nhello\nEOF\n";
        let a = assess_terminal_paste(TERMINAL, text);
        assert!(!a.can_merge_single_line, "heredoc 合并会丢掉结束标记");
        assert_eq!(a.single_line_text, a.safe_text);
    }

    #[test]
    fn test_shell_block_is_never_merged() {
        for text in [
            "for f in *.log\ndo\n  wc -l \"$f\"\ndone\n",
            "if [ -f x ]; then\n  echo yes\nfi\n",
            "while read l\ndo echo \"$l\"\ndone < in.txt\n",
        ] {
            let a = assess_terminal_paste(TERMINAL, text);
            assert!(!a.can_merge_single_line, "块结构不该被硬合并：{text}");
        }
    }

    #[test]
    fn test_explicit_connectors_are_never_merged() {
        for text in ["make \\\n  build\n", "cat a.txt |\n  grep x\n", "foo &&\nbar\n"] {
            let a = assess_terminal_paste(TERMINAL, text);
            assert!(!a.can_merge_single_line, "显式连接符不该再补 &&：{text}");
        }
    }

    #[test]
    fn test_comment_line_is_never_merged() {
        let a = assess_terminal_paste(TERMINAL, "# 先备份\ncp a b\n");
        assert!(!a.can_merge_single_line, "注释行合并会把后面的命令一起注释掉");
    }

    #[test]
    fn test_single_line_has_no_merge_form() {
        let a = assess_terminal_paste(TERMINAL, "ls -la\n");
        assert!(!a.can_merge_single_line);
        assert_eq!(a.single_line_text, "ls -la");
    }

    #[test]
    fn test_blank_lines_are_ignored_in_merge() {
        let a = assess_terminal_paste(TERMINAL, "cd /tmp\n\n\ngit pull\n");
        assert!(a.can_merge_single_line);
        assert_eq!(a.single_line_text, "cd /tmp && git pull");
        assert_eq!(a.line_count, 2);
    }

    #[test]
    fn test_extended_terminals_and_keywords_are_recognized() {
        for bid in [
            "io.appmakes.otty",
            "com.stablyai.orca",
            "dev.waveterm.Wave",
            "com.raphaelamorim.rio",
            "org.contour-terminal.contour",
            "com.finalshell",
            "kingToolbox.WindTerm",
            "com.vandyke.SecureCRT",
            "com.lemonmojo.RoyalTSX.App",
            "com.panic.Prompt3",
            "dev.kdrag0n.MacVirt",
            "com.example.my-custom-terminal",
        ] {
            assert!(is_terminal_bundle_id(bid), "应识别终端: {bid}");
        }
        assert!(is_terminal_target("", "Otty", false));
        assert!(is_terminal_target("", "FinalShell", false));
        assert!(is_terminal_target("com.unknown.app", "My Super Terminal", false));
    }

    #[test]
    fn test_ide_integrated_terminal_switch() {
        for bid in [
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92",
            "com.deepseek.dsh",
            "dev.webcodex.desktop",
            "com.tencent.workbuddy.mac",
            "com.apple.dt.Xcode",
            "com.jetbrains.intellij",
        ] {
            assert!(
                !is_terminal_target(bid, "", false),
                "关闭 IDE 开关时不应拦: {bid}"
            );
            assert!(
                is_terminal_target(bid, "", true),
                "开启 IDE 开关时应保护内置终端: {bid}"
            );
            let a = assess_terminal_paste_with_context(bid, "", "cd /tmp\ngit status\n", true);
            assert!(a.is_terminal && a.requires_confirmation);
        }
    }

    #[test]
    fn test_expanded_destructive_commands_are_flagged() {
        assert!(keys(&assess_terminal_paste(TERMINAL, "git reset --hard HEAD~1"))
            .contains(&"git_force_push"));
        assert!(keys(&assess_terminal_paste(TERMINAL, "git clean -fd"))
            .contains(&"git_force_push"));
        assert!(keys(&assess_terminal_paste(TERMINAL, "rm -r -f /tmp/demo"))
            .contains(&"rm_rf"));
        assert!(keys(&assess_terminal_paste(TERMINAL, "find . -name '*.tmp' -delete"))
            .contains(&"rm_rf"));
        assert!(keys(&assess_terminal_paste(TERMINAL, "DROP DATABASE prod;"))
            .contains(&"sql_drop"));
        assert!(keys(&assess_terminal_paste(TERMINAL, "killall -9 node"))
            .contains(&"power_control"));
    }
}
