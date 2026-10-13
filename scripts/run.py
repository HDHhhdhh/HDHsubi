"""Run an installed helper with the workspace Python and local Aside CLI."""
import os
from pathlib import Path
import subprocess
import sys
from install import ROOT, runtime_python, safe_path, tool_path


def main():
    if len(sys.argv) < 2:
        raise ValueError('Usage: python scripts/run.py mathsecr-paper-builder-kit/scripts/<helper> [arguments]')
    script = safe_path(ROOT, sys.argv[1])
    py = runtime_python(ROOT)
    if not py.is_file():
        raise ValueError('This is a source checkout, not an installed workspace. Run scripts/install.py first.')
    env = os.environ.copy()
    env['PYTHONUTF8'] = '1'
    paths = [str(py.parent)]
    aside = tool_path('aside')
    if aside:
        paths.append(str(Path(aside).parent))
    env['PATH'] = os.pathsep.join(paths + [env.get('PATH', '')])
    if script.suffix == '.ps1':
        pwsh = tool_path('pwsh')
        if not pwsh:
            raise ValueError('PowerShell 7 was not found')
        command = [pwsh, '-NoProfile', '-File', str(script)]
    elif script.suffix == '.py':
        command = [str(py), str(script)]
    else:
        raise ValueError('Only .ps1 and .py helpers are supported')
    return subprocess.run(command + sys.argv[2:], cwd=ROOT, env=env).returncode


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
