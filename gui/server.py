#!/usr/bin/env python3
"""latex-tutor GUI server.

Neovim starts this process and talks to it over stdin/stdout (JSON lines):
  nvim -> server: {"type": "state", ...}   comments for the focused question
                  {"type": "compile", "file": ...}           on save
                  {"type": "live", "file", "lines", "s", "e"} unsaved text (live.py)
  server -> nvim: {"type": "ready", "port": N}
                  {"type": "action", "action": ..., ...}   button clicks

The browser window talks to the server over HTTP on 127.0.0.1:
  GET  /            the app (static/)
  GET  /events      Server-Sent Events: state + pdf updates
  GET  /pdf         the compiled PDF
  POST /action      a click, forwarded to nvim

The PDF is built with pdflatex -synctex=1 into ~/.cache/latex-tutor/build/,
never next to your .tex files or in build/. SyncTeX maps each comment's
source lines to rectangles on the page.
"""

import argparse
import hashlib
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import live as livebuild  # noqa: E402

HERE = Path(__file__).resolve().parent
STATIC = HERE / "static"
CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "latex-tutor" / "build"

lock = threading.Lock()
state = {}            # last state from nvim, plus boxes
pdf = {"path": None, "version": 0, "error": None, "building": False, "file": None}
clients = []          # list of queue.Queue for SSE
last = {"state": None}  # last published state (GET /state)
box_cache = {}        # (pdf_version, line) -> [boxes]
macro_cache = {}      # header path -> (mtime, macros)
# Live preview (live.py): the PDF of your unsaved text.
lv = {"path": None, "version": 0, "error": None, "input": None, "file": None, "label": None, "secs": None}
livers = {}           # source file -> livebuild.Live
seq = [0]             # one version counter for every PDF the window is sent
pdf_files = {}        # version -> path, for GET /pdf?v=


def next_version(path):
    seq[0] += 1
    pdf_files[seq[0]] = path
    for v in [v for v in pdf_files if v < seq[0] - 8]:
        pdf_files.pop(v)
    return seq[0]


def view():
    """The PDF the window shows: the live one once it exists for this file."""
    f = state.get("file")
    if lv["path"] and f and lv["file"] == f:
        return lv
    return pdf
out_lock = threading.Lock()


def to_nvim(msg):
    with out_lock:
        sys.stdout.write(json.dumps(msg) + "\n")
        sys.stdout.flush()


def broadcast(kind, data):
    payload = f"event: {kind}\ndata: {json.dumps(data)}\n\n"
    with lock:
        for q in list(clients):
            q.put(payload)


# --- LaTeX macros from the manual's header, for KaTeX -----------------------

def balanced(s, i):
    """Return (content, end) of the {...} group starting at s[i] == '{'."""
    depth = 0
    for j in range(i, len(s)):
        if s[j] == "\\":
            continue
        if s[j] == "{" and (j == 0 or s[j - 1] != "\\"):
            depth += 1
        elif s[j] == "}" and s[j - 1] != "\\":
            depth -= 1
            if depth == 0:
                return s[i + 1:j], j + 1
    return None, len(s)


def parse_macros(text):
    text = re.sub(r"(?<!\\)%.*", "", text)
    macros = {}
    for m in re.finditer(r"\\(?:re)?newcommand\*?\s*\{?\s*(\\[A-Za-z]+)\s*\}?\s*(?:\[(\d)\])?\s*(?:\[[^\]]*\])?\s*(?=\{)", text):
        body, _ = balanced(text, m.end())
        if body is not None:
            macros[m.group(1)] = body
    for m in re.finditer(r"\\DeclareMathOperator(\*?)\s*\{\s*(\\[A-Za-z]+)\s*\}\s*(?=\{)", text):
        body, _ = balanced(text, m.end())
        if body is not None:
            star = "*" if m.group(1) else ""
            macros[m.group(2)] = "\\operatorname" + star + "{" + body + "}"
    for m in re.finditer(r"\\def\s*(\\[A-Za-z]+)\s*(?=\{)", text):
        body, _ = balanced(text, m.end())
        if body is not None:
            macros.setdefault(m.group(1), body)
    return macros


