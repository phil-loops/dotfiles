# srv/syntax.py — a changed file's declarations, read from its syntax tree for canopy's review page.
#
#   POST /syntax/units {branch | sha, path}
#     → {ok, sha, units: [{line, endLine, name, scope}], functions: [{line, endLine, name}], classes: [same]}
#
# Parses with Helix's own compiled grammars and runs Helix's own textobject queries, so "a function"
# means here exactly what it means to Helix's ]f. The tree-sitter C runtime is loaded through ctypes
# (Homebrew's libtree-sitter) — no Python dependency. A unit is a statement in its scope: the file's
# top level, a class body, or a describe(…) callback's body — those are stepped into, everything else
# is read whole. In .tsx/.jsx a React component (a PascalCase function) is a scope too: its hooks,
# handlers and returned JSX are separate things to read. Lines are 1-based, on the given commit.
import ctypes
import json
import os
import subprocess
import threading

from srv import ctx

RUNTIME = os.environ.get("CANOPY_TREE_SITTER", "/opt/homebrew/lib/libtree-sitter.dylib")
HELIX = os.environ.get("CANOPY_HELIX_RUNTIME", "/opt/homebrew/opt/helix/libexec/runtime")

# extension → (grammar, the queries directory Helix pairs with it)
LANGS = {".ts": ("typescript", "typescript"), ".mts": ("typescript", "typescript"), ".cts": ("typescript", "typescript"),
         ".tsx": ("tsx", "tsx"), ".js": ("javascript", "javascript"), ".mjs": ("javascript", "javascript"),
         ".cjs": ("javascript", "javascript"), ".jsx": ("javascript", "jsx")}

SUITES = {"describe", "suite", "context"}


class Point(ctypes.Structure):
    _fields_ = [("row", ctypes.c_uint32), ("column", ctypes.c_uint32)]


class Node(ctypes.Structure):
    _fields_ = [("context", ctypes.c_uint32 * 4), ("id", ctypes.c_void_p), ("tree", ctypes.c_void_p)]


class Capture(ctypes.Structure):
    _fields_ = [("node", Node), ("index", ctypes.c_uint32)]


class Match(ctypes.Structure):
    _fields_ = [("id", ctypes.c_uint32), ("pattern_index", ctypes.c_uint16), ("capture_count", ctypes.c_uint16),
                ("captures", ctypes.POINTER(Capture))]


class _TS:
    """The C runtime's calls this module makes, typed once."""

    def __init__(self, path):
        rt = ctypes.CDLL(path)

        def f(name, res, *args):
            fn = getattr(rt, name)
            fn.restype, fn.argtypes = res, list(args)
            return fn
        vp, u32 = ctypes.c_void_p, ctypes.c_uint32
        self.parser_new = f("ts_parser_new", vp)
        self.parser_delete = f("ts_parser_delete", None, vp)
        self.set_language = f("ts_parser_set_language", ctypes.c_bool, vp, vp)
        self.parse = f("ts_parser_parse_string", vp, vp, vp, ctypes.c_char_p, u32)
        self.tree_delete = f("ts_tree_delete", None, vp)
        self.root = f("ts_tree_root_node", Node, vp)
        self.named_count = f("ts_node_named_child_count", u32, Node)
        self.named_child = f("ts_node_named_child", Node, Node, u32)
        self.field = f("ts_node_child_by_field_name", Node, Node, ctypes.c_char_p, u32)
        self.is_null = f("ts_node_is_null", ctypes.c_bool, Node)
        self.type = f("ts_node_type", ctypes.c_char_p, Node)
        self.start = f("ts_node_start_point", Point, Node)
        self.end = f("ts_node_end_point", Point, Node)
        self.start_byte = f("ts_node_start_byte", u32, Node)
        self.end_byte = f("ts_node_end_byte", u32, Node)
        self.parent = f("ts_node_parent", Node, Node)
        self.query_new = f("ts_query_new", vp, vp, ctypes.c_char_p, u32, ctypes.POINTER(u32), ctypes.POINTER(ctypes.c_int))
        self.capture_count = f("ts_query_capture_count", u32, vp)
        self.capture_name = f("ts_query_capture_name_for_id", ctypes.c_char_p, vp, u32, ctypes.POINTER(u32))
        self.cursor_new = f("ts_query_cursor_new", vp)
        self.cursor_delete = f("ts_query_cursor_delete", None, vp)
        self.cursor_exec = f("ts_query_cursor_exec", None, vp, vp, Node)
        self.next_capture = f("ts_query_cursor_next_capture", ctypes.c_bool, vp, ctypes.POINTER(Match), ctypes.POINTER(u32))


