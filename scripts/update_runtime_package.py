"""Refresh public package identities after reviewed source changes."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    snapshot_path = ROOT / 'SOURCE_SNAPSHOT.json'
    snapshot = json.loads(snapshot_path.read_text(encoding='utf-8'))
    for item in snapshot['files']:
        path = ROOT / item['path']
        current = sha(path)
        if current != item['exportSha256']:
            item['exportSha256'] = current
            item['bytes'] = path.stat().st_size
            item['transformation'] = (item.get('transformation') or '') + '; public-runtime installation and Windows/macOS portability'
    snapshot_path.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
    paths = sorted(p for p in (ROOT / 'mathsecr-paper-builder-kit').rglob('*') if p.is_file() and '__pycache__' not in p.parts)
    paths += [ROOT / 'scripts' / name for name in ('install.py', 'run.py', 'bootstrap.ps1', 'install_aside.ps1', 'check_runtime.ps1', 'runtime-dependencies.json')]
    paths += [ROOT / 'docs/installation.md']
    manifest = {'schemaVersion': 1, 'profile': 'public-runtime', 'privateBundleRequired': False,
                'files': [{'path': p.relative_to(ROOT).as_posix(), 'sha256': sha(p)} for p in paths]}
    (ROOT / 'scripts/runtime-package.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8', newline='\n')


if __name__ == '__main__':
    main()
