"""Live preview: rebuild the PDF from your unsaved text a moment after you
stop typing.

Speed comes from warm spares. A spare is a TeX process that has already
loaded your preamble and run \\begin{document}, and now sits waiting for its
next terminal line. When a build is wanted, nvim's text goes into a body file
and the spare is told to \\input it, so only the body is typeset. Two spares
are kept ready, so back-to-back builds both start warm.

The body file keeps the source's line numbers: lines outside what is built
are replaced by "%". SyncTeX and TeX's error line numbers therefore point at
the real lines of your file.

Safety:
* A build with a TeX error (half-typed \\frac{, a stray $) is not shown; the
  window keeps the last good PDF and reports the error line. An error that
  persists for a few seconds is shown anyway, so a real error doesn't freeze
  the preview.
* The spare's terminal is closed right after the \\input line, so TeX can
  never wait for input; a build that runs too long is killed.
* Only one build runs at a time and the newest text always wins.
* Everything is written to ~/.cache/latex-tutor/build/, never next to your
  files or into build/.
"""

import hashlib
import os
import re
import shutil
import subprocess
import threading
import time
from pathlib import Path

MARK = "LTLIVE>"
TIMEOUT = 12          # seconds before a build is killed
POOL = 2              # warm spares kept ready
PERSIST = 4.0         # an identical error lasting this long is shown anyway


def errors_after_mark(log_text):
    """TeX errors in the body part of a log: [(message, line or None)]."""
    i = log_text.find(MARK)
    if i < 0:
        return [("the preamble did not finish loading", None)]
    out = []
    lines = log_text[i:].splitlines()
    for k, l in enumerate(lines):
        if l.startswith("! "):
            where = next((x for x in lines[k:k + 14] if re.match(r"^l\.\d+", x)), "")
            m = re.match(r"^l\.(\d+)", where)
            out.append((l[2:].strip().rstrip("."), int(m.group(1)) if m else None))
    return out


class Spare:
    def __init__(self, live, key, job, pre):
        self.key = key
        self.job = job
        self.started = time.time()
        out = live.out
        # \ref and \cite resolve against the last full build's .aux.
        aux = live.full_aux()
        if aux and aux.exists():
            try:
                shutil.copyfile(aux, out / (job + ".aux"))
            except OSError:
                pass
        self.proc = subprocess.Popen(
            [live.engine, "-synctex=1", "-interaction=scrollmode",
             f"-output-directory={out}", f"-jobname={job}"],
            cwd=live.src.parent, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, text=True)
        # Load the preamble now, while you type.
        self.proc.stdin.write("\\input{%s}\n" % pre.as_posix())
        self.proc.stdin.flush()

    def alive(self):
        return self.proc.poll() is None

    def kill(self):
        try:
            self.proc.kill()
        except OSError:
            pass


