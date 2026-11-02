import Foundation

public enum LanQuickDropPage {
    public enum Locale: String, Equatable {
        case zhHans = "zh-Hans"
        case zhHant = "zh-Hant"
        case en = "en"
    }

    /// 由 HTTP `Accept-Language` 推断移动端页面初始语言：
    /// - `zh-tw` / `zh-hk` / `zh-mo` / `zh-hant` → 繁體中文
    /// - 其余 `zh*` → 简体中文
    /// - 其它任意国家/语言（或 header 缺失时回退客户端应用语言）→ English
    public static func resolveLocale(acceptLanguage: String?) -> Locale {
        let raw = (acceptLanguage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let primaryTag: String
        if !raw.isEmpty {
            primaryTag = raw.split(separator: ",").first.map {
                String($0.split(separator: ";").first ?? "")
            } ?? ""
        } else {
            primaryTag = LocalizationManager.shared.effectiveLanguageCode.lowercased()
        }
        if primaryTag.hasPrefix("zh") {
            if primaryTag.contains("hant") || primaryTag.contains("tw") || primaryTag.contains("hk") || primaryTag.contains("mo") {
                return .zhHant
            }
            return .zhHans
        }
        return .en
    }

    public static func html(payload: LanSharedPayload, token: String, acceptLanguage: String? = nil) -> String {
        let locale = resolveLocale(acceptLanguage: acceptLanguage)
        let meta: [String: Any] = [
            "kind": payload.kind.rawValue,
            "title": payload.title,
            "fileName": payload.fileName,
            "token": token,
            "locale": locale.rawValue,
        ]
        let metaJSON: String = {
            guard let data = try? JSONSerialization.data(withJSONObject: meta),
                  var string = String(data: data, encoding: .utf8) else { return "{}" }
            // 防止文件名/标题里出现 </script> 破坏内联脚本
            string = string.replacingOccurrences(of: "</", with: "<\\/")
            return string
        }()
        return template
            .replacingOccurrences(of: "__LAN_LANG__", with: locale.rawValue)
            .replacingOccurrences(of: "__LAN_META__", with: metaJSON)
    }

    private static let template = #"""
<!DOCTYPE html>
<html lang="__LAN_LANG__">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="robots" content="noindex, nofollow">
<title>NookClip · Phone Drop</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "PingFang TC", "Microsoft YaHei", sans-serif; background: #f2f2f7; color: #1d1d1f; padding: 18px; padding-bottom: 40px; }
  @media (prefers-color-scheme: dark) { body { background: #1c1c1e; color: #f5f5f7; } .card { background: #2c2c2e !important; } .muted { color: #98989d !important; } textarea, input[type=text] { background: #1c1c1e !important; color: #f5f5f7 !important; border-color: #3a3a3c !important; } .pre { background: #1c1c1e !important; } }
  .wrap { max-width: 680px; margin: 0 auto; }
  .brand { display: flex; align-items: center; gap: 8px; font-size: 13px; font-weight: 600; color: #007aff; margin-bottom: 14px; }
  .card { background: #fff; border-radius: 14px; padding: 16px; margin-bottom: 14px; box-shadow: 0 1px 3px rgba(0,0,0,.06); }
  h1 { font-size: 17px; margin: 0 0 4px; line-height: 1.35; word-break: break-word; }
  .muted { font-size: 12px; color: #6e6e73; line-height: 1.5; }
  .pre { white-space: pre-wrap; word-break: break-word; background: #f2f2f7; border-radius: 10px; padding: 12px; margin: 12px 0; max-height: 46vh; overflow: auto; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px; line-height: 1.55; -webkit-user-select: text; user-select: text; }
  img#img { display: none; max-width: 100%; border-radius: 10px; margin: 12px 0; }
  .btn { appearance: none; border: 0; border-radius: 10px; padding: 11px 16px; font-size: 15px; font-weight: 600; background: #007aff; color: #fff; width: 100%; margin-top: 8px; cursor: pointer; }
  .btn.secondary { background: #e5e5ea; color: #1d1d1f; }
  @media (prefers-color-scheme: dark) { .btn.secondary { background: #3a3a3c; color: #f5f5f7; } }
  .btn:active { opacity: .8; }
  .row { display: flex; gap: 10px; }
  .row > * { flex: 1; }
  textarea { width: 100%; min-height: 92px; border-radius: 10px; border: 1px solid #d1d1d6; padding: 10px 12px; font-size: 15px; font-family: inherit; resize: vertical; background: #fff; color: inherit; }
  .filelabel { display: block; border: 1px dashed #c7c7cc; border-radius: 10px; padding: 14px; text-align: center; font-size: 14px; color: #6e6e73; margin-top: 8px; }
  .status { font-size: 13px; text-align: center; min-height: 20px; margin-top: 6px; color: #34c759; }
  .status.err { color: #ff3b30; }
  .hint { font-size: 12px; color: #6e6e73; margin-top: 6px; }
  .dl { display: inline-block; margin-top: 12px; font-size: 14px; color: #007aff; text-decoration: none; }
</style>
</head>
<body>
<div class="wrap">
  <div class="brand" id="brand">◇ NookClip · Phone Drop</div>

  <div class="card">
    <h1 id="title">From Your Mac</h1>
    <div class="muted" id="subtitle">Peer-to-peer over your local network. Never touches any cloud server.</div>
    <pre class="pre" id="content" style="display:none"></pre>
    <img id="img" alt="Image">
    <a class="dl" id="dl" style="display:none" download>Download</a>
    <button class="btn" id="copyBtn" style="display:none">Copy Text</button>
  </div>

  <div class="card">
    <h1 id="sendHeading">Send to Mac Clipboard</h1>
    <div class="muted" id="sendDesc">Type text below or pick a photo / file from your phone to send it straight to your Mac.</div>
    <textarea id="textInput" placeholder="Type text to send to your Mac…"></textarea>
    <button class="btn" id="sendTextBtn">Send Text to Mac</button>
    <label class="filelabel" for="fileInput" id="fileLabel">Or tap to choose a photo / file</label>
    <input type="file" id="fileInput" style="display:none">
    <button class="btn secondary" id="sendFileBtn" style="display:none">Send Selected File to Mac</button>
    <div class="status" id="status"></div>
    <div class="hint" id="footerHint">Keep the Phone Drop view open on your Mac during transfer — closing it or waiting 5 minutes disconnects immediately.</div>
  </div>
</div>
<script>
(function () {
  var META = __LAN_META__;
  var I18N = {
    'zh-Hans': {
      brand: '◇ NookClip · 手机互传',
      fromMac: '来自电脑的内容',
      subtitleText: '同一局域网内点对点传输，数据不经过任何服务器。',
      subtitleImg: '长按图片可保存到相册。',
      subtitleFile: '点下方链接下载电脑上的文件。',
      dlImg: '下载原图',
      dlFilePrefix: '下载文件：',
      dlFileFallback: '文件',
      copyBtn: '一键复制文本',
      copied: '已复制到手机剪贴板',
      copyFail: '复制失败，请长按选择文本',
      loadFail: '连接已断开，请确认电脑端仍保持快传界面打开',
      sendHeading: '发送到电脑剪贴板',
      sendDesc: '在下方输入文字，或选择手机相册里的图片 / 文件，点发送即可传回 Mac。',
      textPlaceholder: '在这里输入要发回电脑的文字…',
      sendTextBtn: '发送文字到电脑',
      fileLabelIdle: '或点此选择图片 / 文件',
      fileLabelPicked: '已选择：',
      sendFileBtn: '发送所选文件到电脑',
      footerHint: '仅在同一 Wi-Fi / 局域网内有效；传输期间请保持电脑端快传界面打开，关闭界面或超过 5 分钟将立即断开连接。',
      emptyTextErr: '请先输入文字',
      emptyFileErr: '请先选择文件',
      sending: '发送中…',
      uploading: '上传中…',
      sentOk: '已发送到电脑剪贴板 ✓',
      sendFail: '发送失败，请确认电脑端仍保持快传界面打开',
      uploadTooLarge: '上传失败，文件可能超过 50MB'
    },
    'zh-Hant': {
      brand: '◇ NookClip · 手機互傳',
      fromMac: '來自電腦的內容',
      subtitleText: '同一區域網路內點對點傳輸，資料不經過任何伺服器。',
      subtitleImg: '長按圖片可儲存到相簿。',
      subtitleFile: '點下方連結下載電腦上的檔案。',
      dlImg: '下載原圖',
      dlFilePrefix: '下載檔案：',
      dlFileFallback: '檔案',
      copyBtn: '一鍵複製文字',
      copied: '已複製到手機剪貼簿',
      copyFail: '複製失敗，請長按選取文字',
      loadFail: '連線已中斷，請確認電腦端仍保持快傳介面開啟',
      sendHeading: '傳送到電腦剪貼簿',
      sendDesc: '在下方輸入文字，或選取手機相簿裡的圖片 / 檔案，點傳送即可傳回 Mac。',
      textPlaceholder: '在這裡輸入要傳回電腦的文字…',
      sendTextBtn: '傳送文字到電腦',
      fileLabelIdle: '或點此選取圖片 / 檔案',
      fileLabelPicked: '已選取：',
      sendFileBtn: '傳送所選檔案到電腦',
      footerHint: '僅在同一 Wi-Fi / 區域網路內有效；傳輸期間請保持電腦端快傳介面開啟，關閉介面或超過 5 分鐘將立即中斷連線。',
      emptyTextErr: '請先輸入文字',
      emptyFileErr: '請先選取檔案',
      sending: '傳送中…',
      uploading: '上傳中…',
      sentOk: '已傳送到電腦剪貼簿 ✓',
      sendFail: '傳送失敗，請確認電腦端仍保持快傳介面開啟',
      uploadTooLarge: '上傳失敗，檔案可能超過 50MB'
    },
    'en': {
      brand: '◇ NookClip · Phone Drop',
      fromMac: 'From Your Mac',
      subtitleText: 'Peer-to-peer over your local network. Never touches any cloud server.',
      subtitleImg: 'Long-press the image to save it to Photos.',
      subtitleFile: 'Tap the link below to download the file from your Mac.',
      dlImg: 'Download Original Image',
      dlFilePrefix: 'Download: ',
      dlFileFallback: 'file',
      copyBtn: 'Copy Text',
      copied: 'Copied to phone clipboard',
      copyFail: 'Copy failed — long-press to select text',
      loadFail: 'Disconnected — make sure Phone Drop is still open on your Mac',
      sendHeading: 'Send to Mac Clipboard',
      sendDesc: 'Type text below or pick a photo / file from your phone to send it straight to your Mac.',
      textPlaceholder: 'Type text to send to your Mac…',
      sendTextBtn: 'Send Text to Mac',
      fileLabelIdle: 'Or tap to choose a photo / file',
      fileLabelPicked: 'Selected: ',
      sendFileBtn: 'Send Selected File to Mac',
      footerHint: 'Works on the same Wi-Fi / LAN only. Keep the Phone Drop view open on your Mac during transfer — closing it or waiting 5 minutes disconnects immediately.',
      emptyTextErr: 'Please enter some text first',
      emptyFileErr: 'Please select a file first',
      sending: 'Sending…',
      uploading: 'Uploading…',
      sentOk: 'Sent to Mac clipboard ✓',
      sendFail: 'Send failed — make sure Phone Drop is still open on your Mac',
      uploadTooLarge: 'Upload failed (file may exceed 50 MB)'
    }
  };

  function pickLocale() {
    var raw = (META.locale || navigator.language || 'en').toLowerCase();
    if (raw.indexOf('zh') === 0) {
      if (raw.indexOf('hant') >= 0 || raw.indexOf('tw') >= 0 || raw.indexOf('hk') >= 0 || raw.indexOf('mo') >= 0) {
        return 'zh-Hant';
      }
      return 'zh-Hans';
    }
    return 'en';
  }

  var L = I18N[pickLocale()] || I18N['en'];
  document.title = L.brand.replace('◇ ', '');
  document.getElementById('brand').textContent = L.brand;
  document.getElementById('subtitle').textContent = L.subtitleText;
  document.getElementById('copyBtn').textContent = L.copyBtn;
  document.getElementById('sendHeading').textContent = L.sendHeading;
  document.getElementById('sendDesc').textContent = L.sendDesc;
  document.getElementById('textInput').placeholder = L.textPlaceholder;
  document.getElementById('sendTextBtn').textContent = L.sendTextBtn;
  document.getElementById('fileLabel').textContent = L.fileLabelIdle;
  document.getElementById('sendFileBtn').textContent = L.sendFileBtn;
  document.getElementById('footerHint').textContent = L.footerHint;

  var base = '/s/' + META.token;
  var statusEl = document.getElementById('status');

  function setStatus(text, isErr) {
    statusEl.textContent = text;
    statusEl.className = 'status' + (isErr ? ' err' : '');
  }

  function loadShared() {
    document.getElementById('title').textContent = META.title || L.fromMac;
    if (META.kind === 'text') {
      var pre = document.getElementById('content');
      pre.style.display = 'block';
      fetch(base + '/payload', { cache: 'no-store' }).then(function (r) { return r.text(); }).then(function (t) {
        pre.textContent = t;
      }).catch(function () { setStatus(L.loadFail, true); });
      var copyBtn = document.getElementById('copyBtn');
      copyBtn.style.display = 'block';
      copyBtn.addEventListener('click', function () {
        var text = pre.textContent || '';
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(text).then(function () { setStatus(L.copied); })
            .catch(function () { fallbackCopy(text); });
        } else { fallbackCopy(text); }
      });
    } else if (META.kind === 'image') {
      var img = document.getElementById('img');
      img.src = base + '/payload';
      img.style.display = 'block';
      document.getElementById('subtitle').textContent = L.subtitleImg;
      var dl = document.getElementById('dl');
      dl.href = base + '/payload';
      dl.textContent = L.dlImg;
      dl.style.display = 'inline-block';
    } else {
      var dlf = document.getElementById('dl');
      dlf.href = base + '/payload';
      dlf.textContent = L.dlFilePrefix + (META.fileName || L.dlFileFallback);
      dlf.style.display = 'inline-block';
      document.getElementById('subtitle').textContent = L.subtitleFile;
    }
  }

  function fallbackCopy(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); setStatus(L.copied); }
    catch (e) { setStatus(L.copyFail, true); }
    document.body.removeChild(ta);
  }

  document.getElementById('sendTextBtn').addEventListener('click', function () {
    var val = document.getElementById('textInput').value;
    if (!val || !val.trim()) { setStatus(L.emptyTextErr, true); return; }
    setStatus(L.sending);
    fetch(base + '/send', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ type: 'text', content: val })
    }).then(function (r) { return r.json(); }).then(function (res) {
      if (res && res.ok) { setStatus(L.sentOk); document.getElementById('textInput').value = ''; }
      else { setStatus(L.sendFail, true); }
    }).catch(function () { setStatus(L.sendFail, true); });
  });

  var fileInput = document.getElementById('fileInput');
  var selectedFile = null;
  fileInput.addEventListener('change', function () {
    selectedFile = fileInput.files && fileInput.files[0] ? fileInput.files[0] : null;
    var btn = document.getElementById('sendFileBtn');
    if (selectedFile) {
      document.getElementById('fileLabel').textContent = L.fileLabelPicked + selectedFile.name;
      btn.style.display = 'block';
    } else {
      document.getElementById('fileLabel').textContent = L.fileLabelIdle;
      btn.style.display = 'none';
    }
  });

  document.getElementById('sendFileBtn').addEventListener('click', function () {
    if (!selectedFile) { setStatus(L.emptyFileErr, true); return; }
    setStatus(L.uploading);
    fetch(base + '/send', {
      method: 'POST',
      headers: {
        'Content-Type': selectedFile.type || 'application/octet-stream',
        'X-Nook-Filename': encodeURIComponent(selectedFile.name)
      },
      body: selectedFile
    }).then(function (r) { return r.json(); }).then(function (res) {
      if (res && res.ok) {
        setStatus(L.sentOk);
        selectedFile = null;
        fileInput.value = '';
        document.getElementById('fileLabel').textContent = L.fileLabelIdle;
        document.getElementById('sendFileBtn').style.display = 'none';
      } else { setStatus(L.uploadTooLarge, true); }
    }).catch(function () { setStatus(L.sendFail, true); });
  });

  loadShared();
})();
</script>
</body>
</html>
"""#
}
