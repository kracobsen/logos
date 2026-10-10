#!/usr/bin/env python3 -I
"""Builds the onboarding site in docs/onboarding/site/ from the chapters and notes in docs/onboarding/.

    python3 -I docs/onboarding/build.py           # build, warn about problems
    python3 -I docs/onboarding/build.py --strict  # also fail on warnings (stale ranges, unannotated files)

Source code is never copied into the notes: every code block is read from the repository at build time, so the
site always shows the code as it is. Notes refer to it by line ranges.

Chapters (chapters/*.html) are hand-written HTML fragments. Their first line is a comment giving the order and title:
    <!-- 10 | Start here -->

Notes (notes/*.txt) annotate source files. Format:

    # order: 30
    # title: Domain
    # subtitle: the shared vocabulary
    Page intro in note markup, up to the first file.

    === LogosKit/Sources/Domain/Clock.swift
    File intro in note markup.
    --- 1-12
    Note for lines 1 to 12.
    --- 13-
    Note for line 13 to the end of the file.

Ranges must be ascending and not overlap; lines no range covers are shown without a note.

Note markup: blank lines separate paragraphs; `- ` starts a bullet; `code`, **bold**, *italic*, [text](url);
[[Module/File.swift]] or [[Module/File.swift:42]] links to an annotated file (any unique path suffix works);
[[#chapter-id]] links to a chapter section, [[term:Book]] to a glossary term. A paragraph starting with `!ios `
is an "iOS & Swift" explainer box, `!why ` a "Why it is like this" box, `!rule ` a "House rule" box.
"""

import html
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
OUT = HERE / "site"
STRICT = "--strict" in sys.argv
warnings = []


def warn(message):
    warnings.append(message)
    print("warning: " + message, file=sys.stderr)


# ---------------------------------------------------------------------------------------------------------------
# Syntax highlighting

SWIFT_KEYWORDS = set(
    """
    actor any as associatedtype async await break case catch class continue convenience default defer deinit didSet
    do dynamic else enum extension fallthrough false fileprivate final for func get guard if import in indirect init
    inout internal is isolated lazy let mutating nil nonisolated nonmutating open operator override package private
    protocol public repeat required rethrows return self Self set some static struct subscript super switch throw
    throws true try typealias unowned var weak where while willSet consuming borrowing sending
    """.split()
)

SWIFT_TOKEN = re.compile(
    r"""
    (?P<doc>///[^\n]*)
  | (?P<comment>//[^\n]*|/\*.*?\*/)
  | (?P<string>\#?\"\"\".*?\"\"\"\#?|\#?"(?:\\.|[^"\\\n])*"\#?)
  | (?P<attr>@[A-Za-z_][A-Za-z0-9_]*)
  | (?P<directive>\#[A-Za-z_]+)
  | (?P<number>\b(?:0x[0-9A-Fa-f_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:e[+-]?\d+)?)\b)
  | (?P<ident>[A-Za-z_][A-Za-z0-9_]*)
    """,
    re.S | re.X,
)

HASH_COMMENT = re.compile(r"""(?P<comment>(?:^|(?<=\s))\#[^\n]*)|(?P<string>"(?:\\.|[^"\\\n])*"|'[^'\n]*')""", re.M)
SLASH_COMMENT = re.compile(r"""(?P<comment>//[^\n]*)|(?P<string>"(?:\\.|[^"\\\n])*")""")
XML_TOKEN = re.compile(r"""(?P<comment><!--.*?-->)|(?P<keyword></?[A-Za-z][^>\s]*|/?>)|(?P<string>"[^"]*")""", re.S)
JSON_TOKEN = re.compile(r"""(?P<attr>"(?:\\.|[^"\\])*"(?=\s*:))|(?P<string>"(?:\\.|[^"\\])*")|(?P<number>-?\d+(?:\.\d+)?)""")


