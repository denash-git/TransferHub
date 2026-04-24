#!/usr/bin/env python3
import os
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


PROJECT_ROOT = Path(__file__).resolve().parent.parent
INSTANCE_ENV = PROJECT_ROOT / "instance.env"
LINKS_DB = PROJECT_ROOT / "runtime" / "speedtest-links.tsv"
FAKESITE_DIR = PROJECT_ROOT / "caddy" / "fakesite"
HOST = "127.0.0.1"
PORT = 9080
TOKEN_RE = re.compile(r"^[A-Za-z0-9]{24}$")


def load_env():
    env = {}
    if not INSTANCE_ENV.exists():
        return env
    for raw_line in INSTANCE_ENV.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip()
    return env


def cleanup_and_read_links(now=None):
    now = int(now or time.time())
    LINKS_DB.parent.mkdir(parents=True, exist_ok=True)
    LINKS_DB.touch(exist_ok=True)

    valid_rows = []
    for raw_line in LINKS_DB.read_text(encoding="utf-8").splitlines():
        parts = raw_line.split("\t")
        if len(parts) < 2:
            continue
        token = parts[0].strip()
        try:
            expires_at = int(parts[1].strip())
        except ValueError:
            continue
        created_at = parts[2].strip() if len(parts) > 2 else ""
        if TOKEN_RE.fullmatch(token) and expires_at > now:
            valid_rows.append((token, expires_at, created_at))

    tmp = LINKS_DB.with_suffix(".tmp")
    tmp.write_text(
        "".join(f"{token}\t{expires_at}\t{created_at}\n" for token, expires_at, created_at in valid_rows),
        encoding="utf-8",
    )
    tmp.replace(LINKS_DB)
    return {token: expires_at for token, expires_at, _ in valid_rows}


def load_fake_index():
    index_path = FAKESITE_DIR / "index.html"
    if index_path.exists():
        return index_path.read_bytes()
    return b"<html><body><h1>OK</h1></body></html>"


