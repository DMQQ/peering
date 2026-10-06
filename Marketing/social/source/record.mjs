import { spawn } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.resolve(here, '../threads/video.mp4');
const FPS = 30, W = 1080, H = 1350;
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', '--remote-debugging-port=9333', `--user-data-dir=${mkdtempSync(path.join(tmpdir(), 'rec-'))}`,
  '--allow-file-access-from-files', '--hide-scrollbars', '--force-device-scale-factor=1', `--window-size=${W},${H}`, 'about:blank',
], { stdio: 'ignore' });

const sleep = ms => new Promise(r => setTimeout(r, ms));
let targets;
for (let i = 0; i < 50; i++) {
  try { targets = await (await fetch('http://127.0.0.1:9333/json')).json(); if (targets.find(t => t.type === 'page')) break; } catch {}
  await sleep(200);
}
const ws = new WebSocket(targets.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const pending = new Map();
ws.addEventListener('message', e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } });
const send = (method, params = {}) => new Promise(res => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
const evalJS = async expr => (await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true })).result?.result?.value;

await send('Page.enable');
await send('Emulation.setDeviceMetricsOverride', { width: W, height: H, deviceScaleFactor: 1, mobile: false });
await send('Page.navigate', { url: 'file://' + path.join(here, 'video.html') });
for (let i = 0; i < 100 && !(await evalJS('window.ready === true')); i++) await sleep(100);
await evalJS(`Promise.all([...document.images].map(i => i.decode().catch(() => {})))`);

if (process.env.STILLS) {
  const { writeFileSync } = await import('node:fs');
  for (const t of process.env.STILLS.split(',')) {
    await evalJS(`seek(${t})`);
    const shot = await send('Page.captureScreenshot', { format: 'png' });
    writeFileSync(`${process.env.STILL_DIR}/still_${t}.png`, Buffer.from(shot.result.data, 'base64'));
  }
  ws.close(); chrome.kill();
  process.exit(0);
}
const total = await evalJS('window.TOTAL');
const frames = Math.round(total * FPS);
const ff = spawn('ffmpeg', ['-y', '-f', 'image2pipe', '-framerate', String(FPS), '-c:v', 'png', '-i', '-',
  '-c:v', 'libx264', '-crf', '17', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out], { stdio: ['pipe', 'ignore', 'inherit'] });
for (let f = 0; f < frames; f++) {
  await evalJS(`seek(${f / FPS})`);
  const shot = await send('Page.captureScreenshot', { format: 'png' });
  if (!ff.stdin.write(Buffer.from(shot.result.data, 'base64'))) await new Promise(r => ff.stdin.once('drain', r));
  if (f % 90 === 0) console.log(`frame ${f}/${frames}`);
}
ff.stdin.end();
await new Promise(r => ff.on('close', r));
ws.close(); chrome.kill();
console.log('done', out);