class Live:
    """Live builds for one .tex file."""

    def __init__(self, src, out, engine, full_aux, on_result):
        self.src = Path(src)
        self.out = Path(out) / "live"
        self.out.mkdir(parents=True, exist_ok=True)
        self.engine = engine
        self.full_aux = full_aux        # () -> Path of the full build's .aux
        self.on_result = on_result      # (result dict) -> None
        self.lock = threading.Lock()
        self.cv = threading.Condition(self.lock)
        self.want = None                # newest request
        self.spares = []
        self.key = None                 # preamble hash the spares were made for
        self.deps = {}                  # preamble input files -> mtime
        self.n = 0
        self.good = None                # last accepted result
        self.err_since = {}             # error signature -> first seen
        self.closed = False
        threading.Thread(target=self.loop, daemon=True).start()

    # --- requests --------------------------------------------------------

    def request(self, lines, s=None, e=None, label=None):
        with self.cv:
            self.want = {"lines": lines, "s": s, "e": e, "label": label, "at": time.time()}
            self.cv.notify()

    def close(self):
        with self.cv:
            self.closed = True
            self.cv.notify()
        for sp in self.spares:
            sp.kill()

    # --- preamble + spares -----------------------------------------------

    def split(self, lines):
        for i, l in enumerate(lines):
            if re.match(r"^\s*\\begin\{document\}", l):
                return i
        return None

    def deps_changed(self):
        for f, mt in self.deps.items():
            try:
                if os.stat(f).st_mtime != mt:
                    return True
            except OSError:
                return True
        return False

    def read_deps(self, job):
        """Files the preamble read from your project (from TeX's -recorder-like
        log), so editing your header file refreshes the spares."""
        deps = {}
        try:
            log = (self.out / (job + ".log")).read_text(errors="replace")
        except OSError:
            return deps
        root = str(self.src.parent.parent)
        for m in re.finditer(r"\(([^()\s]+\.(?:tex|sty|cls|def))", log.split(MARK)[0]):
            p = m.group(1)
            p = p if os.path.isabs(p) else os.path.join(self.src.parent, p)
            p = os.path.realpath(p)
            if p.startswith(root) and "texmf" not in p and os.path.exists(p):
                deps[p] = os.stat(p).st_mtime
        return deps

    def ensure_spares(self, pre_lines):
        key = hashlib.sha1("\n".join(pre_lines).encode()).hexdigest()[:12]
        if key != self.key or self.deps_changed():
            for sp in self.spares:
                sp.kill()
            self.spares = []
            self.key = key
            self.deps = {}
            (self.out / f"pre-{key}.tex").write_text("\n".join(pre_lines) + "\n\\begin{document}\n")
        self.spares = [sp for sp in self.spares if sp.alive()]
        pre = self.out / f"pre-{key}.tex"
        while len(self.spares) < POOL:
            self.n += 1
            self.spares.append(Spare(self, key, f"live{self.n}", pre))

    # --- the build loop --------------------------------------------------

    def loop(self):
        while True:
            with self.cv:
                while self.want is None and not self.closed:
                    self.cv.wait()
                if self.closed:
                    return
                req, self.want = self.want, None
            try:
                self.build(req)
            except Exception as ex:  # noqa: BLE001
                self.on_result({"ok": False, "error": f"live preview: {ex}"})

    def body(self, lines, bd, s, e):
        keep_all = s is None
        out = []
        end_seen = False
        for i, l in enumerate(lines, start=1):
            if i <= bd + 1:                      # preamble and \begin{document}
                out.append("%")
            elif keep_all or s <= i <= e:
                if re.match(r"^\s*\\end\{document\}", l):
                    end_seen = True
                out.append(l)
            elif re.match(r"^\s*\\end\{document\}", l):
                end_seen = True
                out.append(l)
            else:
                out.append("%")
        if not end_seen:
            out.append("\\end{document}")
        return out

    def build(self, req):
        lines = req["lines"]
        bd = self.split(lines)
        if bd is None:
            self.on_result({"ok": False, "error": "no \\begin{document} in this file; live preview needs the main file"})
            return
        self.ensure_spares(lines[:bd])
        sp = self.spares.pop(0)
        body_path = self.out / (sp.job + "-body.tex")
        body_path.write_text("\n".join(self.body(lines, bd, req["s"], req["e"])) + "\n")
        t0 = time.time()
        try:
            sp.proc.stdin.write("\\message{%s}\\input{%s}\n" % (MARK, body_path.as_posix()))
            sp.proc.stdin.flush()
            sp.proc.stdin.close()        # TeX can never wait on the terminal
        except (BrokenPipeError, OSError):
            pass
        try:
            sp.proc.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            sp.kill()
            self.on_result({"ok": False, "error": "live build took too long"})
            return
        if not self.deps:
            self.deps = self.read_deps(sp.job)
        # Its replacement starts after the build, so it doesn't compete for CPU.
        self.ensure_spares(lines[:bd])
        pdf = self.out / (sp.job + ".pdf")
        try:
            log = (self.out / (sp.job + ".log")).read_text(errors="replace")
        except OSError:
            log = ""
        errs = errors_after_mark(log)
        ok = pdf.exists() and pdf.stat().st_size > 0
        res = {"ok": ok, "pdf": str(pdf), "input": str(body_path), "label": req["label"],
               "secs": round(time.time() - t0, 2), "errors": errs}
        if errs:
            msg, line = errs[0]
            res["error"] = f"line {line}: {msg}" if line else msg
            sig = (msg, line)
            first = self.err_since.setdefault(sig, req["at"])
            for k in [k for k in self.err_since if k != sig]:
                self.err_since.pop(k)
            # Mid-typing errors keep the last good PDF; a lasting one is shown.
            show = ok and (self.good is None or time.time() - first >= PERSIST)
        else:
            self.err_since.clear()
            show = ok
            if not ok:
                res["error"] = "the live build produced no PDF"
        res["show"] = show
        if show:
            self.good = res
        self.on_result(res)
        self.prune()

    def prune(self):
        keep = {sp.job for sp in self.spares}
        if self.good:
            keep.add(Path(self.good["pdf"]).stem)
        recent = sorted((int(m.group(1)) for f in self.out.glob("live*.pdf")
                         if (m := re.match(r"live(\d+)\.pdf$", f.name))), reverse=True)[:4]
        keep |= {f"live{n}" for n in recent}
        for f in self.out.glob("live*"):
            job = re.match(r"(live\d+)", f.name)
            if job and job.group(1) not in keep:
                try:
                    f.unlink()
                except OSError:
                    pass