_lock = threading.Lock()
_ts = None
_langs = {}     # grammar → TSLanguage*
_queries = {}   # queries dir → (TSQuery*, the capture id of function.around)
_cache = {}     # blob sha + grammar → the answer


def _runtime():
    global _ts
    if _ts is None:
        _ts = _TS(RUNTIME)
    return _ts


def _language(grammar):
    if grammar not in _langs:
        lib = ctypes.CDLL(os.path.join(HELIX, "grammars", f"{grammar}.dylib"))
        entry = getattr(lib, f"tree_sitter_{grammar}")
        entry.restype = ctypes.c_void_p
        _langs[grammar] = entry()
    return _langs[grammar]


def query_text(name, seen=None):
    """Helix's textobjects.scm for `name` with its `; inherits:` files folded in, as Helix reads it."""
    seen = set() if seen is None else seen
    if name in seen:
        return ""
    seen.add(name)
    path = os.path.join(HELIX, "queries", name, "textobjects.scm")
    if not os.path.exists(path):
        return ""
    own, inherited = [], []
    with open(path, encoding="utf-8") as f:
        text = f.read()
    for line in text.splitlines():
        if line.strip().startswith("; inherits:"):
            for dep in line.split(":", 1)[1].split(","):
                inherited.append(query_text(dep.strip(), seen))
        else:
            own.append(line)
    return "\n".join(own + inherited)


def _query(qdir, lang):
    if qdir not in _queries:
        ts = _runtime()
        src = query_text(qdir).encode()
        off, err = ctypes.c_uint32(0), ctypes.c_int(0)
        q = ts.query_new(lang, src, len(src), ctypes.byref(off), ctypes.byref(err))
        if not q:
            raise RuntimeError(f"Helix's {qdir} textobjects don't compile (error {err.value} at byte {off.value})")
        n = ctypes.c_uint32(0)
        names = [ts.capture_name(q, i, ctypes.byref(n))[:n.value].decode() for i in range(ts.capture_count(q))]
        _queries[qdir] = (q, {i: n for i, n in enumerate(names) if n in ("function.around", "class.around")})
    return _queries[qdir]


def units_of(src, ext):
    """`src` (bytes)'s units, and its functions and classes as Helix's textobjects find them (what ]f and ]t
    walk); None for a language this doesn't read."""
    if ext not in LANGS:
        return None
    grammar, qdir = LANGS[ext]
    with _lock:
        ts = _runtime()
        lang = _language(grammar)
        q, ids = _query(qdir, lang)
        parser = ts.parser_new()
        try:
            if not ts.set_language(parser, lang):
                raise RuntimeError(f"the {grammar} grammar's ABI doesn't match {RUNTIME}")
            tree = ts.parse(parser, None, src, len(src))
            try:
                root = ts.root(tree)
                reader = _Reader(ts, src, jsx=grammar in ("tsx", "javascript"))
                return reader.read(root), _textobjects(ts, q, ids, root, reader)
            finally:
                ts.tree_delete(tree)
        finally:
            ts.parser_delete(parser)


def _textobjects(ts, q, ids, root, reader):
    """Helix's function.around and class.around matches, each once, in file order, with a name."""
    out = {"function.around": {}, "class.around": {}}
    cur = ts.cursor_new()
    try:
        ts.cursor_exec(cur, q, root)
        m, at = Match(), ctypes.c_uint32(0)
        while ts.next_capture(cur, ctypes.byref(m), ctypes.byref(at)):
            c = m.captures[at.value]
            kind = ids.get(c.index)
            if kind is None:
                continue
            span = (ts.start(c.node).row + 1, ts.end(c.node).row + 1)
            if span not in out[kind]:
                out[kind][span] = reader.called(c.node)
    finally:
        ts.cursor_delete(cur)
    return tuple([{"line": a, "endLine": b, "name": n} for (a, b), n in sorted(out[k].items())]
                 for k in ("function.around", "class.around"))


