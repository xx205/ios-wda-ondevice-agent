#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import html
import http.server
import json
import os
import socketserver
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


DEFAULT_BASE_URL = os.environ.get("WDA_URL", "http://127.0.0.1:8100")


class ApiError(RuntimeError):
    pass


def _now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _join_url(base_url: str, path: str) -> str:
    base = (base_url or "").rstrip("/")
    if not path.startswith("/"):
        path = "/" + path
    return base + path


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _write_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def _write_text(path: Path, data: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(data, encoding="utf-8")


@dataclass(frozen=True)
class HttpResult:
    status: int
    headers: Dict[str, str]
    body: bytes


def http_request_json(
    *,
    method: str,
    url: str,
    payload: Optional[Dict[str, Any]] = None,
    timeout: float = 20.0,
) -> Any:
    headers = {"Accept": "application/json"}
    data = None
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url=url, method=method, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
            charset = resp.headers.get_content_charset() or "utf-8"
            text = body.decode(charset, errors="replace")
            try:
                return json.loads(text)
            except Exception as e:  # noqa: BLE001
                raise ApiError(f"Non-JSON response from {url}: {e}\n{text[:2000]}") from e
    except urllib.error.HTTPError as e:
        body = e.read() if e.fp else b""
        msg = body.decode("utf-8", errors="replace")
        raise ApiError(f"HTTP {e.code} {e.reason} for {url}\n{msg[:2000]}") from e
    except urllib.error.URLError as e:
        raise ApiError(f"Failed to connect to {url}: {e}") from e
    except Exception as e:  # noqa: BLE001
        raise ApiError(f"Request failed for {url}: {e}") from e


def unwrap_wda_value(obj: Any) -> Any:
    # WebDriverAgent's FBResponseWithObject wraps responses as:
    # {"value": <payload>, "sessionId": ...}
    if isinstance(obj, dict) and "value" in obj:
        return obj.get("value")
    return obj


def api_get(base_url: str, path: str, timeout: float) -> Any:
    return http_request_json(method="GET", url=_join_url(base_url, path), timeout=timeout)


def api_post(base_url: str, path: str, payload: Optional[Dict[str, Any]], timeout: float) -> Any:
    return http_request_json(method="POST", url=_join_url(base_url, path), payload=payload, timeout=timeout)


def parse_json_arg(value: str) -> Dict[str, Any]:
    value = value.strip()
    if value.startswith("@"):
        p = Path(value[1:])
        return json.loads(_read_text(p))
    return json.loads(value)


def pretty_json(obj: Any) -> str:
    return json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=False)


