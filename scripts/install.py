"""Install the public runtime without the historical private regression bundle."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import venv

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'scripts/runtime-package.json'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def safe_path(root, relative):
    """Reject traversal and linked destinations before resolving them."""
    parts = PurePosixPath(relative).parts
    if not parts or relative != '/'.join(parts) or any(p in ('.', '..') for p in parts) or ':' in relative or '\\' in relative or relative.startswith('/'):
        raise ValueError(f'Unsafe package path: {relative}')
    full = root.joinpath(*parts)
    # macOS /var and /tmp are system aliases. Resolve the chosen root, while
    # rejecting links at or below that root where package writes occur.
    for ancestor in (full, *full.parents):
        if ancestor != root and not ancestor.is_relative_to(root):
            break
        if ancestor.is_symlink() or (hasattr(ancestor, 'is_junction') and ancestor.is_junction()):
            raise ValueError(f'Linked installation path: {ancestor}')
    if not full.resolve().is_relative_to(root.resolve()):
        raise ValueError(f'Path leaves installation root: {relative}')
    return full


def package_files(root=ROOT):
    manifest = json.loads((root / 'scripts/runtime-package.json').read_text(encoding='utf-8'))
    if manifest.get('schemaVersion') != 1 or not manifest.get('files'):
        raise ValueError('Invalid runtime package manifest')
    seen = set()
    files = []
    for record in manifest['files']:
        path = record['path']
        if path in seen:
            raise ValueError(f'Duplicate package path: {path}')
        seen.add(path)
        source = safe_path(root, path)
        if not source.is_file() or digest(source) != record['sha256']:
            raise ValueError(f'Missing or modified source package file: {path}')
        files.append((path, source))
    return files


def runtime_python(project):
    return project / '.hdhsubi/venv' / ('Scripts/python.exe' if os.name == 'nt' else 'bin/python')


def tool_path(name):
    found = shutil.which(name)
    if found:
        return found
    candidates = {
        'pwsh': [Path(os.environ.get('ProgramFiles', 'C:/Program Files')) / 'PowerShell/7/pwsh.exe', Path('/opt/homebrew/bin/pwsh'), Path('/usr/local/bin/pwsh')],
        'aside': [Path(os.environ.get('LOCALAPPDATA', '.')) / 'Aside/CLI/current/aside.exe', Path.home() / '.local/bin/aside'],
        'brew': [Path('/opt/homebrew/bin/brew'), Path('/usr/local/bin/brew')],
    }
    return next((str(p) for p in candidates.get(name, []) if p.is_file()), None)


def run(args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)


def ensure_tools(install_tools):
    pwsh = tool_path('pwsh')
    if not pwsh and install_tools:
        if os.name == 'nt' and tool_path('winget'):
            run(['winget', 'install', '--id', 'Microsoft.PowerShell', '--exact', '--source', 'winget', '--accept-source-agreements', '--accept-package-agreements'])
        elif platform.system() == 'Darwin' and tool_path('brew'):
            run([tool_path('brew'), 'install', '--cask', 'powershell'])
        pwsh = tool_path('pwsh')
    if not pwsh:
        raise ValueError('PowerShell 7 is required. See docs/installation.md. On macOS: brew install --cask powershell. On Windows: winget install --id Microsoft.PowerShell --exact --source winget. Retry in a new terminal.')
    run([pwsh, '-NoProfile', '-Command', 'if ($PSVersionTable.PSVersion.Major -lt 7) { exit 2 }'])
    if not tool_path('aside') and install_tools and platform.system() == 'Darwin' and tool_path('brew'):
        run([tool_path('brew'), 'install', '--cask', 'aside'])
    if not tool_path('aside') and install_tools:
        if os.name == 'nt':
            run([pwsh, '-NoProfile', '-File', ROOT / 'scripts/install_aside.ps1'])
        elif platform.system() == 'Darwin':
            with tempfile.TemporaryDirectory(prefix='hdhsubi-aside-') as temp:
                path = Path(temp) / 'install.sh'
                # Use the official macOS curl transport, not Python urllib's
                # distinct user agent (which some release CDNs reject).
                run(['curl', '-fsSL', '--connect-timeout', '20', '--max-time', '120', 'https://releases.aside.com/install.sh', '-o', path])
                run(['bash', path])
        if not tool_path('aside'):
            raise ValueError('Aside CLI installation did not produce a discoverable CLI. See the official Developer settings and docs/installation.md; retry in a new terminal.')
    # Browser app setup/login remains interactive; do not invent silent flags.
    return pwsh


def prepare_runtime(project):
    py = runtime_python(project)
    env_root = py.parent.parent
    safe_path(project, '.hdhsubi/venv')
    if not py.exists():
        venv.EnvBuilder(with_pip=True).create(env_root)
    dependencies = json.loads((ROOT / 'scripts/runtime-dependencies.json').read_text(encoding='utf-8'))
    run([py, '-m', 'pip', 'install', '--disable-pip-version-check', *dependencies['pythonPackages']])
    font_root = safe_path(project, '.hdhsubi/venv/share/mathsecr-fonts')
    font_root.mkdir(parents=True, exist_ok=True)
    for font in dependencies['fonts']:
        dest = font_root / font['name']
        if dest.is_file() and digest(dest) == font['sha256']:
            continue
        request = urllib.request.Request(font['url'], headers={'User-Agent': 'HDHsubi-installer/1'})
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read(8 * 1024 * 1024)
        if hashlib.sha256(data).hexdigest() != font['sha256']:
            raise ValueError(f'Font download hash mismatch: {font["name"]}')
        dest.write_bytes(data)
    return py


def destinations(files, project, codex_home):
    result = [(source, safe_path(project, relative)) for relative, source in files]
    result += [(ROOT / 'scripts/runtime-package.json', safe_path(project, 'scripts/runtime-package.json'))]
    result += [(ROOT / 'mathsecr-paper-builder-kit/AGENTS.md', safe_path(project, 'AGENTS.md'))]
    prefix = 'mathsecr-paper-builder-kit/skills/'
    for relative, source in files:
        if relative.startswith(prefix):
            result.append((source, safe_path(codex_home, 'skills/' + relative[len(prefix):])))
    return result


def check(project, codex_home, require_browser=False):
    receipt_path = safe_path(project, '.hdhsubi/install-receipt.json')
    if not receipt_path.is_file():
        raise ValueError('No completed installation receipt. Run the public installer first.')
    receipt = json.loads(receipt_path.read_text(encoding='utf-8'))
    if receipt.get('schemaVersion') != 1 or receipt.get('profile') != 'public-runtime' or receipt.get('codexHome') != str(codex_home):
        raise ValueError('Installation receipt does not match this profile or Codex home')
    # Always compare the current source package as well as the installed bytes.
    for source, dest in destinations(package_files(), project, codex_home):
        if not dest.is_file() or digest(source) != digest(dest):
            raise ValueError(f'Installation sync failure: {dest}')
    py = runtime_python(project)
    dependencies = json.loads((ROOT / 'scripts/runtime-dependencies.json').read_text(encoding='utf-8'))
    for font in dependencies['fonts']:
        path = py.parent.parent / 'share/mathsecr-fonts' / font['name']
        if not path.is_file() or digest(path) != font['sha256']:
            raise ValueError(f'Installed font missing or modified: {font["name"]}')
    run([py, '-c', 'import PIL, reportlab, pypdf, pymupdf; print("PythonRuntime PASS")'])
    pwsh = ensure_tools(False)
    run([pwsh, '-NoProfile', '-File', project / 'scripts/check_runtime.ps1', '-ProjectRoot', project])
    browser = 'cli-found-login-not-verified' if tool_path('aside') else 'setup-required'
    if require_browser:
        env = os.environ.copy()
        if tool_path('aside'):
            env['PATH'] = str(Path(tool_path('aside')).parent) + os.pathsep + env.get('PATH', '')
        result = subprocess.run([pwsh, '-NoProfile', '-File', project / 'mathsecr-paper-builder-kit/scripts/check_aside_repl.ps1', '-HostId', 'local'], capture_output=True, text=True, timeout=70, env=env, check=True)
        probe = json.loads(result.stdout)
        if probe['Availability']['Status'] != 'ready':
            raise ValueError('Aside local REPL is not ready. Open Aside, complete its setup, and retry. No remote fallback is allowed.')
        browser = 'local-repl-ready-paper-login-not-verified'
    print(json.dumps({'status': 'PASS', 'profile': 'public-runtime', 'sync': 'PASS', 'browser': browser, 'livePaperVerified': False}))


def install(project, codex_home, force=False, install_tools=False):
    files = package_files()  # Missing source bytes fail before target mutation.
    copies = destinations(files, project, codex_home)
    for source, dest in copies:
        if dest.exists() and not dest.is_file():
            raise ValueError(f'Destination is not a file: {dest}')
        if dest.is_file() and digest(dest) != digest(source) and not force:
            raise ValueError(f'Existing file differs: {dest}. Review it, then use --force to back it up and replace it.')
    ensure_tools(install_tools)
    project.mkdir(parents=True, exist_ok=True)
    py = prepare_runtime(project)
    for source, dest in copies:
        if dest.is_file() and digest(dest) == digest(source):
            continue
        if dest.is_file():
            backup_root = safe_path(project, '.hdhsubi/backups')
            backup_root.mkdir(parents=True, exist_ok=True)
            backup = backup_root / (hashlib.sha256(str(dest).encode()).hexdigest() + '-' + digest(dest))
            if not backup.exists():
                shutil.copyfile(dest, backup)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, dest)
    receipt = {'schemaVersion': 1, 'profile': 'public-runtime', 'codexHome': str(codex_home), 'python': str(py), 'privateBundleRequired': False}
    (project / '.hdhsubi/install-receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')
    check(project, codex_home)
    print(f'Open this workspace in Codex: {project}')
    print('Next: docs/installation.md and mathsecr-paper-builder-kit/prompts/start-prompt.md. Aside and MathSecr login must be completed by the recipient.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project-root', required=True, type=Path)
    parser.add_argument('--codex-home', type=Path, default=Path(os.environ.get('CODEX_HOME') or Path.home() / '.codex'))
    parser.add_argument('--force', action='store_true')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--require-browser', action='store_true')
    parser.add_argument('--install-tools', action='store_true', help='Install missing PowerShell via WinGet/Homebrew and Aside via Homebrew on macOS')
    args = parser.parse_args()
    if sys.version_info < (3, 10):
        parser.error('Python 3.10 or newer is required; Python 3.12 is the tested baseline')
    project = args.project_root.expanduser().absolute()
    codex_home = args.codex_home.expanduser().absolute()
    for root in (project, codex_home):
        if root == Path(root.anchor) or root.is_symlink():
            parser.error('Installation roots must be ordinary directories below the filesystem root')
    if (not args.check and (project == ROOT or project.is_relative_to(ROOT) or ROOT.is_relative_to(project))) or project == codex_home or project.is_relative_to(codex_home) or codex_home.is_relative_to(project):
        parser.error('Use separate, non-overlapping source, workspace and Codex-home directories')
    try:
        if args.check:
            check(project, codex_home, args.require_browser)
        else:
            install(project, codex_home, args.force, args.install_tools)
            if args.require_browser:
                check(project, codex_home, True)
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        print(f'INSTALLATION FAILED: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