class _Reader:
    def __init__(self, ts, src, jsx=False):
        self.ts, self.src, self.out, self.scopes, self.jsx = ts, src, [], 0, jsx

    def kids(self, n):
        return [self.ts.named_child(n, i) for i in range(self.ts.named_count(n))]

    def kind(self, n):
        return self.ts.type(n).decode()

    def text(self, n):
        return self.src[self.ts.start_byte(n):self.ts.end_byte(n)].decode("utf-8", "replace")

    def field(self, n, name):
        c = self.ts.field(n, name.encode(), len(name))
        return None if self.ts.is_null(c) else c

    def read(self, root):
        self.scope(self.kids(root))
        return self.out

    def scope(self, statements):
        self.scopes += 1
        mine = self.scopes
        for s in statements:
            if self.kind(s) == "comment":
                continue
            inner = self.inside(s)
            if inner is not None:
                self.scope(inner)
            else:
                self.out.append({"line": self.ts.start(s).row + 1, "endLine": self.ts.end(s).row + 1,
                                 "name": self.name(s), "scope": mine})

    def inside(self, s):
        """The statements a container holds — a class's members, a describe(…) callback's body — else None."""
        k = self.kind(s)
        if k == "export_statement":
            d = self.field(s, "declaration")
            return self.inside(d) if d is not None else None
        if self.jsx and (body := self.component_body(s)) is not None:
            return body
        if k in ("class_declaration", "abstract_class_declaration", "class"):
            body = self.field(s, "body")
            return self.kids(body) if body is not None else None
        if k == "expression_statement":
            call = self.kids(s)[0] if self.ts.named_count(s) else None
            if call is None or self.kind(call) != "call_expression" or self.callee(call).split(".")[0] not in SUITES:
                return None
            for a in self.kids(self.field(call, "arguments") or call):
                if self.kind(a) in ("arrow_function", "function_expression", "function"):
                    body = self.field(a, "body")
                    if body is not None and self.kind(body) == "statement_block":
                        return self.kids(body)
        return None

    def component_body(self, s):
        """A React component's statements: `function Foo() {…}` or `const Foo = (…) => {…}`, Foo PascalCase."""
        k = self.kind(s)
        fn = None
        if k == "function_declaration":
            fn = s
        elif k in ("lexical_declaration", "variable_declaration") and self.ts.named_count(s) == 1:
            d = self.kids(s)[0]
            v = self.field(d, "value") if self.kind(d) == "variable_declarator" else None
            if v is not None and self.kind(v) in ("arrow_function", "function_expression", "function"):
                fn, s = v, d
        name = self.field(s, "name") if fn is not None else None
        if name is None or not self.text(name)[:1].isupper():
            return None
        body = self.field(fn, "body")
        return self.kids(body) if body is not None and self.kind(body) == "statement_block" else None

    def called(self, n):
        """What a function or class is called: its own name, else the binding or call it sits in."""
        k = self.kind(n)
        own = self.field(n, "name")
        if k == "method_definition" and own is not None:
            return f"method {self.text(own)}"
        if k in ("class_declaration", "abstract_class_declaration", "class", "interface_declaration", "type_alias_declaration"):
            word = {"interface_declaration": "interface", "type_alias_declaration": "type"}.get(k, "class")
            return f"{word} {self.text(own)}" if own is not None else word
        if own is not None:
            return f"function {self.text(own)}"
        p = self.ts.parent(n)
        if self.ts.is_null(p):
            return "function"
        pk = self.kind(p)
        if pk == "variable_declarator" and self.field(p, "name") is not None:
            return f"function {self.text(self.field(p, 'name'))}"
        if pk == "pair" and self.field(p, "key") is not None:
            return f"function {self.text(self.field(p, 'key'))}"
        if pk == "jsx_expression":
            attr = self.ts.parent(p)
            if not self.ts.is_null(attr) and self.kind(attr) == "jsx_attribute" and self.ts.named_count(attr):
                return f"{self.text(self.kids(attr)[0])} handler"
        if pk == "arguments":
            call = self.ts.parent(p)
            if not self.ts.is_null(call) and self.kind(call) == "call_expression":
                head = self.callee(call)
                first = next(iter(self.kids(p)), None)
                title = self.text(first) if first is not None and self.kind(first) in ("string", "template_string") else ""
                return f"{head}({title})" if title else f"{head}() callback"
        return "function"

    def callee(self, call):
        f = self.field(call, "function")
        if f is None:
            return ""
        if self.kind(f) == "call_expression":   # describe.each(table)(…)
            return self.callee(f)
        return self.text(f)

    def name(self, s):
        k = self.kind(s)
        if k == "export_statement":
            d = self.field(s, "declaration")
            return self.name(d) if d is not None else "export"
        if k in ("function_declaration", "generator_function_declaration"):
            return f"function {self.text(self.field(s, 'name'))}" if self.field(s, "name") else "function"
        if k in ("class_declaration", "abstract_class_declaration"):
            return f"class {self.text(self.field(s, 'name'))}" if self.field(s, "name") else "class"
        if k in ("interface_declaration", "type_alias_declaration", "enum_declaration"):
            word = {"interface_declaration": "interface", "type_alias_declaration": "type", "enum_declaration": "enum"}[k]
            return f"{word} {self.text(self.field(s, 'name'))}" if self.field(s, "name") else word
        if k == "method_definition":
            return f"method {self.text(self.field(s, 'name'))}" if self.field(s, "name") else "method"
        if k in ("lexical_declaration", "variable_declaration"):
            names = []
            for d in self.kids(s):
                if self.kind(d) != "variable_declarator" or self.field(d, "name") is None:
                    continue
                v = self.field(d, "value")
                fn = v is not None and self.kind(v) in ("arrow_function", "function_expression", "function")
                names.append(("function " if fn else "") + self.text(self.field(d, "name")))
            return ", ".join(names) or "declaration"
        if k == "import_statement":
            return "import"
        if k == "return_statement":
            return "return"
        if k == "expression_statement" and self.ts.named_count(s):
            call = self.kids(s)[0]
            if self.kind(call) == "call_expression":
                head = self.callee(call)
                args = [a for a in self.kids(self.field(call, "arguments") or call)]
                title = next((self.text(a) for a in args[:1] if self.kind(a) in ("string", "template_string")), "")
                return f"{head}({title})" if title else head
        if k in ("public_field_definition", "field_definition", "property_signature"):
            n = self.field(s, "name")
            return self.text(n) if n is not None else k
        return k.replace("_", " ")


