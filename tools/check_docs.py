#!/usr/bin/env python3
"""Documentation gate for docs/.

Checks, in this order:

1. Links: every relative Markdown link in docs/ resolves to a file or directory.
2. Citations: every `path.ext:LINE` code citation in the checked trees points at
   a file that exists and a line that is in range.
3. Quoted blocks: every ```zig block in the checked trees appears in the source
   file named by the `file.zig:LINE` citation above it, in order, so a quoted
   declaration cannot drift from the code it claims to quote.
4. Budgets: docs/budgets.json ceilings are respected, and every page under the
   covered trees has a row (a new page without a budget is a config error, the
   same way a new src file without a provenance row is).

Scope: links are checked across all of docs/. Citations, blocks and budgets are
checked in the trees listed in CHECKED_TREES plus the single-file entries in
CHECKED_FILES, so the older hand-written references can be migrated one at a
time instead of failing the gate on day one.

Exit status is 1 with a printed report when any check fails.

Usage: python3 tools/check_docs.py [--quiet] [--all] [--only SUBSTRING]
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"

# Trees whose citations, quoted blocks and budgets are enforced.
CHECKED_TREES = ("subsystems", "catalogs", "cookbook", "postmortem")
CHECKED_FILES = ("AGENTS.md", "glossary.md", "testing.md")

# A path that resolves to one of these is a citation of an external artifact we
# do not have in this checkout, so only its shape is informational.
EXTERNAL_PREFIXES = ("..", "/")

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
CITATION_RE = re.compile(
    r"([A-Za-z0-9_][A-Za-z0-9_./-]*\.(?:zig|zon|md|toml|xml|json|sh|py|html|ts|c|h))"
    r":(\d+)(?:-(\d+))?"
)
FENCE_RE = re.compile(r"^(\s*)(`{3,}|~{3,})\s*([A-Za-z0-9_+-]*)\s*$")
BUDGETS = DOCS / "budgets.json"

MAX_REPORT = 12

# A quoted block may elide neighbouring lines with an explicit marker. Anything
# else in a block must be a consecutive run of the cited source.
ELISION_RE = re.compile(r"^//\s*(\.\.\.|\(.*omitted.*\)).*$")


def rel(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def markdown_files() -> list[Path]:
    return sorted(p for p in DOCS.rglob("*.md") if p.is_file())


def is_checked(path: Path) -> bool:
    try:
        parts = path.relative_to(DOCS).parts
    except ValueError:
        return False
    if len(parts) == 1:
        return parts[0] in CHECKED_FILES
    return parts[0] in CHECKED_TREES


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def check_links(text: str, path: Path, failures: list[str]) -> int:
    total = 0
    for match in LINK_RE.finditer(text):
        target = match.group(1)
        if target.startswith(("http://", "https://", "mailto:", "#", "<")):
            continue
        total += 1
        target = target.split("#", 1)[0]
        if not target:
            continue
        resolved = (path.parent / target).resolve()
        if not resolved.exists():
            failures.append(f"{rel(path)}: dead link {target}")
    return total


def resolve_cited(cited: str) -> tuple[Path | None, str]:
    """Resolve a citation to a source file.

    A repo-relative path is used as written. A bare or partial name is accepted
    only when exactly one file in `src/` ends with it, so `peer.zig:41` resolves
    while an ambiguous `join.zig:31` stays a defect in the page.
    """
    direct = ROOT / cited
    if direct.is_file():
        return direct, "ok"
    if cited.startswith(EXTERNAL_PREFIXES):
        return None, "missing"
    matches = [p for p in ROOT.glob(f"src/**/{cited}") if p.is_file()]
    if len(matches) == 1:
        return matches[0], "ok"
    if len(matches) > 1:
        return None, "ambiguous"
    return None, "missing"


def check_citations(text: str, path: Path, failures: list[str]) -> int:
    total = 0
    for match in CITATION_RE.finditer(text):
        cited, start, end = match.group(1), int(match.group(2)), match.group(3)
        if cited.startswith(EXTERNAL_PREFIXES) or "7dtd-engine-research" in cited:
            continue
        total += 1
        source, state = resolve_cited(cited)
        if state == "ambiguous":
            failures.append(
                f"{rel(path)}: citation {cited}:{start} is ambiguous; "
                "use a repo-relative path"
            )
            continue
        if source is None:
            failures.append(f"{rel(path)}: citation to missing file {cited}:{start}")
            continue
        last = int(end) if end else start
        line_count = len(read_text(source).splitlines())
        if start > line_count or last > line_count:
            failures.append(
                f"{rel(path)}: citation {cited}:{start}"
                + (f"-{last}" if end else "")
                + f" is past the end of the file ({line_count} lines)"
            )
    return total


def iter_zig_blocks(text: str):
    """Yield (start_line_index, lines) for every fenced zig block."""
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = FENCE_RE.match(lines[i])
        if not m:
            i += 1
            continue
        fence, lang = m.group(2), m.group(3).lower()
        if lang != "zig":
            i += 1
            continue
        body = []
        j = i + 1
        while j < len(lines) and not lines[j].strip().startswith(fence[:3]):
            body.append(lines[j])
            j += 1
        yield i, body
        i = j + 1


def citation_before(text: str, block_start: int) -> tuple[str, int] | None:
    """Last repository file:LINE citation in the prose above a block, if any."""
    head = "\n".join(text.splitlines()[:block_start])
    found = None
    for match in CITATION_RE.finditer(head):
        cited = match.group(1)
        if cited.startswith(EXTERNAL_PREFIXES):
            continue
        found = (cited, int(match.group(2)))
    return found


def citations_before(text: str, block_start: int, limit: int = 6) -> list[tuple[str, int]]:
    """Repository file:LINE citations in the prose above a block, nearest first.

    A paragraph may cite several files, so the block is tried against each in
    turn rather than against the last one only.
    """
    head = "\n".join(text.splitlines()[:block_start])
    found = []
    for match in CITATION_RE.finditer(head):
        cited = match.group(1)
        if cited.startswith(EXTERNAL_PREFIXES):
            continue
        found.append((cited, int(match.group(2))))
    found.reverse()
    return found[:limit]


def block_matches(body: list[str], source_lines: list[str], cited_line: int) -> str | None:
    """Return the first drifted block line, or None when the block matches."""
    cursor = max(0, cited_line - 1)
    for body_line in body:
        needle = body_line.rstrip()
        if not needle.strip() or ELISION_RE.match(needle.strip()):
            continue
        hit = None
        for index in range(cursor, len(source_lines)):
            if source_lines[index] == needle:
                hit = index
                break
        if hit is None:
            return body_line
        cursor = hit + 1
    return None


def check_blocks(text: str, path: Path, failures: list[str]) -> int:
    total = 0
    for start, body in iter_zig_blocks(text):
        total += 1
        anchors = citations_before(text, start)
        if not anchors:
            failures.append(
                f"{rel(path)}:{start + 1}: zig block with no file.zig:LINE citation above it"
            )
            continue
        first_failure = None
        for cited, cited_line in anchors:
            source, state = resolve_cited(cited)
            if source is None:
                if first_failure is None:
                    first_failure = (
                        f"{rel(path)}:{start + 1}: zig block cites "
                        f"{'ambiguous' if state == 'ambiguous' else 'missing'} "
                        f"file {cited}:{cited_line}"
                    )
                continue
            source_lines = [line.rstrip() for line in read_text(source).splitlines()]
            drifted = block_matches(body, source_lines, cited_line)
            if drifted is None:
                first_failure = None
                break
            if first_failure is None:
                first_failure = (
                    f"{rel(path)}:{start + 1}: quoted block does not match "
                    f"{cited}:{cited_line} (first drifted line: {drifted.strip()[:70]!r})"
                )
        if first_failure is not None:
            failures.append(first_failure)
    return total


def check_budgets(failures: list[str]) -> int:
    if not BUDGETS.is_file():
        failures.append(f"missing {rel(BUDGETS)} (word ceilings for the checked trees)")
        return 0
    try:
        manifest = json.loads(read_text(BUDGETS))
    except json.JSONDecodeError as exc:
        failures.append(f"{rel(BUDGETS)}: not valid JSON: {exc}")
        return 0
    docs = manifest.get("docs")
    if not isinstance(docs, dict):
        failures.append(f"{rel(BUDGETS)}: expected a top-level 'docs' object")
        return 0

    total = 0
    covered: set[str] = set()
    for name, ceiling in sorted(docs.items()):
        path = ROOT / name
        covered.add(name)
        if not path.is_file():
            failures.append(f"{rel(BUDGETS)}: listed document {name} does not exist")
            continue
        if not isinstance(ceiling, int) or ceiling <= 0:
            failures.append(f"{rel(BUDGETS)}: ceiling for {name} must be a positive integer")
            continue
        words = len(read_text(path).split())
        total += 1
        if words > ceiling:
            failures.append(
                f"{name}: {words} words exceeds its {ceiling}-word ceiling "
                "(relocate detail, condense, or raise the ceiling in the same change)"
            )

    for path in markdown_files():
        if not is_checked(path):
            continue
        name = rel(path)
        if name not in covered:
            failures.append(f"{rel(BUDGETS)}: {name} has no budget row")
    return total


PAGE_CONTRACT = {
    "subsystems": ("Sources:", "## See also"),
}


def check_page_contracts(failures: list[str]) -> int:
    """Each subsystem page carries the markers its page contract requires.

    A page without a `Sources:` line or a `See also` section is not reachable
    from the code it documents, or from its siblings.
    """
    total = 0
    for tree, markers in PAGE_CONTRACT.items():
        directory = DOCS / tree
        if not directory.is_dir():
            continue
        for page in sorted(directory.glob("*.md")):
            if page.name == "README.md":
                continue
            total += 1
            text = read_text(page)
            for marker in markers:
                if marker not in text:
                    failures.append(
                        f"{rel(page)}: missing {marker!r} required by the page contract"
                    )
    return total


def check_registries(failures: list[str]) -> int:
    """Every page in a checked tree must be listed by that tree's README.

    The README is the registry for its tier (docs/AGENTS.md), so a page that is
    not linked from it is invisible to a reader starting at the map.
    """
    total = 0
    for tree in CHECKED_TREES:
        directory = DOCS / tree
        if not directory.is_dir():
            continue
        readme = directory / "README.md"
        listed = read_text(readme) if readme.is_file() else ""
        for page in sorted(directory.glob("*.md")):
            if page.name == "README.md":
                continue
            total += 1
            if f"({page.name})" not in listed:
                failures.append(
                    f"{rel(readme) if readme.is_file() else tree}: "
                    f"{rel(page)} has no registry row in the tree README"
                )
    return total


def main() -> int:
    argv = sys.argv[1:]
    quiet = "--quiet" in argv
    global MAX_REPORT
    if "--all" in argv:
        MAX_REPORT = 10**6
    only = None
    if "--only" in argv:
        index = argv.index("--only")
        if index + 1 < len(argv):
            only = argv[index + 1]

    failures: list[str] = []
    links = citations = blocks = budgets = 0

    for path in markdown_files():
        if only is not None and only not in rel(path):
            continue
        text = read_text(path)
        links += check_links(text, path, failures)
        if is_checked(path):
            citations += check_citations(text, path, failures)
            blocks += check_blocks(text, path, failures)
    budgets = 0 if only else check_budgets(failures)
    if only is None:
        check_registries(failures)
        check_page_contracts(failures)

    if failures:
        for line in failures[:MAX_REPORT]:
            print(f"check_docs: {line}", file=sys.stderr)
        if len(failures) > MAX_REPORT:
            print(
                f"check_docs: ... and {len(failures) - MAX_REPORT} more",
                file=sys.stderr,
            )
        print(
            f"check_docs: {len(failures)} failure(s) "
            f"({links} links, {citations} citations, {blocks} quoted blocks, {budgets} budgets)",
            file=sys.stderr,
        )
        return 1

    if not quiet:
        print(
            f"check_docs: ok ({links} links, {citations} citations, "
            f"{blocks} quoted blocks, {budgets} budgets)"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