def tokens(text, path):
    """Yields (css class or None, text) covering `text`."""
    suffix = path.suffix
    if suffix == ".swift":
        pattern = SWIFT_TOKEN
    elif suffix in (".sh", ".yml", ".yaml") or path.name == ".gitignore":
        pattern = HASH_COMMENT
    elif suffix == ".xcconfig" or path.name.endswith(".xcconfig.template"):
        pattern = SLASH_COMMENT
    elif suffix in (".plist", ".entitlements", ".xcscheme", ".xml"):
        pattern = XML_TOKEN
    elif suffix == ".json" or path.name == ".swift-format":
        pattern = JSON_TOKEN
    else:
        yield None, text
        return
    position = 0
    for match in pattern.finditer(text):
        if match.start() > position:
            yield None, text[position : match.start()]
        kind = match.lastgroup
        value = match.group()
        if kind == "ident":
            if value in SWIFT_KEYWORDS:
                kind = "keyword"
            elif value[0].isupper():
                kind = "type"
            else:
                kind = None
        yield kind, value
        position = match.end()
    if position < len(text):
        yield None, text[position:]


def highlighted_lines(text, path):
    """The file as a list of HTML lines, each with its spans closed."""
    lines = [""]
    for kind, value in tokens(text, path):
        for index, part in enumerate(value.split("\n")):
            if index:
                lines.append("")
            if part:
                escaped = html.escape(part, quote=False)
                lines[-1] += '<span class="t-%s">%s</span>' % (kind, escaped) if kind else escaped
    if lines and lines[-1] == "" and text.endswith("\n"):
        lines.pop()
    return lines


# ---------------------------------------------------------------------------------------------------------------
# Note markup

file_index = {}  # repo path -> (page file name, anchor)
chapter_ids = {}  # section id -> page file name
glossary_terms = set()


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def file_anchor(path):
    return "f-" + slug(path)


def resolve_file(ref):
    matches = [p for p in file_index if p == ref or p.endswith("/" + ref)]
    if len(matches) == 1:
        return matches[0]
    warn("cross-reference [[%s]] matches %d annotated files" % (ref, len(matches)))
    return None


def link(ref, current_page):
    if ref.startswith("#"):
        section = ref[1:]
        page = chapter_ids.get(section)
        if page is None:
            warn("cross-reference [[%s]] names no chapter section" % ref)
            return "<code>%s</code>" % html.escape(ref)
        target = ("" if page == current_page else page) + "#" + section
        label = chapter_titles.get(section, section)
        return '<a class="xref" href="%s">%s</a>' % (target, html.escape(label))
    if ref.startswith("term:"):
        term = ref[5:]
        if term not in glossary_terms:
            warn("glossary term [[%s]] isn't in GLOSSARY.md" % ref)
        target = ("" if current_page == "glossary.html" else "glossary.html") + "#term-" + slug(term)
        return '<a class="term" href="%s">%s</a>' % (target, html.escape(term))
    path, _, line = ref.partition(":")
    found = resolve_file(path)
    if found is None:
        return "<code>%s</code>" % html.escape(ref)
    page, anchor = file_index[found]
    target = ("" if page == current_page else page) + "#" + anchor + ("-L" + line if line else "")
    label = found.split("/")[-1] + (":" + line if line else "")
    return '<a class="xref" href="%s"><code>%s</code></a>' % (target, html.escape(label))


INLINE = re.compile(
    r"`(?P<code>[^`]+)`|\[\[(?P<xref>[^\]]+)\]\]|\*\*(?P<bold>.+?)\*\*|(?<![\w*])\*(?P<em>[^*\s][^*]*?)\*(?![\w*])"
    r"|\[(?P<text>[^\]]+)\]\((?P<url>[^)\s]+)\)"
)