def units(req, raw):
    """POST /syntax/units — a file's units at a branch's tip (or a commit)."""
    try:
        d = json.loads(raw or "{}")
        branch, commit, rel = str(d.get("branch") or ""), str(d.get("sha") or ""), str(d["path"])
        if not (branch or commit) or commit.startswith("-") or branch.startswith("-"):
            raise KeyError("branch")
    except (ValueError, KeyError, TypeError):
        return req._send(400, json.dumps({"ok": False, "message": "want {branch or sha, path}"}))
    if os.path.isabs(rel) or ".." in rel.split("/"):
        return req._send(400, json.dumps({"ok": False, "message": f"bad path {rel}"}))
    ext = os.path.splitext(rel)[1]
    if ext not in LANGS:
        return req._send(200, json.dumps({"ok": True, "units": None, "functions": None, "classes": None, "message": f"no grammar for {ext or 'this file'}"}))
    repo = ctx.repo_cwd()
    ref = commit or f"refs/heads/{branch}"
    sha = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "-q", f"{ref}^{{commit}}"],
                         capture_output=True, text=True).stdout.strip()
    if not sha:
        return req._send(200, json.dumps({"ok": False, "message": f"no commit {commit or branch}"}))
    blob = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "-q", f"{sha}:{rel}"],
                          capture_output=True, text=True).stdout.strip()
    if not blob:
        return req._send(200, json.dumps({"ok": True, "sha": sha, "units": [], "functions": [], "classes": [], "message": "not in this commit"}))
    key = f"{blob}|{ext}"
    hit = _cache.get(key)
    if hit is None:
        src = subprocess.run(["git", "-C", repo, "cat-file", "blob", blob], capture_output=True).stdout
        try:
            us, (fns, classes) = units_of(src, ext)
        except (OSError, RuntimeError, AttributeError) as e:
            return req._send(200, json.dumps({"ok": False, "message": f"can't read its syntax: {e}"}))
        hit = {"units": us, "functions": fns, "classes": classes}
        if len(_cache) > 512:
            _cache.clear()
        _cache[key] = hit
    req._send(200, json.dumps({"ok": True, "sha": sha, **hit}))
