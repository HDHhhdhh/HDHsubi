"""Validate the public snapshot; this does not validate live MathSecr behavior."""
import hashlib
import json
import re
import sys
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
ALLOWED = {".ps1", ".py", ".js", ".cjs", ".md", ".yaml", ".json", ".html"}
ROOT_NAMES = {".gitignore", ".gitattributes", "README.md", "AGENTS.md", "SOURCE_SNAPSHOT.json"}
FORBIDDEN_PARTS = {".omo", ".codex", ".agents", "node_modules", "tmp", ".tmp", "output", "evaluation-sets", "__pycache__"}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    errors = []
    checked = 0
    total_bytes = 0
    # Token shapes match actual values, not source code mentioning token names.
    patterns = [
        ("GitHub token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,})\b")),
        ("API key", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{30,}\b")),
        ("private key", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
        ("personal Windows path", re.compile(r"\b[A-Z]:[/\\]+Users[/\\]+(?!alice[/\\]+)[\w .-]+[/\\]", re.I)),
        ("personal email", re.compile(r"\b[A-Za-z0-9._%+-]+@(?:naver|gmail|daum)\.com\b", re.I)),
    ]
    for path in sorted(ROOT.rglob("*")):
        relative = path.relative_to(ROOT)
        if ".git" in relative.parts:
            continue
        if path.is_symlink():
            errors.append(f"symlink: {relative}")
            continue
        if not path.is_file():
            continue
        if any(part in FORBIDDEN_PARTS for part in relative.parts):
            errors.append(f"private/generated directory: {relative}")
        if path.name not in ROOT_NAMES and path.suffix not in ALLOWED:
            errors.append(f"unexpected file type: {relative}")
        if len(relative.parts) == 1 and path.name not in ROOT_NAMES:
            errors.append(f"unexpected root file: {relative}")
        text = path.read_text(encoding="utf-8-sig")
        for label, pattern in patterns:
            if pattern.search(text):
                errors.append(f"{label}: {relative}")
        # Only synthetic example paper URLs are allowed in copied test code/docs.
        for number in re.findall(r"https?://(?:www\.)?mathsecr\.com/mypaper/(\d+)", text):
            if number not in {"1", "123", "124", "12345"}:
                errors.append(f"non-synthetic paper URL: {relative}")
        if path.suffix == ".json":
            try:
                json.loads(text)
            except ValueError:
                errors.append(f"invalid JSON: {relative}")
        checked += 1
        total_bytes += path.stat().st_size
    snapshot = json.loads((ROOT / "SOURCE_SNAPSHOT.json").read_text(encoding="utf-8"))
    for record in snapshot["files"]:
        path = (ROOT / record["path"]).resolve()
        if not path.is_relative_to(ROOT) or not path.is_file() or digest(path) != record["exportSha256"]:
            errors.append(f"snapshot hash drift: {record['path']}")
        if record["sourceSha256"] != record["exportSha256"] and not record["transformation"]:
            errors.append(f"undeclared transformation: {record['path']}")
    # Archived canonical kit docs refer to intentionally withheld private assets.
    # Validate every link in the newly authored public narrative instead.
    markdown = [ROOT / "README.md", ROOT / "AGENTS.md", *sorted((ROOT / "docs").rglob("*.md"))]
    links = 0
    for path in markdown:
        text = path.read_text(encoding="utf-8")
        for link in re.findall(r"\[[^\]]*\]\(([^)]+)\)", text):
            target = link.strip().strip("<>")
            if re.match(r"(?:https?|mailto):", target):
                continue
            file_name, _, anchor = target.partition("#")
            destination = (path.parent / unquote(file_name)).resolve() if file_name else path
            if not destination.is_relative_to(ROOT) or not destination.is_file():
                errors.append(f"missing/unsafe link: {path.relative_to(ROOT)} -> {target}")
            elif anchor and not re.search(r"^#{1,6}\s+" + re.escape(anchor) + r"\s*$", destination.read_text(encoding="utf-8"), re.M | re.I):
                errors.append(f"missing anchor: {path.relative_to(ROOT)} -> {target}")
            links += 1
    print(json.dumps({"status": "FAIL" if errors else "PASS", "files": checked, "bytes": total_bytes, "snapshotFiles": len(snapshot["files"]), "publicDocumentLinks": links, "errors": errors}, ensure_ascii=False))
    return 1 if errors else 0

if __name__ == "__main__":
    sys.exit(main())
