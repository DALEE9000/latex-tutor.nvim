#!/usr/bin/env python3
"""Compile a TikZ snippet with your document's own preamble and render a
PNG preview of it. Used by Draw (lua/latex-tutor/draw.lua):

    python3 draw.py build JOB.json   ->  prints {"ok", "png", "pdf", "error", ...}

JOB.json: {"src": main .tex path, "preamble": text before \\begin{document},
           "tikz": the snippet, "libraries": ["arrows.meta", ...],
           "out": output folder, "dpi": 220}

The snippet is typeset with the preview package, so the page is cropped to
the tikzpicture. Your header is \\input from the main file's folder exactly
as in your document, so macros, colours and \\tikzset styles all apply.
Everything is written to the output folder (~/.cache/latex-tutor/draw/),
never next to your files.
"""

import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

CROP = ("\\usepackage[active,tightpage]{preview}\n"
        "\\PreviewEnvironment{tikzpicture}\n"
        "\\setlength\\PreviewBorder{6pt}\n")


def first_error(log, body_start):
    """(message, snippet line or None, context) of the first TeX error."""
    lines = log.splitlines()
    for i, l in enumerate(lines):
        if l.startswith("! "):
            ctx = lines[i:i + 14]
            where = next((x for x in ctx if re.match(r"^l\.\d+", x)), "")
            m = re.match(r"^l\.(\d+)", where)
            n = int(m.group(1)) if m else None
            snippet_line = n - body_start if n and n > body_start else None
            return l[2:].strip(), snippet_line, "\n".join(ctx[:6])
    return None


def build(job):
    out = Path(job["out"])
    out.mkdir(parents=True, exist_ok=True)
    src = Path(job["src"])
    libs = [x for x in (job.get("libraries") or []) if re.fullmatch(r"[\w.\-]+", x or "")]
    tikz = job["tikz"]
    key = hashlib.sha1(json.dumps([job["preamble"], tikz, libs]).encode()).hexdigest()[:12]
    name = "draw-" + key

    def attempt(crop):
        head = job["preamble"].rstrip("\n") + "\n"
        if libs:
            head += "\\usetikzlibrary{%s}\n" % ",".join(libs)
        if crop:
            head += CROP
        head += "\\begin{document}\n\\pagestyle{empty}\n"
        body_start = head.count("\n")
        (out / (name + ".tex")).write_text(head + tikz.rstrip("\n") + "\n\\end{document}\n")
        try:
            subprocess.run([job.get("engine") or "pdflatex", "-interaction=nonstopmode", "-halt-on-error",
                            f"-output-directory={out}", str(out / (name + ".tex"))],
                           cwd=src.parent, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           stdin=subprocess.DEVNULL, timeout=90)
        except subprocess.TimeoutExpired:
            return {"ok": False, "error": "timed out after 90 s (an infinite loop in the drawing?)"}
        log = (out / (name + ".log")).read_text(errors="replace") if (out / (name + ".log")).exists() else ""
        err = first_error(log, body_start)
        pdf = out / (name + ".pdf")
        if err or not pdf.exists():
            msg, line, ctx = err or ("no PDF was produced", None, "")
            # an error in the preamble part means the crop setup clashed with it
            return {"ok": False, "error": msg, "line": line, "context": ctx,
                    "preamble_error": err is not None and line is None}
        return {"ok": True, "pdf": str(pdf)}

    res = attempt(True)
    if not res["ok"] and res.get("preamble_error"):
        res = attempt(False)   # without the crop: a full page, but it still shows
    if res["ok"]:
        png = out / (name + ".png")
        subprocess.run(["pdftoppm", "-r", str(job.get("dpi") or 220), "-png", "-singlefile", "-f", "1", "-l", "1",
                        res["pdf"], str(png.with_suffix(""))],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        if png.exists():
            res["png"] = str(png)
    return res


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "build":
        print(json.dumps(build(json.loads(Path(sys.argv[2]).read_text()))))
    else:
        print(__doc__)