def inline(text, page):
    out = []
    position = 0
    for match in INLINE.finditer(text):
        out.append(html.escape(text[position : match.start()], quote=False))
        if match.group("code") is not None:
            out.append("<code>%s</code>" % html.escape(match.group("code"), quote=False))
        elif match.group("xref") is not None:
            out.append(link(match.group("xref").strip(), page))
        elif match.group("bold") is not None:
            out.append("<strong>%s</strong>" % inline(match.group("bold"), page))
        elif match.group("em") is not None:
            out.append("<em>%s</em>" % inline(match.group("em"), page))
        else:
            out.append('<a href="%s">%s</a>' % (html.escape(match.group("url")), inline(match.group("text"), page)))
        position = match.end()
    out.append(html.escape(text[position:], quote=False))
    return "".join(out)


BOXES = {"!ios ": ("box-ios", "iOS &amp; Swift"), "!why ": ("box-why", "Why it is like this"), "!rule ": ("box-rule", "House rule")}


def markup(text, page):
    blocks = re.split(r"\n\s*\n", text.strip())
    out = []
    for block in blocks:
        if not block.strip():
            continue
        lines = block.split("\n")
        box = next((key for key in BOXES if block.startswith(key)), None)
        if box:
            css, label = BOXES[box]
            body = markup(block[len(box) :], page)
            out.append('<aside class="box %s"><div class="box-label">%s</div>%s</aside>' % (css, label, body))
        elif all(re.match(r"\s*- ", line) or (line.startswith("  ") and i) for i, line in enumerate(lines)):
            items = []
            for line in lines:
                if re.match(r"\s*- ", line):
                    items.append(re.sub(r"^\s*- ", "", line))
                else:
                    items[-1] += " " + line.strip()
            out.append("<ul>%s</ul>" % "".join("<li>%s</li>" % inline(item, page) for item in items))
        else:
            out.append("<p>%s</p>" % inline(" ".join(line.strip() for line in lines), page))
    return "\n".join(out)


# ---------------------------------------------------------------------------------------------------------------
# Notes files

class Section:
    def __init__(self, start, end, note):
        self.start, self.end, self.note = start, end, note


class AnnotatedFile:
    def __init__(self, path, intro):
        self.path, self.intro, self.sections = path, intro, []


class NotesPage:
    def __init__(self, source):
        self.source = source
        self.order, self.title, self.subtitle, self.intro = 99, source.stem, "", ""
        self.files = []
        self.name = source.stem + ".html"


def parse_notes(source):
    page = NotesPage(source)
    current_file = None
    current_section = None
    buffer = []

    def flush():
        text = "\n".join(buffer).strip("\n")
        buffer.clear()
        if current_section is not None:
            current_section.note = text
        elif current_file is not None:
            current_file.intro = text
        else:
            page.intro = text

    for number, line in enumerate(source.read_text().split("\n"), 1):
        header = re.match(r"# (order|title|subtitle): (.*)$", line)
        if header and current_file is None and not page.intro and not buffer:
            key, value = header.groups()
            if key == "order":
                page.order = int(value)
            else:
                setattr(page, key, value.strip())
            continue
        if line.startswith("=== "):
            flush()
            current_file = AnnotatedFile(line[4:].strip(), "")
            current_section = None
            page.files.append(current_file)
            continue
        ranged = re.match(r"--- (\d+)-(\d*)\s*$", line)
        if ranged and current_file is not None:
            flush()
            start = int(ranged.group(1))
            end = int(ranged.group(2)) if ranged.group(2) else None
            current_section = Section(start, end, "")
            current_file.sections.append(current_section)
            continue
        if line.startswith("--- ") or line.startswith("==="):
            warn("%s:%d: malformed marker %r" % (source.name, number, line))
        buffer.append(line)
    flush()
    return page


# ---------------------------------------------------------------------------------------------------------------
# Rendering

pages = []  # (order, file name, title) for the navigation
chapter_titles = {}


def nav(current):
    items = []
    for _, name, title in sorted(pages):
        css = ' class="current"' if name == current else ""
        items.append('<li><a href="%s"%s>%s</a></li>' % (name, css, html.escape(title)))
    return "<ul>%s</ul>" % "".join(items)


