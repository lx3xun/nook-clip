#!/usr/bin/env node
// 逐帧截图器：用 headless Chrome + CDP 驱动页面里的 window.__seek(t)，把每一帧存成图片。
// 只用 node 内置能力（全局 WebSocket），不装任何依赖。
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  if (i === -1) return fallback;
  return process.argv[i + 1];
}

const page = arg('page', 'player.html');
const scene = arg('scene', 'a');
const fps = Number(arg('fps', '30'));
const duration = Number(arg('duration', '8000'));
const width = Number(arg('width', '1200'));
const height = Number(arg('height', '760'));
const dsf = Number(arg('dsf', '2'));
const outDir = resolve(arg('out', `frames/${scene}`));
const quality = Number(arg('quality', '92'));
const port = Number(arg('port', String(9400 + Math.floor(Math.random() * 200))));

const frameCount = Math.round((duration / 1000) * fps);

mkDirClean(outDir);

const tmpProfile = `/tmp/nookclip-capture-${port}`;
rmSync(tmpProfile, { recursive: true, force: true });

const chrome = spawn(CHROME, [
  // 关键：headless=new + no-sandbox。老式 --headless 在这里会因 GPU 进程
  // 起不来（"GPU process isn't usable. Goodbye."）直接退出，CDP 连接随之 1006 断开。
  '--headless=new',
  `--remote-debugging-port=${port}`,
  `--user-data-dir=${tmpProfile}`,
  `--window-size=${width},${height}`,
  '--hide-scrollbars',
  '--no-sandbox',
  '--disable-gpu',
  '--disable-dev-shm-usage',
  '--disable-breakpad',
  '--disable-crash-reporter',
  '--force-color-profile=srgb',
  '--allow-file-access-from-files',
  '--no-first-run',
  '--no-default-browser-check',
  '--font-render-hinting=none',
  'about:blank',
], { stdio: ['ignore', 'ignore', 'pipe'] });

let chromeStderr = '';
chrome.stderr.on('data', (d) => { chromeStderr += d.toString(); });

process.on('exit', () => { try { chrome.kill('SIGKILL'); } catch {} });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitForDevtools(timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/json/list`);
      const list = await res.json();
      const target = list.find((t) => t.type === 'page');
      if (target?.webSocketDebuggerUrl) return target.webSocketDebuggerUrl;
    } catch {}
    await sleep(120);
  }
  throw new Error(`devtools 未就绪\n${chromeStderr.slice(-2000)}`);
}

class CDP {
  constructor(ws) {
    this.ws = ws;
    this.nextId = 0;
    this.pending = new Map();
    this.listeners = new Map();
    ws.addEventListener('message', (event) => {
      const msg = JSON.parse(event.data);
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve: res, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(`${msg.error.message} (${msg.error.code})`));
        else res(msg.result);
      } else if (msg.method) {
        for (const fn of this.listeners.get(msg.method) ?? []) fn(msg.params);
      }
    });
  }
  send(method, params = {}, timeoutMs = 30000) {
    const id = ++this.nextId;
    return new Promise((res, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP 超时 ${timeoutMs}ms：${method}\n${chromeStderr.split('\n').filter((l) => !l.includes('crashpad') && !l.includes('mach_vm') && !l.includes('CVDisplayLink')).slice(-8).join('\n')}`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (v) => { clearTimeout(timer); res(v); },
        reject: (e) => { clearTimeout(timer); reject(e); },
      });
      try {
        this.ws.send(JSON.stringify({ id, method, params }));
      } catch (e) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(e);
      }
    });
  }
  on(method, fn) {
    const arr = this.listeners.get(method) ?? [];
    arr.push(fn);
    this.listeners.set(method, arr);
  }
}

function mkDirClean(dir) {
  if (existsSync(dir)) rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
}

const wsUrl = await waitForDevtools();
const ws = new WebSocket(wsUrl);
await new Promise((res, reject) => {
  ws.addEventListener('open', res, { once: true });
  ws.addEventListener('error', reject, { once: true });
});
const cdp = new CDP(ws);

await cdp.send('Page.enable');
await cdp.send('Runtime.enable');
await cdp.send('Emulation.setDeviceMetricsOverride', {
  width, height, deviceScaleFactor: dsf, mobile: false,
});

let pageErrors = [];
cdp.on('Runtime.exceptionThrown', (p) => {
  pageErrors.push(p.exceptionDetails?.exception?.description ?? p.exceptionDetails?.text ?? 'unknown');
});
cdp.on('Runtime.consoleAPICalled', (p) => {
  if (p.type === 'error') pageErrors.push(p.args.map((a) => a.value ?? a.description).join(' '));
});

const fileUrl = `file://${resolve(page)}?scene=${scene}`;
await cdp.send('Page.navigate', { url: fileUrl });

// 等页面自报就绪
const readyDeadline = Date.now() + 15000;
let ready = false;
while (Date.now() < readyDeadline) {
  const r = await cdp.send('Runtime.evaluate', {
    expression: 'Boolean(window.__ready)', returnByValue: true, awaitPromise: false,
  });
  if (r.result?.value === true) { ready = true; break; }
  if (pageErrors.length) throw new Error(`页面报错：\n${pageErrors.join('\n')}`);
  await sleep(120);
}
if (!ready) throw new Error(`页面未就绪：${fileUrl}\n${pageErrors.join('\n')}`);

const started = Date.now();
for (let i = 0; i < frameCount; i += 1) {
  const t = (i / fps) * 1000;
  await cdp.send('Runtime.evaluate', { expression: `window.__seek(${t.toFixed(3)})`, returnByValue: true });
  const shot = await cdp.send('Page.captureScreenshot', {
    format: 'jpeg', quality, captureBeyondViewport: false, fromSurface: true,
  });
  writeFileSync(join(outDir, `f${String(i).padStart(4, '0')}.jpg`), Buffer.from(shot.data, 'base64'));
  if (i % 30 === 0) process.stdout.write(`  ${scene} ${i}/${frameCount} 帧\n`);
}

if (pageErrors.length) {
  console.error('⚠️ 页面运行期报错：\n' + pageErrors.join('\n'));
}

console.log(`✅ ${scene}: ${frameCount} 帧 @${fps}fps → ${outDir}（${((Date.now() - started) / 1000).toFixed(1)}s）`);

ws.close();
chrome.kill('SIGKILL');
process.exit(0);
