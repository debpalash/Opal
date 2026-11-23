"""Independent-server capability matrix: validation, evidence lookup, doc rendering.

The matrix (docs/server-matrix.json) is the ceiling on what docs may claim
about Opal as a self-hosted server. Pure functions take file contents as
arguments; `check_repo` does the reading.
"""
from __future__ import annotations

import json
from pathlib import Path
import re

MATRIX_PATH = "docs/server-matrix.json"
DOC_PATH = "docs/headless-server-spec.md"
BEGIN, END = "<!-- server-matrix:begin -->", "<!-- server-matrix:end -->"
STATUSES = ("verified", "fixture-only", "unverified")
SUITES = ("ci", "opt-in", "real-provider")
ENVIRONMENTS = ("workstation", "nas_class")
CAPABILITIES = ("library_imports", "metadata_fixes", "multiple_users", "permissions",
                "backup_restore", "migrations", "transcode_limits", "concurrent_streams")

# A sentence claiming Opal stands in for a media server. Allowed only when every
# workstation cell is verified, or when the line itself negates/scopes it.
OVERCLAIM = re.compile(
    r"(replac(e|es|ing|ement)|drop-in|substitute)[^.\n]{0,30}(jellyfin|plex|emby|media server)"
    r"|(jellyfin|plex|emby)[^.\n]{0,20}(replacement|alternative)", re.IGNORECASE)
SCOPED = re.compile(r"rather than|\bnot\b|n't|needed to|\bearn\b", re.IGNORECASE)


def validate(matrix):
    problems = []
    if matrix.get("schema") != 1:
        problems.append("schema must be 1")
    ids = [c.get("id") for c in matrix.get("capabilities", [])]
    for missing in sorted(set(CAPABILITIES) - set(ids)):
        problems.append(f"capability {missing} missing")
    if len(ids) != len(set(ids)):
        problems.append("duplicate capability id")
    for cap in matrix.get("capabilities", []):
        for env in ENVIRONMENTS:
            cell = cap.get("cells", {}).get(env)
            where = f"{cap.get('id')}.{env}"
            if cell is None:
                problems.append(f"{where} missing")
                continue
            status, evidence = cell.get("status"), cell.get("evidence", [])
            if status not in STATUSES:
                problems.append(f"{where}: status {status!r} not in {STATUSES}")
            if status == "verified" and not evidence:
                problems.append(f"{where}: verified needs evidence")
            if status == "unverified" and evidence:
                problems.append(f"{where}: unverified cannot cite evidence")
            for item in evidence:
                if item.get("suite") not in SUITES:
                    problems.append(f"{where}: suite {item.get('suite')!r} not in {SUITES}")
                if "::" not in item.get("test", ""):
                    problems.append(f"{where}: locator {item.get('test')!r} needs file::name")
    return problems


def locate(locator, source):
    """True when `source` (the file's text) defines the test named by `locator`."""
    path, _, name = locator.partition("::")
    if path.endswith(".zig"):
        return f'test "{name}"' in source
    if path.startswith("tests/features/"):
        return f'@test("{name}"' in source
    cls, _, method = name.partition("::")
    return bool(method) and f"class {cls}(" in source and f"def {method}(" in source


def suite_problem(locator, suite, build_zig, workflows):
    """Check the suite label against how CI actually reaches the test."""
    path = locator.partition("::")[0]
    if path.endswith(".zig"):
        in_ci = f'b.path("{path}")' in build_zig and "zig build test" in workflows
    elif path.startswith("tests/features/"):
        in_ci = "tests/test_features.py" in workflows
    else:
        in_ci = path in workflows
    if suite == "ci" and not in_ci:
        return f"{locator}: labelled ci but no workflow runs it"
    if suite != "ci" and in_ci:
        return f"{locator}: labelled {suite} but CI runs it; relabel as ci"
    return None


def render(matrix):
    rows = ["| Capability | Workstation | NAS-class |", "| --- | --- | --- |"]
    for cap in matrix["capabilities"]:
        cells = []
        for env in ENVIRONMENTS:
            cell = cap["cells"][env]
            suites = sorted({e["suite"] for e in cell["evidence"]})
            cells.append(cell["status"] + (f" ({', '.join(suites)})" if suites else ""))
        rows.append(f"| {cap['label']} | {cells[0]} | {cells[1]} |")
    return "\n".join(rows)


def doc_table(doc):
    if BEGIN not in doc or END not in doc:
        return None
    return doc.split(BEGIN, 1)[1].split(END, 1)[0].strip()


def overclaims(text, matrix):
    """Lines claiming server replacement beyond what the matrix verifies."""
    if all(c["cells"]["workstation"]["status"] == "verified" for c in matrix["capabilities"]):
        return []
    return [(n, line.strip()) for n, line in enumerate(text.splitlines(), 1)
            if OVERCLAIM.search(line) and not SCOPED.search(line)]


def check_repo(root):
    root = Path(root)
    matrix = json.loads((root / MATRIX_PATH).read_text(encoding="utf-8"))
    problems = validate(matrix)
    if problems:
        return problems
    build_zig = (root / "build.zig").read_text(encoding="utf-8")
    workflows = "\n".join(p.read_text(encoding="utf-8") for p in sorted((root / ".github/workflows").glob("*.yml")))
    for cap in matrix["capabilities"]:
        for env in ENVIRONMENTS:
            for item in cap["cells"][env]["evidence"]:
                path = root / item["test"].partition("::")[0]
                if not path.is_file() or not locate(item["test"], path.read_text(encoding="utf-8")):
                    problems.append(f"{cap['id']}.{env}: test not found: {item['test']}")
                    continue
                problem = suite_problem(item["test"], item["suite"], build_zig, workflows)
                if problem:
                    problems.append(problem)
    table = doc_table((root / DOC_PATH).read_text(encoding="utf-8"))
    if table != render(matrix):
        problems.append(f"{DOC_PATH} matrix table differs from {MATRIX_PATH}; paste render() output")
    docs = [root / "README.md", *sorted((root / "docs").rglob("*.md"))]
    for doc in docs:
        if "benchmarks" in doc.parts:
            continue
        for line_no, line in overclaims(doc.read_text(encoding="utf-8"), matrix):
            problems.append(f"{doc.relative_to(root)}:{line_no}: claims more than the matrix verifies: {line[:120]}")
    return problems