def page_html(name, title, body, toc):
    return """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} · Logos onboarding</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
<nav class="sidebar">
<a class="brand" href="index.html"><span class="lambda">λ</span> Logos onboarding</a>
{nav}
{toc}
</nav>
<main>
{body}
<footer>Generated by <code>docs/onboarding/build.py</code> from the repository as it is. Edit the chapters and notes in
<code>docs/onboarding/</code>, never the generated pages.</footer>
</main>
</body>
</html>
""".format(title=html.escape(title), nav=nav(name), toc=toc, body=body)


def render_file(annotated, page_name):
    path = REPO / annotated.path
    if not path.exists():
        warn("%s annotates %s, which doesn't exist" % (page_name, annotated.path))
        return ""
    text = path.read_text()
    lines = highlighted_lines(text, path)
    count = len(lines)
    anchor = file_anchor(annotated.path)

    sections = []
    previous_end = 0
    for section in annotated.sections:
        end = count if section.end is None else section.end
        if section.start <= previous_end or section.start > count or end < section.start:
            warn("%s: %s: range %d-%s overlaps, is out of order or is past the end (%d lines)"
                 % (page_name, annotated.path, section.start, section.end or "", count))
            continue
        if end > count:
            warn("%s: %s: range %d-%d runs past the end (%d lines)" % (page_name, annotated.path, section.start, end, count))
            end = count
        if section.start > previous_end + 1:
            sections.append((previous_end + 1, section.start - 1, ""))
        sections.append((section.start, end, section.note))
        previous_end = end
    if previous_end < count:
        sections.append((previous_end + 1, count, ""))
    if not annotated.sections:
        warn("%s: %s has no annotated ranges" % (page_name, annotated.path))

    rows = []
    for start, end, note in sections:
        code = "".join(
            '<span class="line" id="%s-L%d"><a class="ln" href="#%s-L%d">%d</a>%s</span>'
            % (anchor, n, anchor, n, n, lines[n - 1])
            for n in range(start, end + 1)
        )
        css = "row" if note.strip() else "row bare"
        rows.append(
            '<div class="%s"><div class="note">%s</div><pre class="code"><code>%s</code></pre></div>'
            % (css, markup(note, page_name), code)
        )
    github = "https://github.com/kracobsen/logos/blob/main/" + annotated.path
    return """<section class="file" id="{anchor}">
<header class="file-head"><h2><code>{path}</code></h2><span class="meta">{count} lines · <a href="{github}">GitHub</a></span></header>
<div class="file-intro">{intro}</div>
<details class="source" open><summary>Annotated source</summary>
{rows}
</details>
</section>""".format(anchor=anchor, path=html.escape(annotated.path), count=count, github=github,
                     intro=markup(annotated.intro, page_name), rows="\n".join(rows))


def render_notes_page(page):
    toc = '<div class="toc"><div class="toc-label">On this page</div><ul>%s</ul></div>' % "".join(
        '<li><a href="#%s">%s</a></li>' % (file_anchor(f.path), html.escape(f.path.split("/")[-1])) for f in page.files
    )
    head = '<header class="page-head"><h1>%s</h1>%s</header>' % (
        html.escape(page.title),
        '<p class="subtitle">%s</p>' % html.escape(page.subtitle) if page.subtitle else "",
    )
    files = "\n".join(render_file(f, page.name) for f in page.files)
    controls = ('<p class="controls"><button onclick="document.querySelectorAll(\'details.source\').forEach(d=>d.open=false)">'
                'Collapse all source</button> <button onclick="document.querySelectorAll(\'details.source\')'
                '.forEach(d=>d.open=true)">Expand all source</button></p>')
    body = head + '<div class="intro">%s</div>' % markup(page.intro, page.name) + controls + files
    return page_html(page.name, page.title, body, toc)