def export_chat_html(
    *,
    base_url: str,
    out_path: Path,
    timeout: float,
    max_screenshot_steps: Optional[int],
) -> None:
    status = unwrap_wda_value(api_get(base_url, "/agent/status", timeout))
    chat = unwrap_wda_value(api_get(base_url, "/agent/chat", timeout))
    logs = unwrap_wda_value(api_get(base_url, "/agent/logs", timeout))

    items: List[Dict[str, Any]] = []
    if isinstance(chat, dict) and isinstance(chat.get("items"), list):
        items = [i for i in chat["items"] if isinstance(i, dict)]

    step_values: List[int] = []
    for item in items:
        try:
            step = int(item.get("step"))
            if step >= 0:
                step_values.append(step)
        except Exception:  # noqa: BLE001
            continue

    unique_steps = sorted(set(step_values))
    if max_screenshot_steps is not None and max_screenshot_steps > 0:
        unique_steps = unique_steps[-max_screenshot_steps:]

    screenshots_by_step: Dict[int, str] = {}
    for step in unique_steps:
        resp = unwrap_wda_value(api_get(base_url, f"/agent/step_screenshot?step={step}", timeout))
        if isinstance(resp, dict) and resp.get("ok") is True and isinstance(resp.get("png_base64"), str):
            screenshots_by_step[step] = resp["png_base64"]

    title = "WDA On‑Device Agent — Chat export"
    css = """
      :root{color-scheme:light dark;--bg:#fff;--fg:#111;--muted:#666;--card:#f6f6f6;--border:#ccc;--primary:#0a84ff;--radius:12px;}
      @media (prefers-color-scheme: dark){:root{--bg:#0b0b0c;--fg:#f2f2f2;--muted:#b0b0b0;--card:#1c1c1e;--border:#3a3a3c;--primary:#0a84ff;}}
      html,body{height:100%;}
      body{margin:0;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Helvetica,Arial,sans-serif;background:var(--bg);color:var(--fg);}
      .wrap{max-width:980px;margin:0 auto;padding:20px;}
      h1{margin:0 0 6px 0;font-size:18px;}
      .meta{color:var(--muted);font-size:13px;margin-bottom:14px;}
      .card{background:var(--card);border:1px solid var(--border);border-radius:var(--radius);padding:12px;margin:12px 0;}
      .row{display:flex;gap:12px;flex-wrap:wrap;}
      .pill{display:inline-block;padding:3px 8px;border-radius:999px;border:1px solid var(--border);font-size:12px;color:var(--muted);}
      .kind{color:var(--primary);border-color:var(--primary);}
      pre{white-space:pre-wrap;word-break:break-word;font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;font-size:13px;line-height:1.35;margin:10px 0 0 0;}
      img{max-width:100%;border-radius:12px;border:1px solid var(--border);background:#000;}
      details{margin-top:10px;}
      details summary{cursor:pointer;color:var(--muted);}
      .col{flex:1 1 360px;min-width:320px;}
    """

    def esc(s: Any) -> str:
        return html.escape("" if s is None else str(s))

    def render_raw_details(raw_value: Any) -> str:
        if raw_value is None:
            return ""
        return (
            "<details><summary>Raw JSON</summary>"
            f"<pre>{esc(raw_value)}</pre>"
            "</details>"
        )

    def render_item(item: Dict[str, Any]) -> str:
        step = item.get("step")
        kind = item.get("kind") or ""
        attempt = item.get("attempt")
        ts = item.get("ts") or ""
        parts = [
            "<div class='card'>",
            "<div class='row'>",
            f"<span class='pill kind'>{esc(kind)}</span>",
            f"<span class='pill'>step {esc(step)}</span>",
        ]
        if attempt is not None:
            parts.append(f"<span class='pill'>attempt {esc(attempt)}</span>")
        if ts:
            parts.append(f"<span class='pill'>{esc(ts)}</span>")
        parts.append("</div>")

        step_i = None
        try:
            step_i = int(step)
        except Exception:  # noqa: BLE001
            step_i = None
        if kind == "request" and step_i is not None and step_i in screenshots_by_step:
            parts.append(
                "<div style='margin-top:10px;'>"
                f"<img alt='screenshot step {step_i}' src='data:image/png;base64,{screenshots_by_step[step_i]}' />"
                "</div>"
            )

        if kind == "request":
            parts.append(f"<pre>{esc(item.get('text') or '')}</pre>")
        elif kind == "response":
            content = item.get("content") or ""
            parts.append(f"<pre>{esc(content)}</pre>")
            if item.get("reasoning"):
                parts.append("<details><summary>Reasoning</summary>")
                parts.append(f"<pre>{esc(item.get('reasoning'))}</pre>")
                parts.append("</details>")
        else:
            parts.append(f"<pre>{esc(pretty_json(item))}</pre>")

        parts.append(render_raw_details(item.get("raw")))
        parts.append("</div>")
        return "".join(parts)

    status_pre = esc(pretty_json(status))
    logs_lines: List[str] = []
    if isinstance(logs, dict) and isinstance(logs.get("lines"), list):
        logs_lines = [str(x) for x in logs["lines"]]
    logs_text = esc("\n".join(logs_lines))

    rendered = [
        "<!doctype html>",
        "<html><head>",
        "<meta charset='utf-8' />",
        "<meta name='viewport' content='width=device-width, initial-scale=1' />",
        f"<title>{esc(title)}</title>",
        f"<style>{css}</style>",
        "</head><body>",
        "<div class='wrap'>",
        f"<h1>{esc(title)}</h1>",
        f"<div class='meta'>Generated at {_now_iso()} · base_url={esc(base_url)}</div>",
        "<div class='card'>",
        "<div class='row'>",
        "<div class='col'>",
        "<div class='pill'>Status</div>",
        f"<pre>{status_pre}</pre>",
        "</div>",
        "<div class='col'>",
        "<div class='pill'>Logs</div>",
        f"<pre>{logs_text}</pre>",
        "</div>",
        "</div>",
        "</div>",
        "<div class='card'>",
        f"<div class='pill'>Chat items ({len(items)})</div>",
        "</div>",
    ]

    for item in items:
        rendered.append(render_item(item))

    rendered.extend(["</div>", "</body></html>"])
    _write_text(out_path, "".join(rendered))


