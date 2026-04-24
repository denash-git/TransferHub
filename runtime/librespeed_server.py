#!/usr/bin/env python3
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


PROJECT_ROOT = Path(__file__).resolve().parent.parent
INSTANCE_ENV = PROJECT_ROOT / "instance.env"
LINKS_DB = PROJECT_ROOT / "runtime" / "speedtest-links.tsv"
VENDOR_DIR = PROJECT_ROOT / "runtime" / "librespeed" / "vendor"
HOST = "127.0.0.1"
PORT = 9080
TOKEN_LEN = 24


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
        if len(token) != TOKEN_LEN or not token.isalnum():
            continue
        try:
            expires_at = int(parts[1].strip())
        except ValueError:
            continue
        created_at = parts[2].strip() if len(parts) > 2 else ""
        if expires_at > now:
            valid_rows.append((token, expires_at, created_at))

    tmp = LINKS_DB.with_suffix(".tmp")
    tmp.write_text(
        "".join(f"{token}\t{expires_at}\t{created_at}\n" for token, expires_at, created_at in valid_rows),
        encoding="utf-8",
    )
    tmp.replace(LINKS_DB)
    return {token: expires_at for token, expires_at, _ in valid_rows}


def page_html(slug, expires_at):
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <base href="/{slug}/">
  <title>TransferHub Speed Test</title>
  <style>
    :root {{
      --page: #ffffff;
      --surface: #eef1f4;
      --panel: #ffffff;
      --panel-soft: #f7f8fa;
      --line: #d8dde5;
      --text: #192331;
      --muted: #6d7888;
      --accent: #3f86ff;
      --accent-2: #70b0ff;
      --good: #1db978;
      --track: #dce2ea;
      --shadow: 0 20px 48px rgba(27, 39, 53, 0.08);
    }}
    * {{ box-sizing: border-box; }}
    html, body {{ min-height: 100%; }}
    body {{
      margin: 0;
      font-family: "Segoe UI Variable Text", "Trebuchet MS", "Segoe UI", sans-serif;
      color: var(--text);
      background: var(--page);
      display: grid;
      place-items: center;
      padding: 80px;
    }}
    .shell {{
      width: min(980px, 100%);
      border-radius: 30px;
      background: var(--surface);
      border: 1px solid #e4e8ee;
      box-shadow: var(--shadow);
      overflow: hidden;
    }}
    .inner {{
      padding: 24px;
    }}
    .topbar {{
      display: flex;
      justify-content: space-between;
      gap: 16px;
      align-items: flex-start;
      margin-bottom: 18px;
    }}
    .eyebrow {{
      color: var(--accent);
      font-size: 12px;
      font-weight: 800;
      letter-spacing: .16em;
      text-transform: uppercase;
      margin-bottom: 8px;
    }}
    h1 {{
      margin: 0;
      font-size: clamp(28px, 5vw, 54px);
      line-height: .96;
      letter-spacing: -.05em;
    }}
    .subline {{
      margin-top: 12px;
      color: var(--muted);
      font-size: 14px;
      max-width: 50ch;
      line-height: 1.45;
    }}
    .expiry {{
      min-width: 240px;
      padding: 14px 34px 13px;
      border-radius: 18px;
      border: 1px solid var(--line);
      background: var(--panel);
      text-align: right;
    }}
    .expiry-label {{
      display: block;
      color: var(--muted);
      font-size: 11px;
      letter-spacing: .12em;
      text-transform: uppercase;
      margin-bottom: 6px;
    }}
    .expiry-value {{
      font-size: 15px;
      font-weight: 700;
      color: var(--text);
    }}
    .dashboard {{
      display: grid;
      grid-template-columns: minmax(0, 1.35fr) minmax(300px, .9fr);
      gap: 18px;
      align-items: stretch;
    }}
    .gauge-card, .meta-card {{
      border-radius: 26px;
      border: 1px solid var(--line);
      background: var(--panel);
    }}
    .gauge-wrap {{
      padding: 22px 20px 18px;
    }}
    .gauge-stage {{
      position: relative;
      max-width: 640px;
      margin: 0 auto;
      padding-top: 4px;
      min-height: 480px;
    }}
    .gauge-svg {{
      display: block;
      width: 100%;
      height: auto;
      overflow: visible;
    }}
    .gauge-track {{
      fill: none;
      stroke: var(--track);
      stroke-width: 16;
      stroke-linecap: round;
    }}
    .gauge-fill {{
      fill: none;
      stroke: url(#gaugeGradient);
      stroke-width: 16;
      stroke-linecap: round;
      stroke-dasharray: 100;
      stroke-dashoffset: 100;
      transition: stroke-dashoffset .18s ease;
    }}
    .needle {{
      transform-origin: 320px 280px;
      transform: rotate(-110deg);
      transition: transform .18s ease;
    }}
    .needle-line {{
      stroke: #37465a;
      stroke-width: 6;
      stroke-linecap: round;
    }}
    .needle-core {{
      fill: url(#needleGradient);
      stroke: #d5ddea;
      stroke-width: 5;
    }}
    .gauge-readout {{
      position: absolute;
      left: 50%;
      top: 60%;
      transform: translate(-50%, -8%);
      width: min(72%, 380px);
      text-align: center;
      pointer-events: none;
      z-index: 2;
    }}
    .gauge-value {{
      font-size: clamp(58px, 11vw, 98px);
      line-height: .88;
      font-weight: 900;
      letter-spacing: -.07em;
    }}
    .gauge-unit {{
      margin-top: 10px;
      color: var(--muted);
      font-size: 14px;
      letter-spacing: .18em;
    }}
    .gauge-caption {{
      margin-top: 8px;
      color: var(--text);
      font-size: 15px;
      font-weight: 700;
      letter-spacing: .12em;
      text-transform: uppercase;
    }}
    .progress-rail {{
      width: 100%;
      height: 10px;
      border-radius: 999px;
      overflow: hidden;
      background: var(--track);
    }}
    .progress-bar {{
      width: 0%;
      height: 100%;
      border-radius: 999px;
      background: linear-gradient(90deg, var(--accent), var(--accent-2));
      transition: width .18s ease;
    }}
    .meta-card {{
      display: flex;
      flex-direction: column;
      padding: 18px 18px 16px;
      gap: 14px;
    }}
    .stats-grid {{
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 14px;
    }}
    .stat {{
      min-width: 0;
      padding: 16px;
      border-radius: 22px;
      background: var(--panel-soft);
      border: 1px solid var(--line);
    }}
    .stat-label {{
      color: var(--muted);
      font-size: 11px;
      font-weight: 800;
      letter-spacing: .14em;
      text-transform: uppercase;
      margin-bottom: 10px;
    }}
    .stat-value {{
      min-height: 58px;
      display: flex;
      align-items: flex-end;
      gap: 4px;
      flex-wrap: nowrap;
      font-weight: 900;
      line-height: .95;
      white-space: nowrap;
    }}
    .stat-number {{
      font-size: clamp(28px, 4vw, 38px);
      letter-spacing: -.06em;
      flex: 0 1 auto;
      min-width: 0;
    }}
    .stat-unit {{
      color: var(--muted);
      font-size: 11px;
      letter-spacing: .08em;
      font-weight: 700;
      flex: 0 0 auto;
      white-space: nowrap;
    }}
    .controls {{
      margin-top: auto;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: flex-end;
      padding: 8px 2px 2px;
    }}
    .start-button {{
      appearance: none;
      border: 0;
      inline-size: 128px;
      block-size: 128px;
      min-height: 128px;
      border-radius: 50%;
      padding: 0;
      cursor: pointer;
      color: #ffffff;
      font-size: 22px;
      font-weight: 900;
      letter-spacing: .04em;
      text-transform: uppercase;
      background: linear-gradient(135deg, var(--accent-2), var(--accent));
      box-shadow: 0 12px 26px rgba(63, 134, 255, 0.22);
      transition: transform .18s ease, opacity .18s ease;
    }}
    .start-button:hover {{ transform: translateY(-1px); }}
    .start-button:disabled {{
      opacity: .64;
      cursor: wait;
      transform: none;
    }}
    @media (max-width: 900px) {{
      .dashboard {{ grid-template-columns: 1fr; }}
      .meta-card {{ order: 2; }}
      .gauge-wrap {{ min-height: 0; }}
    }}
    @media (max-width: 640px) {{
      body {{ padding: 10px; }}
      .inner {{ padding: 18px; }}
      .topbar {{
        flex-direction: column;
        align-items: stretch;
      }}
      .expiry {{
        min-width: 0;
        text-align: left;
      }}
      .stats-grid {{ grid-template-columns: 1fr 1fr; }}
      .gauge-readout {{
        width: min(82%, 360px);
        top: 59%;
        transform: translate(-50%, -8%);
      }}
    }}
    @media (max-width: 460px) {{
      .stats-grid {{ grid-template-columns: 1fr; }}
      .gauge-stage {{ min-height: 344px; }}
      .gauge-value {{ font-size: 62px; }}
      .stat-number {{ font-size: 34px; }}
      .stat-unit {{ font-size: 10px; letter-spacing: .06em; }}
      .start-button {{
        inline-size: 112px;
        block-size: 112px;
        min-height: 112px;
        font-size: 20px;
      }}
    }}
  </style>
</head>
<body>
  <main class="shell">
    <div class="inner">
      <div class="topbar">
        <div>
          <div class="eyebrow">Тест Скорости</div>
          <h1>TransferHub</h1>
          <div class="subline">Проверка идет между клиентом и VPS через порт 443.</div>
        </div>
        <div class="expiry">
          <span class="expiry-label">Ссылка действует до</span>
          <span class="expiry-value" id="expiresAt">Загрузка локального времени...</span>
        </div>
      </div>

      <div class="dashboard">
        <section class="gauge-card">
          <div class="gauge-wrap">
            <div class="gauge-stage">
              <svg class="gauge-svg" viewBox="0 0 640 380" aria-hidden="true">
                <defs>
                  <linearGradient id="gaugeGradient" x1="0%" y1="0%" x2="100%" y2="0%">
                    <stop offset="0%" stop-color="#1f7dff"/>
                    <stop offset="55%" stop-color="#48b9ff"/>
                    <stop offset="100%" stop-color="#8ae1ff"/>
                  </linearGradient>
                  <linearGradient id="needleGradient" x1="0%" y1="0%" x2="100%" y2="100%">
                    <stop offset="0%" stop-color="#8be2ff"/>
                    <stop offset="100%" stop-color="#1f7dff"/>
                  </linearGradient>
                </defs>
                <path class="gauge-track" d="M100 280 A220 220 0 0 1 540 280" pathLength="100"></path>
                <path class="gauge-fill" id="gaugeFill" d="M100 280 A220 220 0 0 1 540 280" pathLength="100"></path>
                <g class="needle" id="needle">
                  <line class="needle-line" x1="320" y1="280" x2="320" y2="132"></line>
                  <circle class="needle-core" cx="320" cy="280" r="20"></circle>
                  <circle fill="#6d7888" cx="320" cy="280" r="7"></circle>
                </g>
              </svg>
              <div class="gauge-readout">
                <div class="gauge-value" id="gaugeValue">0.00</div>
                <div class="gauge-unit" id="gaugeUnit">Мбит/с</div>
                <div class="gauge-caption" id="gaugeCaption">Скачивание</div>
              </div>
            </div>

            <div class="progress-rail"><div class="progress-bar" id="progressBar"></div></div>
          </div>
        </section>

        <aside class="meta-card">
          <div class="stats-grid">
            <section class="stat">
              <div class="stat-label">Пинг</div>
              <div class="stat-value" id="ping"></div>
            </section>
            <section class="stat">
              <div class="stat-label">Джиттер</div>
              <div class="stat-value" id="jitter"></div>
            </section>
            <section class="stat">
              <div class="stat-label">Скачивание</div>
              <div class="stat-value" id="download"></div>
            </section>
            <section class="stat">
              <div class="stat-label">Отдача</div>
              <div class="stat-value" id="upload"></div>
            </section>
          </div>

          <div class="controls">
            <button class="start-button" id="startBtn" type="button">Тест</button>
          </div>
        </aside>
      </div>
    </div>
  </main>

  <script src="./speedtest.js"></script>
  <script>
    const slug = {slug!r};
    const basePath = `/${{slug}}`;
    const expiresAtUnix = {expires_at};
    const s = new Speedtest();

    const btn = document.getElementById('startBtn');
    const expiresAtEl = document.getElementById('expiresAt');
    const gaugeValueEl = document.getElementById('gaugeValue');
    const gaugeUnitEl = document.getElementById('gaugeUnit');
    const gaugeCaptionEl = document.getElementById('gaugeCaption');
    const progressBarEl = document.getElementById('progressBar');
    const needleEl = document.getElementById('needle');
    const gaugeFillEl = document.getElementById('gaugeFill');

    s.setParameter('test_order', 'IP_D_P_U');
    s.setParameter('time_auto', false);
    s.setParameter('time_dl_max', 12);
    s.setParameter('time_ul_max', 16);
    s.setParameter('count_ping', 10);
    s.setParameter('xhr_dlMultistream', 3);
    s.setParameter('xhr_ulMultistream', 6);
    s.setParameter('xhr_ul_blob_megabytes', 8);
    s.setParameter('garbagePhp_chunkSize', 100);
    s.setParameter('url_dl', `${{basePath}}/backend/garbage.php`);
    s.setParameter('url_ul', `${{basePath}}/backend/empty.php`);
    s.setParameter('url_ping', `${{basePath}}/backend/empty.php`);
    s.setParameter('url_getIp', `${{basePath}}/backend/getIP.php`);

    function renderLocalExpiry() {{
      const expires = new Date(expiresAtUnix * 1000);
      expiresAtEl.textContent = expires.toLocaleString(undefined, {{
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit',
        second: '2-digit'
      }});
    }}

    function formatNumber(value) {{
      const num = Number.parseFloat(value);
      if (!Number.isFinite(num) || num <= 0) return null;
      if (num >= 100) return num.toFixed(0);
      if (num >= 10) return num.toFixed(1);
      return num.toFixed(2);
    }}

    function setMetric(id, value, unit) {{
      const el = document.getElementById(id);
      const formatted = formatNumber(value);
      if (!formatted) {{
        el.innerHTML = `<span class="stat-number">-</span><span class="stat-unit">${{unit}}</span>`;
        return;
      }}
      el.innerHTML = `<span class="stat-number">${{formatted}}</span><span class="stat-unit">${{unit}}</span>`;
    }}

    function gaugeAngleFor(value, maxValue) {{
      const safe = Math.max(0, Number.parseFloat(value) || 0);
      const capped = Math.min(safe, maxValue);
      const ratio = Math.log10(capped + 1) / Math.log10(maxValue + 1);
      return -110 + ratio * 220;
    }}

    function setGauge(value, unit, caption, maxValue) {{
      const numeric = Math.max(0, Number.parseFloat(value) || 0);
      const ratio = Math.min(1, Math.log10(numeric + 1) / Math.log10(maxValue + 1));
      const angle = gaugeAngleFor(numeric, maxValue);
      gaugeValueEl.textContent = formatNumber(numeric) || '0.00';
      gaugeUnitEl.textContent = unit;
      gaugeCaptionEl.textContent = caption;
      needleEl.style.transform = `rotate(${{angle}}deg)`;
      gaugeFillEl.style.strokeDashoffset = `${{100 - ratio * 100}}`;
    }}

    function setProgress(percent) {{
      const safePercent = Math.max(0, Math.min(100, percent));
      progressBarEl.style.width = `${{safePercent}}%`;
    }}

    function resetMetrics() {{
      setMetric('ping', null, 'мс');
      setMetric('jitter', null, 'мс');
      setMetric('download', null, 'Мбит/с');
      setMetric('upload', null, 'Мбит/с');
      setGauge(0, 'Мбит/с', 'Скачивание', 1000);
      setProgress(0);
    }}

    function updateProgress(data) {{
      if (data.testState === 1) {{
        setProgress((data.dlProgress || 0) * 45);
        setGauge(data.dlStatus, 'Мбит/с', 'Скачивание', 1000);
      }} else if (data.testState === 2) {{
        setProgress(45 + (data.pingProgress || 0) * 15);
        setGauge(data.pingStatus, 'мс', 'Пинг', 300);
      }} else if (data.testState === 3) {{
        setProgress(60 + (data.ulProgress || 0) * 40);
        setGauge(data.ulStatus, 'Мбит/с', 'Отдача', 1000);
      }} else if (data.testState === 4) {{
        setProgress(100);
      }}
    }}

    s.onupdate = function(data) {{
      setMetric('download', data.dlStatus, 'Мбит/с');
      setMetric('upload', data.ulStatus, 'Мбит/с');
      setMetric('ping', data.pingStatus, 'мс');
      setMetric('jitter', data.jitterStatus, 'мс');
      updateProgress(data);
    }};

    s.onend = function(aborted) {{
      btn.disabled = false;
      btn.textContent = 'Тест';
    }};

    btn.addEventListener('click', function() {{
      btn.disabled = true;
      btn.textContent = '...';
      resetMetrics();
      s.start();
    }});

    renderLocalExpiry();
    resetMetrics();
  </script>
</body>
</html>
"""


class LibreSpeedHandler(BaseHTTPRequestHandler):
    server_version = ""

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
        expires_at = cleanup_and_read_links().get(token)
        if not expires_at:
            self._serve_not_found()
            return

        if action in ("", "/") and method in ("GET", "HEAD"):
            self._serve_page(slug, expires_at)
            return
        if action == "/speedtest.js" and method in ("GET", "HEAD"):
            self._serve_static("speedtest.js", "application/javascript; charset=utf-8")
            return
        if action == "/speedtest_worker.js" and method in ("GET", "HEAD"):
            self._serve_static("speedtest_worker.js", "application/javascript; charset=utf-8")
            return
        if action == "/backend/empty.php":
            if method == "POST":
                self._drain_request_body()
            self._send_empty(200)
            return
        if action == "/backend/getIP.php" and method in ("GET", "HEAD"):
            self._serve_get_ip()
            return
        if action == "/backend/garbage.php" and method in ("GET", "HEAD"):
            self._serve_garbage(parsed.query)
            return

        self._serve_not_found()

    def _extract_slug_and_action(self, path, prefix):
        if not prefix:
            return None, None
        parts = [part for part in path.split("?")[0].split("/") if part]
        if not parts:
            return None, None
        slug = parts[0]
        if not slug.startswith(prefix):
            return None, None
        token = slug[len(prefix):]
        if len(token) != TOKEN_LEN or not token.isalnum():
            return None, None
        action = "/" + "/".join(parts[1:]) if len(parts) > 1 else ""
        return slug, action

    def _serve_page(self, slug, expires_at):
        body = page_html(slug, expires_at).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _serve_static(self, filename, content_type):
        path = VENDOR_DIR / filename
        if not path.exists():
            self._serve_not_found()
            return
        body = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _serve_get_ip(self):
        ip = self.headers.get("X-Forwarded-For", self.client_address[0]).split(",")[0].strip()
        body = json.dumps({"processedString": ip, "rawIspInfo": ""}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _serve_garbage(self, query):
        params = parse_qs(query)
        chunk_mb = 100
        raw = params.get("ckSize", ["100"])[0]
        if raw.isdigit():
            chunk_mb = max(1, min(int(raw), 256))
        total_size = chunk_mb * 1024 * 1024
        block = b"0" * 65536
        remaining = total_size
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(total_size))
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.end_headers()
        if self.command == "HEAD":
            return
        try:
            while remaining > 0:
                piece = block[: min(len(block), remaining)]
                self.wfile.write(piece)
                remaining -= len(piece)
        except BrokenPipeError:
            return

    def _drain_request_body(self):
        remaining = int(self.headers.get("Content-Length", "0") or "0")
        while remaining > 0:
            chunk = self.rfile.read(min(65536, remaining))
            if not chunk:
                break
            remaining -= len(chunk)

    def _send_empty(self, status):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.end_headers()

    def _serve_not_found(self):
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.end_headers()


if __name__ == "__main__":
    ThreadingHTTPServer((HOST, PORT), LibreSpeedHandler).serve_forever()