def render_glossary():
    text = (REPO / "GLOSSARY.md").read_text()
    entries = re.findall(r"\*\*(.+?)\*\*:\n(.+?)\n_Avoid_: (.+?)\n", text + "\n")
    rows = []
    for term, definition, avoid in entries:
        rows.append(
            '<div class="term-entry" id="term-%s"><dt>%s</dt><dd>%s<p class="avoid">Avoid: %s</p></dd></div>'
            % (slug(term), html.escape(term), html.escape(definition), html.escape(avoid))
        )
    body = """<header class="page-head"><h1>Glossary</h1><p class="subtitle">Generated from <code>GLOSSARY.md</code>.</p></header>
<div class="intro"><p>The domain language of Logos. These words are capitalised in code comments, docs and UI copy
when they mean exactly this (a <em>Book</em>, a <em>Download</em>), and the "avoid" words are kept out of the code so
there is only one name per idea. When you name a type or write a comment, pick from this list.</p></div>
<dl class="glossary">%s</dl>""" % "\n".join(rows)
    return page_html("glossary.html", "Glossary", body, "")


def main():
    for term in re.findall(r"^\*\*(.+?)\*\*:", (REPO / "GLOSSARY.md").read_text(), re.M):
        glossary_terms.add(term)

    chapters = []
    for source in sorted((HERE / "chapters").glob("*.html")):
        text = source.read_text()
        first = re.match(r"<!--\s*(\d+)\s*\|\s*(.+?)\s*-->\n", text)
        if not first:
            warn("%s has no '<!-- order | title -->' first line" % source.name)
            continue
        name = "index.html" if source.stem == "index" else source.stem + ".html"
        chapters.append((int(first.group(1)), name, first.group(2), text[first.end():]))
        pages.append((int(first.group(1)), name, first.group(2)))
        for section, title in re.findall(r'<h[23] id="([^"]+)">(.*?)</h[23]>', text):
            chapter_ids[section] = name
            chapter_titles[section] = re.sub(r"<[^>]+>", "", title)

    notes = [parse_notes(source) for source in sorted((HERE / "notes").glob("*.txt"))]
    for page in notes:
        pages.append((page.order, page.name, page.title))
        for f in page.files:
            if f.path in file_index:
                warn("%s is annotated twice" % f.path)
            file_index[f.path] = (page.name, file_anchor(f.path))
    pages.append((900, "glossary.html", "Glossary"))

    OUT.mkdir(exist_ok=True)
    for stale in OUT.glob("*.html"):
        stale.unlink()
    (OUT / "style.css").write_text((HERE / "style.css").read_text())
    for order, name, title, text in chapters:
        # Chapters may use [[...]] cross-references too.
        text = re.sub(r"\[\[([^\]]+)\]\]", lambda m: link(m.group(1).strip(), name), text)
        toc_items = re.findall(r'<h2 id="([^"]+)">(.*?)</h2>', text)
        toc = '<div class="toc"><div class="toc-label">On this page</div><ul>%s</ul></div>' % "".join(
            '<li><a href="#%s">%s</a></li>' % (i, t) for i, t in toc_items) if toc_items else ""
        (OUT / name).write_text(page_html(name, title, text, toc))
    for page in notes:
        (OUT / page.name).write_text(render_notes_page(page))
    (OUT / "glossary.html").write_text(render_glossary())

    # Every Swift source file, script and config should be annotated somewhere.
    import subprocess

    tracked = subprocess.run(["git", "ls-files"], cwd=REPO, capture_output=True, text=True).stdout.split()
    expected = [p for p in tracked if re.match(r"(LogosKit/Sources|Logos)/.*\.swift$|LogosUITests/.*\.swift$|scripts/|Config/(?!Local\.xcconfig$)|LogosKit/Package\.swift$", p)]
    for path in expected:
        if path not in file_index:
            warn("%s isn't annotated on any page" % path)

    print("Built %d pages into %s" % (len(pages), OUT.relative_to(REPO)))
    if warnings:
        print("%d warning(s)" % len(warnings), file=sys.stderr)
        if STRICT:
            sys.exit(1)


if __name__ == "__main__":
    main()