def macros_for(root):
    if not root:
        return {}
    out = {}
    for h in sorted(Path(root).glob("header*.tex")):
        try:
            mt = h.stat().st_mtime
            hit = macro_cache.get(str(h))
            if not hit or hit[0] != mt:
                hit = (mt, parse_macros(h.read_text(errors="replace")))
                macro_cache[str(h)] = hit
            out.update(hit[1])
        except OSError:
            pass
    return out


# --- Build + SyncTeX ---------------------------------------------------------

def build_dir(tex):
    return CACHE / hashlib.sha1(str(tex).encode()).hexdigest()[:12]


def first_error(log_path):
    try:
        lines = Path(log_path).read_text(errors="replace").splitlines()
    except OSError:
        return "build failed"
    for i, l in enumerate(lines):
        if l.startswith("! "):
            where = next((x for x in lines[i:i + 12] if re.match(r"^l\.\d+", x)), "")
            return (l[2:] + (" (" + where.split(" ")[0] + ")" if where else "")).strip()
    return "build failed"


def compile_pdf(tex, engine):
    tex = Path(tex)
    out = build_dir(tex)
    out.mkdir(parents=True, exist_ok=True)
    cmd = [engine, "-synctex=1", "-interaction=nonstopmode", "-halt-on-error",
           "-file-line-error", f"-output-directory={out}", tex.name]
    with lock:
        if pdf["building"]:
            pdf["again"] = (str(tex), engine)
            return
        pdf["building"] = True
    broadcast("build", {"building": True})
    try:
        runs = 1 if (out / (tex.stem + ".aux")).exists() else 2
        ok = True
        for _ in range(runs):
            r = subprocess.run(cmd, cwd=tex.parent, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               stdin=subprocess.DEVNULL, timeout=180)
            ok = r.returncode == 0
            if not ok:
                break
        pdf_path = out / (tex.stem + ".pdf")
        with lock:
            pdf["file"] = str(tex)
            if ok and pdf_path.exists():
                pdf["path"] = str(pdf_path)
                pdf["version"] = next_version(str(pdf_path))
                pdf["error"] = None
                box_cache.clear()
            else:
                pdf["error"] = first_error(out / (tex.stem + ".log"))
                if pdf_path.exists() and not pdf["path"]:
                    pdf["path"] = str(pdf_path)
                    pdf["version"] = next_version(str(pdf_path))
    except Exception as e:  # noqa: BLE001
        with lock:
            pdf["error"] = str(e)
    finally:
        with lock:
            pdf["building"] = False
            again = pdf.pop("again", None)
    publish()
    if again:
        compile_pdf(*again)


def synctex_view(tex, line, v=None):
    """Rectangles (page, x, y, w, h in PDF points, y from the top) for a line."""
    v = v or pdf
    key = (v["version"], line)
    if key in box_cache:
        return box_cache[key]
    boxes = []
    if v["path"]:
        try:
            name = v.get("input") or Path(tex).name  # live: the body file, same line numbers
            r = subprocess.run(["synctex", "view", "-i", f"{line}:0:{name}", "-o", v["path"]],
                               cwd=Path(tex).parent, capture_output=True, text=True, timeout=10)
            cur = {}
            for l in r.stdout.splitlines():
                k, _, v = l.partition(":")
                if k in ("Page", "h", "v", "W", "H"):
                    cur[k] = float(v)
                if k == "H" and {"Page", "h", "v", "W"} <= cur.keys():
                    boxes.append({"page": int(cur["Page"]), "x": cur["h"], "y": cur["v"] - cur["H"],
                                  "w": cur["W"], "h": cur["H"] * 1.25})
                    cur = {}
        except Exception:  # noqa: BLE001
            pass
    # Merge to one rectangle per page.
    merged = {}
    for b in boxes:
        m = merged.get(b["page"])
        if not m:
            merged[b["page"]] = dict(b)
        else:
            x1, y1 = min(m["x"], b["x"]), min(m["y"], b["y"])
            x2, y2 = max(m["x"] + m["w"], b["x"] + b["w"]), max(m["y"] + m["h"], b["y"] + b["h"])
            m.update(x=x1, y=y1, w=x2 - x1, h=y2 - y1)
    res = list(merged.values())
    box_cache[key] = res
    for k in [k for k in box_cache if k[0] < seq[0] - 8]:
        box_cache.pop(k, None)
    return res