def _read_request_body(handler: http.server.BaseHTTPRequestHandler, max_bytes: int = 2_000_000) -> bytes:
    length = handler.headers.get("Content-Length")
    if length is None:
        return b""
    try:
        n = int(length)
    except Exception:  # noqa: BLE001
        n = 0
    if n <= 0:
        return b""
    if n > max_bytes:
        raise ApiError(f"Request too large: {n} bytes")
    return handler.rfile.read(n)


def _send_json(handler: http.server.BaseHTTPRequestHandler, obj: Any, status: int = 200) -> None:
    data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


def _send_bytes(handler: http.server.BaseHTTPRequestHandler, data: bytes, content_type: str, status: int = 200) -> None:
    handler.send_response(status)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


def _make_live_page_html(base_url: str, poll_ms: int) -> str:
    # A tiny "attach to a running Runner" dashboard.
    # Browser talks to this local server (same-origin), which proxies requests to the Runner.
    esc_base = html.escape(base_url)
    return f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>WDA Live Console</title>
  <style>
    :root{{color-scheme:light dark;--bg:#fff;--fg:#111;--muted:#666;--card:#f6f6f6;--border:#ccc;--primary:#0a84ff;--radius:12px;}}
    @media (prefers-color-scheme: dark){{:root{{--bg:#0b0b0c;--fg:#f2f2f2;--muted:#b0b0b0;--card:#1c1c1e;--border:#3a3a3c;--primary:#0a84ff;}}}}
    html,body{{height:100%;}}
    body{{margin:0;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Helvetica,Arial,sans-serif;background:var(--bg);color:var(--fg);}}
    .wrap{{max-width:1100px;margin:0 auto;padding:14px;}}
    h1{{margin:0 0 6px 0;font-size:16px;}}
    .meta{{color:var(--muted);font-size:12px;margin-bottom:12px;}}
    .row{{display:flex;gap:12px;flex-wrap:wrap;align-items:flex-start;}}
    .col{{flex:1 1 520px;min-width:340px;}}
    .card{{background:var(--card);border:1px solid var(--border);border-radius:var(--radius);padding:12px;margin:12px 0;}}
    .toolbar{{display:flex;gap:8px;align-items:center;flex-wrap:wrap;}}
    button{{border:1px solid var(--border);border-radius:10px;background:transparent;color:inherit;padding:8px 10px;font-size:13px;cursor:pointer;}}
    button.primary{{border-color:var(--primary);color:var(--primary);}}
    button.danger{{border-color:#ff3b30;color:#ff3b30;}}
    button:disabled{{opacity:.5;cursor:not-allowed;}}
    pre{{white-space:pre-wrap;word-break:break-word;font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;font-size:12.5px;line-height:1.35;margin:0;}}
    img{{max-width:100%;border-radius:12px;border:1px solid var(--border);background:#000;}}
    details{{margin-top:8px;}}
    details summary{{cursor:pointer;color:var(--muted);}}
    .pill{{display:inline-block;padding:3px 8px;border-radius:999px;border:1px solid var(--border);font-size:12px;color:var(--muted);}}
    .pill.kind{{border-color:var(--primary);color:var(--primary);}}
    .item{{margin-top:10px;}}
    .item-head{{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:6px;}}
    .split{{display:flex;gap:10px;flex-wrap:wrap;}}
    .split .left{{flex:1 1 320px;min-width:280px;}}
    .split .right{{flex:1 1 320px;min-width:280px;}}
    .muted{{color:var(--muted);}}
    .err{{color:#ff3b30;white-space:pre-wrap;word-break:break-word;font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;font-size:12.5px;}}
    .logs{{max-height:340px;overflow:auto;}}
    .chat{{max-height:650px;overflow:auto;}}
    .kv{{display:grid;grid-template-columns:160px 1fr;gap:8px 10px;}}
    .kv .k{{color:var(--muted);font-size:12px;}}
    .kv .v{{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;font-size:12px;}}
  </style>
</head>
<body>
  <div class="wrap">
    <h1>WDA Live Console</h1>
    <div class="meta">Runner base_url: <span class="pill">{esc_base}</span> · This page attaches to a running Runner via /agent/*.</div>

    <div class="card">
      <div class="toolbar">
        <button class="primary" id="btnRefresh">Refresh now</button>
        <button id="btnStart">Start</button>
        <button id="btnStop">Stop</button>
        <button class="danger" id="btnReset">Reset runtime</button>
        <button class="danger" id="btnFactoryReset">Factory reset</button>
        <span class="pill" id="pillStatus">status: ?</span>
        <span class="pill" id="pillTokens">tokens: ?</span>
      </div>
      <div style="margin-top:10px" class="kv">
        <div class="k">running</div><div class="v" id="kvRunning">?</div>
        <div class="k">last_message</div><div class="v" id="kvLastMessage">?</div>
      </div>
      <div id="errBox" class="err" style="margin-top:10px; display:none;"></div>
    </div>

    <div class="row">
      <div class="col">
        <div class="card">
          <div class="pill">Logs</div>
          <div class="logs" style="margin-top:10px;"><pre id="logsPre"></pre></div>
        </div>
      </div>
      <div class="col">
        <div class="card">
          <div class="pill">Chat</div>
          <div class="chat" id="chatBox" style="margin-top:10px;"></div>
        </div>
      </div>
    </div>
  </div>

  <script>
    const POLL_MS = {int(poll_ms)};
    const $ = (id) => document.getElementById(id);
    const errBox = $("errBox");
    function showErr(msg) {{
      if (!msg) {{
        errBox.style.display = "none";
        errBox.textContent = "";
        return;
      }}
      errBox.style.display = "block";
      errBox.textContent = String(msg);
    }}
    function fmt(n) {{
      if (n === null || n === undefined) return "?";
      if (typeof n === "number") return String(n);
      return String(n);
    }}

    async function api(path, method="GET", body=null) {{
      const opt = {{ method }};
      if (body !== null) {{
        opt.headers = {{ "Content-Type": "application/json" }};
        opt.body = JSON.stringify(body);
      }}
      const resp = await fetch(path, opt);
      const text = await resp.text();
      let data = null;
      try {{ data = JSON.parse(text); }} catch(e) {{ data = {{ raw: text }}; }}
      if (!resp.ok) {{
        const m = data && data.error ? data.error : (data && data.raw ? data.raw : (resp.status + " " + resp.statusText));
        throw new Error(m);
      }}
      return data;
    }}

    function renderChat(items) {{
      const box = $("chatBox");
      box.textContent = "";
      for (const it of items) {{
        const kind = it.kind || "";
        const step = it.step;
        const attempt = it.attempt;
        const ts = it.ts || "";

        const wrap = document.createElement("div");
        wrap.className = "item";

        const head = document.createElement("div");
        head.className = "item-head";
        const pillKind = document.createElement("span");
        pillKind.className = "pill kind";
        pillKind.textContent = kind || "item";
        head.appendChild(pillKind);
        const pillStep = document.createElement("span");
        pillStep.className = "pill";
        pillStep.textContent = "step " + fmt(step);
        head.appendChild(pillStep);
        if (attempt !== null && attempt !== undefined) {{
          const pillAttempt = document.createElement("span");
          pillAttempt.className = "pill";
          pillAttempt.textContent = "attempt " + fmt(attempt);
          head.appendChild(pillAttempt);
        }}
        if (ts) {{
          const pillTs = document.createElement("span");
          pillTs.className = "pill";
          pillTs.textContent = ts;
          head.appendChild(pillTs);
        }}
        wrap.appendChild(head);

        if (kind === "request" && Number.isFinite(Number(step))) {{
          const img = document.createElement("img");
          img.alt = "screenshot step " + step;
          img.src = "/img/step?step=" + encodeURIComponent(step);
          wrap.appendChild(img);
        }}

        const pre = document.createElement("pre");
        if (kind === "request") {{
          pre.textContent = it.text || "";
        }} else if (kind === "response") {{
          pre.textContent = it.content || "";
        }} else {{
          pre.textContent = JSON.stringify(it, null, 2);
        }}
        pre.style.marginTop = "8px";
        wrap.appendChild(pre);

        if (kind === "response" && it.reasoning) {{
          const det = document.createElement("details");
          const sum = document.createElement("summary");
          sum.textContent = "Reasoning";
          const preR = document.createElement("pre");
          preR.textContent = it.reasoning;
          det.appendChild(sum);
          det.appendChild(preR);
          wrap.appendChild(det);
        }}

        if (it.raw) {{
          const det = document.createElement("details");
          const sum = document.createElement("summary");
          sum.textContent = "Raw JSON";
          const preRaw = document.createElement("pre");
          preRaw.textContent = String(it.raw);
          det.appendChild(sum);
          det.appendChild(preRaw);
          wrap.appendChild(det);
        }}

        box.appendChild(wrap);
      }}
    }}

    async function refreshAll() {{
      try {{
        showErr(null);
        const st = await api("/api/status");
        const logs = await api("/api/logs");
        const chat = await api("/api/chat");

        $("kvRunning").textContent = fmt(st.running);
        $("kvLastMessage").textContent = fmt(st.last_message);

        const running = !!st.running;
        $("pillStatus").textContent = "status: " + (running ? "running" : "stopped");

        const tu = st.token_usage || {{}};
        const t = "req=" + fmt(tu.requests) + " in=" + fmt(tu.input_tokens) + " out=" + fmt(tu.output_tokens) + " cached=" + fmt(tu.cached_tokens) + " total=" + fmt(tu.total_tokens);
        $("pillTokens").textContent = "tokens: " + t;

        const lines = (logs && logs.lines && Array.isArray(logs.lines)) ? logs.lines : [];
        $("logsPre").textContent = lines.join("\\n");

        const items = (chat && chat.items && Array.isArray(chat.items)) ? chat.items : [];
        renderChat(items);
      }} catch (e) {{
        showErr(e && e.message ? e.message : String(e));
      }}
    }}

    $("btnRefresh").onclick = refreshAll;
    $("btnStart").onclick = async () => {{
      try {{
        showErr(null);
        await api("/api/start", "POST", null);
        await refreshAll();
      }} catch(e) {{
        showErr(e && e.message ? e.message : String(e));
      }}
    }};
    $("btnStop").onclick = async () => {{
      try {{
        showErr(null);
        await api("/api/stop", "POST", null);
        await refreshAll();
      }} catch(e) {{
        showErr(e && e.message ? e.message : String(e));
      }}
    }};
    $("btnReset").onclick = async () => {{
      if (!confirm("Reset runtime?")) return;
      try {{
        showErr(null);
        await api("/api/reset", "POST", null);
        await refreshAll();
      }} catch(e) {{
        showErr(e && e.message ? e.message : String(e));
      }}
    }};
    $("btnFactoryReset").onclick = async () => {{
      if (!confirm("Factory reset? This clears local config + runtime state.")) return;
      try {{
        showErr(null);
        await api("/api/factory_reset", "POST", null);
        await refreshAll();
      }} catch(e) {{
        showErr(e && e.message ? e.message : String(e));
      }}
    }};

    // Auto refresh (optional).
    refreshAll();
    if (POLL_MS > 0) {{
      setInterval(refreshAll, POLL_MS);
    }}
  </script>
</body>
</html>
"""


class _ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def run_live_server(*, base_url: str, host: str, port: int, timeout: float, poll_seconds: float) -> None:
    base_url = base_url.rstrip("/")

    poll_ms = 0
    if poll_seconds and poll_seconds > 0:
        poll_ms = max(250, int(poll_seconds * 1000))
    page_html = _make_live_page_html(base_url, poll_ms)

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, fmt: str, *args: Any) -> None:
            # quiet
            return

        def do_GET(self) -> None:  # noqa: N802
            try:
                parsed = urllib.parse.urlparse(self.path)
                path = parsed.path
                qs = urllib.parse.parse_qs(parsed.query)

                if path == "/" or path == "/index.html":
                    _send_bytes(self, page_html.encode("utf-8"), "text/html; charset=utf-8")
                    return

                if path.startswith("/api/"):
                    target = "/agent" + path[len("/api") :]
                    if target == "/agent/step_screenshot":
                        step = (qs.get("step") or [None])[0]
                        if not step:
                            _send_json(self, {"ok": False, "error": "Missing query parameter: step"}, status=400)
                            return
                        target = f"/agent/step_screenshot?step={urllib.parse.quote(str(step))}"
                    data = unwrap_wda_value(api_get(base_url, target, timeout))
                    _send_json(self, data)
                    return

                if path == "/img/step":
                    step = (qs.get("step") or [None])[0]
                    if not step:
                        _send_bytes(self, b"", "text/plain; charset=utf-8", status=400)
                        return
                    resp = unwrap_wda_value(api_get(base_url, f"/agent/step_screenshot?step={urllib.parse.quote(str(step))}", timeout))
                    if not isinstance(resp, dict) or resp.get("ok") is not True or not isinstance(resp.get("png_base64"), str):
                        _send_bytes(self, b"", "text/plain; charset=utf-8", status=404)
                        return
                    png = base64.b64decode(resp["png_base64"].encode("ascii"), validate=False)
                    _send_bytes(self, png, "image/png")
                    return

                _send_bytes(self, b"Not found", "text/plain; charset=utf-8", status=404)
            except Exception as e:  # noqa: BLE001
                _send_json(self, {"ok": False, "error": str(e)}, status=500)

        def do_POST(self) -> None:  # noqa: N802
            try:
                parsed = urllib.parse.urlparse(self.path)
                path = parsed.path
                if not path.startswith("/api/"):
                    _send_bytes(self, b"Not found", "text/plain; charset=utf-8", status=404)
                    return

                body = _read_request_body(self)
                payload = None
                if body:
                    try:
                        payload = json.loads(body.decode("utf-8", errors="replace"))
                    except Exception as e:  # noqa: BLE001
                        _send_json(self, {"ok": False, "error": f"Invalid JSON body: {e}"}, status=400)
                        return

                target = "/agent" + path[len("/api") :]
                if target not in {
                    "/agent/config",
                    "/agent/start",
                    "/agent/stop",
                    "/agent/reset",
                    "/agent/factory_reset",
                }:
                    _send_json(self, {"ok": False, "error": "Unsupported endpoint"}, status=404)
                    return
                data = unwrap_wda_value(api_post(base_url, target, payload, timeout))
                _send_json(self, data)
            except Exception as e:  # noqa: BLE001
                _send_json(self, {"ok": False, "error": str(e)}, status=500)

    httpd = _ThreadingHTTPServer((host, port), Handler)
    url = f"http://{host}:{httpd.server_address[1]}/"
    print(f"Live console: {url}", flush=True)
    print(f"Proxying to Runner: {base_url}", flush=True)
    print("Press Ctrl+C to stop.", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


def cmd_status(args: argparse.Namespace) -> int:
    st = unwrap_wda_value(api_get(args.base_url, "/agent/status", args.timeout))
    print(pretty_json(st))
    return 0


def cmd_logs(args: argparse.Namespace) -> int:
    data = unwrap_wda_value(api_get(args.base_url, "/agent/logs", args.timeout))
    lines = []
    if isinstance(data, dict) and isinstance(data.get("lines"), list):
        lines = [str(x) for x in data["lines"]]
    if args.tail and args.tail > 0:
        lines = lines[-args.tail :]
    for l in lines:
        print(l)
    return 0


def cmd_chat(args: argparse.Namespace) -> int:
    data = unwrap_wda_value(api_get(args.base_url, "/agent/chat", args.timeout))
    items = []
    if isinstance(data, dict) and isinstance(data.get("items"), list):
        items = [x for x in data["items"] if isinstance(x, dict)]

    if args.jsonl:
        out = Path(args.jsonl)
        lines = [json.dumps(x, ensure_ascii=False) for x in items]
        _write_text(out, "\n".join(lines) + ("\n" if lines else ""))
        print(f"Wrote JSONL: {out}")

    if args.html:
        out = Path(args.html)
        export_chat_html(
            base_url=args.base_url,
            out_path=out,
            timeout=args.timeout,
            max_screenshot_steps=args.max_screenshot_steps,
        )
        print(f"Wrote HTML: {out}")

    if not args.jsonl and not args.html:
        print(pretty_json({"items": items}))
    return 0


def cmd_step_screenshot(args: argparse.Namespace) -> int:
    step = int(args.step)
    resp = unwrap_wda_value(api_get(args.base_url, f"/agent/step_screenshot?step={step}", args.timeout))
    if not isinstance(resp, dict) or resp.get("ok") is not True:
        raise ApiError(pretty_json(resp))
    b64 = resp.get("png_base64") or ""
    if not isinstance(b64, str) or not b64:
        raise ApiError("Missing png_base64")
    png = base64.b64decode(b64.encode("ascii"), validate=False)
    out = Path(args.out)
    _write_bytes(out, png)
    print(f"Wrote PNG: {out}")
    return 0


def cmd_post_simple(args: argparse.Namespace) -> int:
    payload = None
    if args.payload is not None:
        payload = parse_json_arg(args.payload)
    resp = unwrap_wda_value(api_post(args.base_url, args.path, payload, args.timeout))
    print(pretty_json(resp))
    return 0


def cmd_serve(args: argparse.Namespace) -> int:
    run_live_server(
        base_url=args.base_url,
        host=args.host,
        port=args.port,
        timeout=args.timeout,
        poll_seconds=float(args.poll_seconds),
    )
    return 0


def cmd_run_until_responses(args: argparse.Namespace) -> int:
    payload: Dict[str, Any] = {}
    if args.payload is not None:
        payload = parse_json_arg(args.payload)
        if not isinstance(payload, dict):
            raise ApiError("Payload must be a JSON object")
    if args.task:
        payload["task"] = args.task
    if not payload.get("task"):
        raise ApiError("Missing task. Provide --task or include it in --payload.")

    target = int(args.responses)
    if target <= 0:
        raise ApiError("--responses must be > 0")

    poll = float(args.poll_seconds)
    if poll <= 0:
        poll = 0.5

    print(f"Starting agent… (stop after {target} response items)", flush=True)
    start_resp = unwrap_wda_value(api_post(args.base_url, "/agent/start", payload, args.timeout))
    print(pretty_json(start_resp))

    seen = 0
    deadline = time.time() + float(args.max_seconds)
    while time.time() < deadline:
        st = unwrap_wda_value(api_get(args.base_url, "/agent/status", args.timeout))
        chat = unwrap_wda_value(api_get(args.base_url, "/agent/chat", args.timeout))
        items = []
        if isinstance(chat, dict) and isinstance(chat.get("items"), list):
            items = [x for x in chat["items"] if isinstance(x, dict)]
        resp_count = 0
        for it in items:
            if it.get("kind") == "response":
                resp_count += 1
        if resp_count != seen:
            seen = resp_count
            print(f"[{_now_iso()}] responses={seen}", flush=True)

        running = False
        if isinstance(st, dict):
            running = bool(st.get("running"))
        if not running:
            print("Agent stopped before reaching target.", flush=True)
            break
        if seen >= target:
            print("Stopping agent…", flush=True)
            stop_resp = unwrap_wda_value(api_post(args.base_url, "/agent/stop", None, args.timeout))
            print(pretty_json(stop_resp))
            break
        time.sleep(poll)

    if args.export_html:
        out = Path(args.export_html)
        export_chat_html(
            base_url=args.base_url,
            out_path=out,
            timeout=args.timeout,
            max_screenshot_steps=args.max_screenshot_steps,
        )
        print(f"Wrote HTML: {out}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="wda_remote_tool.py",
        description="Local helper to control /agent endpoints and export chat with screenshots.",
    )
    p.add_argument("--base-url", default=DEFAULT_BASE_URL, help=f"WDA base URL (default: {DEFAULT_BASE_URL})")
    p.add_argument("--timeout", type=float, default=20.0, help="HTTP timeout in seconds")

    sub = p.add_subparsers(dest="cmd", required=True)

    ps = sub.add_parser("status", help="GET /agent/status")
    ps.set_defaults(func=cmd_status)

    pl = sub.add_parser("logs", help="GET /agent/logs")
    pl.add_argument("--tail", type=int, default=0, help="Print only last N lines")
    pl.set_defaults(func=cmd_logs)

    pc = sub.add_parser("chat", help="GET /agent/chat (optionally export)")
    pc.add_argument("--jsonl", help="Write chat items as JSON Lines (.jsonl)")
    pc.add_argument("--html", help="Write chat export as a single HTML file (embeds screenshots)")
    pc.add_argument(
        "--max-screenshot-steps",
        type=int,
        default=0,
        help="If > 0, embed screenshots only for the last N steps (faster)",
    )
    pc.set_defaults(func=cmd_chat)

    ppng = sub.add_parser("step-screenshot", help="GET /agent/step_screenshot?step=N and save PNG")
    ppng.add_argument("--step", required=True, help="Step number")
    ppng.add_argument("--out", required=True, help="Output PNG path")
    ppng.set_defaults(func=cmd_step_screenshot)

    psrv = sub.add_parser("serve", help="Start a local live dashboard (no CORS, proxies Runner /agent/*)")
    psrv.add_argument("--host", default="127.0.0.1", help="Listen host (default: 127.0.0.1)")
    psrv.add_argument("--port", type=int, default=0, help="Listen port (0 = random free port)")
    psrv.add_argument(
        "--poll-seconds",
        type=float,
        default=0.0,
        help="Auto refresh interval in seconds (default: 0 = manual refresh only)",
    )
    psrv.set_defaults(func=cmd_serve)

    prun = sub.add_parser(
        "run-until-responses",
        help="POST /agent/start and stop after N 'response' items appear in /agent/chat",
    )
    prun.add_argument("--task", default="", help="Task text to run")
    prun.add_argument("--payload", help="JSON object (or @file.json) merged into start payload")
    prun.add_argument("--responses", type=int, default=5, help="Stop after this many response items (default: 5)")
    prun.add_argument("--poll-seconds", type=float, default=0.5, help="Polling interval in seconds (default: 0.5)")
    prun.add_argument("--max-seconds", type=float, default=180.0, help="Give up after this many seconds (default: 180)")
    prun.add_argument("--export-html", help="Export chat as HTML after stop")
    prun.add_argument(
        "--max-screenshot-steps",
        type=int,
        default=0,
        help="If > 0, embed screenshots only for the last N steps (faster)",
    )
    prun.set_defaults(func=cmd_run_until_responses)

    def add_post(name: str, path: str, help_text: str) -> None:
        sp = sub.add_parser(name, help=help_text)
        sp.add_argument("--payload", help="JSON string or @/path/to.json")
        sp.set_defaults(func=cmd_post_simple, path=path)

    add_post("config", "/agent/config", "POST /agent/config (update config)")
    add_post("start", "/agent/start", "POST /agent/start (start agent)")
    add_post("stop", "/agent/stop", "POST /agent/stop (stop agent)")
    add_post("reset", "/agent/reset", "POST /agent/reset (reset runtime)")
    add_post("factory-reset", "/agent/factory_reset", "POST /agent/factory_reset (factory reset)")

    return p


def main(argv: List[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))  # type: ignore[arg-type]
    except KeyboardInterrupt:
        return 130
    except ApiError as e:
        print(f"[error] {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
