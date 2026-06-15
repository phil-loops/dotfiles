#!/usr/bin/env python3
"""Assemble the review HTML from decomposed source in viewer/, inject the model.
Output stays self-contained (one <style> + one <script>), so static file:// and
live-server modes are unchanged. Edit viewer/{styles.css,data.js,graph.js,detail.js,
shell.html} — graph and detail are now separate files. Usage: tpl.py <model.json> <out.html>"""
import sys, os
model = open(sys.argv[1]).read()
V = os.path.join(os.path.dirname(os.path.abspath(__file__)), "viewer")
def asset(n): return open(os.path.join(V, n)).read()
out = (asset("shell.html")
       .replace("__STYLES__", asset("styles.css"))
       .replace("__SCRIPTS__", asset("data.js") + asset("graph.js") + asset("detail.js") + asset("palette.js") + asset("freshness.js"))
       .replace("__MODEL__", model))
open(sys.argv[2], "w").write(out)