def synctex_edit(page, x, y):
    """Source line under a point of the PDF, if it's in the reviewed file."""
    v = view()
    if not v["path"] or not v["file"]:
        return None
    want = os.path.realpath(v.get("input") or v["file"])
    try:
        r = subprocess.run(["synctex", "edit", "-o", f"{page}:{x}:{y}:{v['path']}"],
                           capture_output=True, text=True, timeout=10)
        src = None
        for l in r.stdout.splitlines():
            if l.startswith("Input:"):
                src = os.path.realpath(l[6:])
            elif l.startswith("Line:") and src == want:
                return int(l[5:])
    except Exception:  # noqa: BLE001
        pass
    return None


def publish():
    """Attach page rectangles to the comments and send everything to the browser."""
    with lock:
        s = json.loads(json.dumps(state)) if state else {}
        p = dict(view())
        is_live = p is not pdf and p.get("input") is not None
    tex = s.get("file")
    same = tex and p.get("file") == tex
    if same:
        for c in s.get("comments", []):
            boxes = []
            for line in range(c["row"] + 1, min(c["end_row"], c["row"] + 6) + 2):
                boxes += synctex_view(tex, line, p)
            # one rect per page
            per = {}
            for b in boxes:
                m = per.get(b["page"])
                if not m:
                    per[b["page"]] = dict(b)
                else:
                    x1, y1 = min(m["x"], b["x"]), min(m["y"], b["y"])
                    x2, y2 = max(m["x"] + m["w"], b["x"] + b["w"]), max(m["y"] + m["h"], b["y"] + b["h"])
                    m.update(x=x1, y=y1, w=x2 - x1, h=y2 - y1)
            c["boxes"] = list(per.values())
        cur = s.get("cursor")
        if isinstance(cur, int):
            # nearest line at or above the cursor that made it onto the page
            for line in range(cur, max(0, cur - 6), -1):
                cb = synctex_view(tex, line, p)
                if cb:
                    s["cursor_box"] = cb[0]
                    break
        f = s.get("focus") or {}
        if f.get("s"):
            fb = synctex_view(tex, f["s"], p) or synctex_view(tex, f["s"] + 1, p)
            f["box"] = fb[0] if fb else None
    s["macros"] = macros_for(s.get("root"))
    err = p["error"] if same else None
    if not is_live and lv["error"] and lv["file"] == tex:
        err = lv["error"]
    s["pdf"] = {"version": p["version"] if same else 0, "error": err,
                # On-save builds run quietly behind the live preview.
                "building": False if is_live else p["building"],
                "live": is_live, "key": (p.get("label") or "all") if is_live else "file",
                "secs": p.get("secs") if is_live else None}
    last["state"] = s
    broadcast("state", s)


# --- HTTP ----------------------------------------------------------------------

TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
         ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml", ".woff2": "font/woff2"}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body=b"", ctype="text/plain; charset=utf-8", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if not (extra and "Cache-Control" in extra):
            self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            q = queue.Queue()
            with lock:
                clients.append(q)
            threading.Thread(target=publish, daemon=True).start()
            try:
                while True:
                    try:
                        msg = q.get(timeout=15)
                    except queue.Empty:
                        msg = ": ping\n\n"
                    self.wfile.write(msg.encode())
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            finally:
                with lock:
                    if q in clients:
                        clients.remove(q)
            return
        if path == "/delay":  # snapshot helper: holds the page's load event open
            ms = int((self.path.split("ms=")[1:] or ["0"])[0] or 0)
            time.sleep(min(ms, 30000) / 1000)
            return self.send(200, b"GIF89a\x01\x00\x01\x00\x00\x00\x00;", "image/gif")
        if path == "/math":  # the last Σ answer (snapshot mode)
            return self.send(200, json.dumps(last.get("math") or {}).encode(), "application/json")
        if path == "/progress":  # the last report nvim sent (snapshot mode)
            return self.send(200, json.dumps({"md": last.get("progress") or ""}).encode(), "application/json")
        if path == "/state":
            body = json.dumps(last["state"] or {}).encode()
            return self.send(200, body, "application/json")
        if path == "/pdf":
            v = re.search(r"[?&]v=(\d+)", self.path)
            p = pdf_files.get(int(v.group(1))) if v else None
            p = p or view()["path"]
            if not p or not os.path.exists(p):
                return self.send(404, b"no pdf yet")
            return self.send(200, Path(p).read_bytes(), "application/pdf")
        name = "index.html" if path in ("/", "") else path.lstrip("/")
        f = (STATIC / name).resolve()
        if STATIC not in f.parents or not f.is_file():
            return self.send(404, b"not found")
        extra = {"Cache-Control": "max-age=86400"} if "vendor" in f.parts else None
        self.send(200, f.read_bytes(), TYPES.get(f.suffix, "application/octet-stream"), extra)

    def do_POST(self):
        if self.path != "/action":
            return self.send(404)
        # Same-origin only: refuse requests a random web page could forge.
        origin = self.headers.get("Origin")
        host = self.headers.get("Host", "")
        if origin and not origin.endswith("//" + host):
            return self.send(403, b"forbidden")
        n = int(self.headers.get("Content-Length", "0") or 0)
        try:
            msg = json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            return self.send(400, b"bad json")
        if msg.get("action") == "pdfclick":
            line = synctex_edit(msg.get("page"), msg.get("x"), msg.get("y"))
            if line:
                to_nvim({"type": "action", "action": "jump_line", "line": line})
        else:
            to_nvim({"type": "action", **msg})
        self.send(204)


def read_nvim(engine):
    for line in sys.stdin:
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = msg.get("type")
        if kind == "state":
            with lock:
                state.clear()
                state.update(msg)
            threading.Thread(target=publish, daemon=True).start()
        elif kind == "math":
            msg["macros"] = macros_for(msg.get("root"))
            last["math"] = msg
            broadcast("math", msg)
        elif kind == "progress":
            last["progress"] = msg.get("md") or ""
            broadcast("progress", {"md": last["progress"]})
        elif kind == "live":
            start_live(msg, engine)
        elif kind == "compile":
            threading.Thread(target=compile_pdf, args=(msg["file"], msg.get("engine") or engine), daemon=True).start()
        elif kind == "quit":
            break
    # nvim quit (or went away): tell the window to close itself, then exit.
    broadcast("bye", {})
    time.sleep(0.3)
    os._exit(0)


def live_result(src, res):
    with lock:
        if res.get("show"):
            lv.update(path=res["pdf"], input=res["input"], file=src, label=res.get("label"),
                      secs=res.get("secs"), version=next_version(res["pdf"]))
        if lv["file"] == src or lv["file"] is None:
            lv["error"] = res.get("error")
    publish()


def start_live(msg, engine):
    src = msg.get("file")
    if not src or not isinstance(msg.get("lines"), list):
        return
    eng = msg.get("engine") or engine
    with lock:
        lr = livers.get(src)
        if lr and lr.engine != eng:
            lr.close()
            lr = None
        if not lr:
            for other in livers.values():   # one file at a time
                other.close()
            livers.clear()
            lr = livebuild.Live(src, build_dir(Path(src)), eng,
                                lambda: build_dir(Path(src)) / (Path(src).stem + ".aux"),
                                lambda res: live_result(src, res))
            livers[src] = lr
    lr.request(msg["lines"], msg.get("s"), msg.get("e"), msg.get("label"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--engine", default="pdflatex")
    a = ap.parse_args()
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    srv.daemon_threads = True
    threading.Thread(target=read_nvim, args=(a.engine,), daemon=True).start()
    to_nvim({"type": "ready", "port": srv.server_address[1]})
    srv.serve_forever()


if __name__ == "__main__":
    main()