def page_html(slug, expires_at):
    return f"""<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Проверка скорости</title>
  <style>
    :root {{
      --bg: #f3f7fb;
      --card: rgba(255, 255, 255, 0.92);
      --line: rgba(10, 43, 74, 0.11);
      --text: #0f2233;
      --muted: #5f7588;
      --accent: #1482d0;
      --accent-soft: #d9efff;
      --ok: #1d9a6c;
      --shadow: 0 24px 60px rgba(20, 52, 84, 0.12);
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      min-height: 100vh;
      font-family: "Segoe UI", Arial, sans-serif;
      color: var(--text);
      background:
        radial-gradient(circle at top left, rgba(20,130,208,.12), transparent 28%),
        radial-gradient(circle at bottom right, rgba(20,130,208,.09), transparent 24%),
        linear-gradient(180deg, #eef5fb, #f8fbfe);
      display: grid;
      place-items: center;
      padding: 18px;
    }}
    .card {{
      width: min(760px, 100%);
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 24px;
      padding: 28px 24px;
      box-shadow: var(--shadow);
      backdrop-filter: blur(12px);
    }}
    h1 {{
      margin: 0 0 8px;
      font-size: clamp(28px, 4vw, 38px);
      letter-spacing: -.03em;
    }}
    p {{
      margin: 0;
      color: var(--muted);
      line-height: 1.55;
    }}
    .lede {{
      margin-bottom: 22px;
    }}
    .grid {{
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 14px;
      margin: 20px 0 18px;
    }}
    .metric {{
      border: 1px solid var(--line);
      border-radius: 18px;
      padding: 18px 16px;
      background: rgba(255,255,255,.72);
      min-width: 0;
    }}
    .metric-label {{
      color: var(--muted);
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: .08em;
      margin-bottom: 8px;
    }}
    .metric-value {{
      font-size: clamp(24px, 3.2vw, 32px);
      font-weight: 700;
      letter-spacing: -.03em;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }}
    .progress-block {{
      margin: 6px 0 20px;
    }}
    .progress-top {{
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      margin-bottom: 8px;
      color: var(--muted);
      font-size: 14px;
    }}
    .progress-rail {{
      width: 100%;
      height: 10px;
      background: #e9f0f6;
      border-radius: 999px;
      overflow: hidden;
    }}
    .progress-bar {{
      width: 0%;
      height: 100%;
      border-radius: 999px;
      background: linear-gradient(90deg, #1482d0, #4ab0f2);
      transition: width .18s ease;
    }}
    .actions {{
      display: flex;
      align-items: center;
      gap: 12px;
      flex-wrap: wrap;
      margin-top: 6px;
    }}
    button {{
      appearance: none;
      border: 0;
      border-radius: 999px;
      padding: 14px 22px;
      font-weight: 700;
      font-size: 16px;
      cursor: pointer;
      color: #fff;
      background: linear-gradient(135deg, #1482d0, #0f6db2);
      box-shadow: 0 12px 26px rgba(20, 130, 208, .24);
    }}
    button[disabled] {{ opacity: .6; cursor: wait; }}
    .status {{
      min-height: 24px;
      color: var(--muted);
      font-size: 14px;
    }}
    @media (max-width: 560px) {{
      .card {{ padding: 22px 18px; }}
      .grid {{ grid-template-columns: 1fr; }}
      .actions {{ flex-direction: column; align-items: stretch; }}
      button {{ width: 100%; }}
    }}
  </style>
</head>
<body>
  <main class="card">
    <h1>Проверка скорости</h1>
    <p class="lede">Тест идёт обычным HTTPS-трафиком до VPS через порт 443.</p>
    <p class="lede" id="expiresAt" data-expires-at="{expires_at}">Ссылка действует до загрузки локального времени...</p>

    <div class="grid">
      <section class="metric"><div class="metric-label">Пинг</div><div class="metric-value" id="ping">-</div></section>
      <section class="metric"><div class="metric-label">Скачивание</div><div class="metric-value" id="download">-</div></section>
      <section class="metric"><div class="metric-label">Отдача</div><div class="metric-value" id="upload">-</div></section>
    </div>

    <section class="progress-block" aria-live="polite">
      <div class="progress-top">
        <span id="phaseLabel">Готово к запуску</span>
        <span id="progressLabel">0%</span>
      </div>
      <div class="progress-rail"><div class="progress-bar" id="progressBar"></div></div>
    </section>

    <div class="actions">
      <button id="startBtn" type="button">Запустить тест</button>
      <div class="status" id="status">Полный тест занимает около 25 секунд.</div>
    </div>
  </main>

  <script>
    const slug = {slug!r};
    const basePath = `/${{slug}}`;
    const expiresAtUnix = {expires_at};
    const PING_SAMPLES = 8;
    const DOWNLOAD_MS = 12000;
    const UPLOAD_MS = 16000;
    const DOWNLOAD_CONCURRENCY = 3;
    const UPLOAD_CONCURRENCY = 6;
    const DOWNLOAD_CHUNK_BYTES = 4 * 1024 * 1024;
    const UPLOAD_CHUNK_BYTES = 1024 * 1024;
    const statusEl = document.getElementById('status');
    const btn = document.getElementById('startBtn');
    const expiresAtEl = document.getElementById('expiresAt');
    const phaseLabelEl = document.getElementById('phaseLabel');
    const progressLabelEl = document.getElementById('progressLabel');
    const progressBarEl = document.getElementById('progressBar');
    const fmtMbps = (value) => value > 0 ? `${{value.toFixed(2)}} Mbps` : '0 Mbps';
    const fmtMs = (value) => value > 0 ? `${{value.toFixed(0)}} ms` : '-';

    function setProgress(percent, phase) {{
      const safePercent = Math.max(0, Math.min(100, percent));
      progressBarEl.style.width = `${{safePercent}}%`;
      progressLabelEl.textContent = `${{Math.round(safePercent)}}%`;
      if (phase) phaseLabelEl.textContent = phase;
    }}

    function setMetricPending(id) {{
      document.getElementById(id).textContent = '...';
    }}

    function renderLocalExpiry() {{
      const expires = new Date(expiresAtUnix * 1000);
      const formatted = expires.toLocaleString(undefined, {{
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit',
        second: '2-digit'
      }});
      expiresAtEl.textContent = `Ссылка действует до ${{formatted}}`;
    }}

    function overallPercent(stage, stagePercent) {{
      if (stage === 'ping') return stagePercent * 0.10;
      if (stage === 'download') return 10 + stagePercent * 0.45;
      if (stage === 'upload') return 55 + stagePercent * 0.45;
      return stagePercent;
    }}

    function startProgressLoop(stage, durationMs, label) {{
      const started = performance.now();
      setProgress(overallPercent(stage, 0), label);
      const timer = setInterval(() => {{
        const elapsed = performance.now() - started;
        const phasePercent = Math.min(elapsed / durationMs, 1);
        setProgress(overallPercent(stage, phasePercent), label);
      }}, 120);
      return () => {{
        clearInterval(timer);
        setProgress(overallPercent(stage, 1), label);
      }};
    }}

    async function timedFetch(url, options) {{
      const started = performance.now();
      const response = await fetch(url, options);
      if (!response.ok) throw new Error(`HTTP ${{response.status}}`);
      return {{ response, ms: performance.now() - started }};
    }}

    async function runPing() {{
      const values = [];
      for (let i = 0; i < PING_SAMPLES; i++) {{
        const {{ ms }} = await timedFetch(`${{basePath}}/api/ping?i=${{Date.now()}}-${{i}}`, {{ cache: 'no-store' }});
        values.push(ms);
        setProgress(overallPercent('ping', (i + 1) / PING_SAMPLES), 'Измеряем пинг');
      }}
      return values.reduce((a, b) => a + b, 0) / values.length;
    }}

    async function consumeDownload(bytes) {{
      const started = performance.now();
      const response = await fetch(`${{basePath}}/api/download?bytes=${{bytes}}&t=${{Date.now()}}`, {{ cache: 'no-store' }});
      if (!response.ok) throw new Error(`HTTP ${{response.status}}`);
      const reader = response.body.getReader();
      let total = 0;
      while (true) {{
        const {{ done, value }} = await reader.read();
        if (done) break;
        total += value.byteLength;
      }}
      return {{ bytes: total, ms: performance.now() - started }};
    }}

    async function runDownload() {{
      const started = performance.now();
      const deadline = started + DOWNLOAD_MS;
      const stopProgress = startProgressLoop('download', DOWNLOAD_MS, 'Измеряем скачивание');
      const workers = Array.from({{ length: DOWNLOAD_CONCURRENCY }}, async () => {{
        let bytes = 0;
        while (performance.now() < deadline) {{
          const sample = await consumeDownload(DOWNLOAD_CHUNK_BYTES);
          bytes += sample.bytes;
        }}
        return bytes;
      }});
      const totals = await Promise.all(workers);
      stopProgress();
      const elapsedSec = Math.max((performance.now() - started) / 1000, 0.001);
      const totalBytes = totals.reduce((a, b) => a + b, 0);
      return (totalBytes * 8) / elapsedSec / 1000000;
    }}

    async function runUpload() {{
      const chunk = new Uint8Array(UPLOAD_CHUNK_BYTES);
      for (let offset = 0; offset < chunk.length; offset += 65536) {{
        crypto.getRandomValues(chunk.subarray(offset, Math.min(offset + 65536, chunk.length)));
      }}
      const started = performance.now();
      const deadline = started + UPLOAD_MS;
      const stopProgress = startProgressLoop('upload', UPLOAD_MS, 'Измеряем отдачу');
      const workers = Array.from({{ length: UPLOAD_CONCURRENCY }}, async (_, workerIndex) => {{
        let bytes = 0;
        while (performance.now() < deadline) {{
          const response = await fetch(`${{basePath}}/api/upload?t=${{Date.now()}}-${{workerIndex}}`, {{
            method: 'POST',
            cache: 'no-store',
            headers: {{ 'Content-Type': 'application/octet-stream' }},
            body: chunk
          }});
          if (!response.ok) throw new Error(`HTTP ${{response.status}}`);
          await response.text();
          bytes += chunk.byteLength;
        }}
        return bytes;
      }});
      const totals = await Promise.all(workers);
      stopProgress();
      const elapsedSec = Math.max((performance.now() - started) / 1000, 0.001);
      const totalBytes = totals.reduce((a, b) => a + b, 0);
      return (totalBytes * 8) / elapsedSec / 1000000;
    }}

    async function runTest() {{
      btn.disabled = true;
      document.getElementById('ping').textContent = '-';
      document.getElementById('download').textContent = '-';
      document.getElementById('upload').textContent = '-';
      setMetricPending('ping');
      setMetricPending('download');
      setMetricPending('upload');
      try {{
        statusEl.textContent = 'Идёт полный HTTPS-тест. Не закрывайте вкладку.';
        setProgress(0, 'Измеряем пинг');
        const ping = await runPing();
        document.getElementById('ping').textContent = fmtMs(ping);

        statusEl.textContent = 'Пинг измерен. Проверяем скорость скачивания.';
        const download = await runDownload();
        document.getElementById('download').textContent = fmtMbps(download);

        statusEl.textContent = 'Скачивание измерено. Проверяем скорость отдачи.';
        const upload = await runUpload();
        document.getElementById('upload').textContent = fmtMbps(upload);

        setProgress(100, 'Готово');
        statusEl.textContent = 'Готово. Пока ссылка жива, тест можно запускать повторно.';
      }} catch (err) {{
        setProgress(100, 'Ошибка');
        statusEl.textContent = `Ошибка теста: ${{err.message}}`;
      }} finally {{
        btn.disabled = false;
      }}
    }}

    btn.addEventListener('click', runTest);
    renderLocalExpiry();
  </script>
</body>
</html>
""".encode("utf-8")


class SpeedTestHandler(BaseHTTPRequestHandler):
    server_version = "TransferHubSpeedTest/1.0"

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        self._dispatch("GET")

    def do_HEAD(self):
        self._dispatch("HEAD")

    def do_POST(self):
        self._dispatch("POST")

    def _dispatch(self, method):
        env = load_env()
        prefix = env.get("SPEEDTEST_PREFIX", "")
        parsed = urlparse(self.path)
        slug, action = self._extract_slug_and_action(parsed.path, prefix)
        if not slug:
            self._serve_not_found()
            return

        token = slug[len(prefix):]
        links = cleanup_and_read_links()
        expires_at = links.get(token)
        if not expires_at:
            self._serve_not_found()
            return

        if action in ("", "/") and method in ("GET", "HEAD"):
            self._serve_page(slug, expires_at)
            return
        if method in ("GET", "HEAD") and action == "/api/ping":
            self._send_text(200, "pong")
            return
        if method in ("GET", "HEAD") and action == "/api/download":
            self._serve_download(parsed.query)
            return
        if method == "POST" and action == "/api/upload":
            self._serve_upload()
            return

        self._serve_not_found()

    def _extract_slug_and_action(self, path, prefix):
        if not prefix:
            return None, None
        clean = path.split("?", 1)[0]
        parts = [part for part in clean.split("/") if part]
        if not parts:
            return None, None
        slug = parts[0]
        if not slug.startswith(prefix):
            return None, None
        token = slug[len(prefix):]
        if not TOKEN_RE.fullmatch(token):
            return None, None
        action = "/" + "/".join(parts[1:]) if len(parts) > 1 else ""
        return slug, action

    def _serve_page(self, slug, expires_at):
        body = page_html(slug, expires_at)
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _serve_download(self, query):
        size = 4 * 1024 * 1024
        parsed = parse_qs(query)
        raw_size = parsed.get("bytes", [""])[0]
        if raw_size.isdigit():
            size = max(64 * 1024, min(int(raw_size), 32 * 1024 * 1024))

        chunk = b"0" * 65536
        remaining = size
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size))
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.end_headers()
        if self.command == "HEAD":
            return

        while remaining > 0:
            piece = chunk[: min(len(chunk), remaining)]
            self.wfile.write(piece)
            remaining -= len(piece)

    def _serve_upload(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        remaining = max(length, 0)
        while remaining > 0:
            data = self.rfile.read(min(65536, remaining))
            if not data:
                break
            remaining -= len(data)
        self._send_text(200, str(length))

    def _serve_fake(self):
        body = load_fake_index()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _serve_not_found(self):
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.end_headers()

    def _send_text(self, status, text):
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)


if __name__ == "__main__":
    server = ThreadingHTTPServer((HOST, PORT), SpeedTestHandler)
    server.serve_forever()
