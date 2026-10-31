"""Install the pinned converter and Python runtime; never starts Hancom."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import venv

ROOT = Path(__file__).resolve().parent
DEPS = json.loads((ROOT / "dependencies.json").read_text(encoding="utf-8"))


def verify_engine(engine):
    commit = subprocess.check_output(["git", "-C", str(engine), "rev-parse", "HEAD"], text=True).strip()
    if commit != DEPS["engineCommit"]:
        raise ValueError("Converter revision differs from dependencies.json")
    if subprocess.check_output(["git", "-C", str(engine), "status", "--porcelain"], text=True).strip():
        raise ValueError("Converter checkout must be clean")
    dll = engine / "scripts/FilePathCheckerModuleExample.dll"
    if hashlib.sha256(dll.read_bytes()).hexdigest() != DEPS["securityModuleSha256"]:
        raise ValueError("Hancom security DLL hash differs")
    return dll


def register_module(dll):
    import winreg
    key_name = r"SOFTWARE\HNC\HwpAutomation\Modules"
    name = "HDHsubiPortableFilePathChecker"
    for view in (winreg.KEY_WOW64_32KEY, winreg.KEY_WOW64_64KEY):
        with winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, key_name, 0,
                               winreg.KEY_READ | winreg.KEY_WRITE | view) as key:
            try:
                existing = winreg.QueryValueEx(key, name)[0]
            except FileNotFoundError:
                existing = str(dll)
            if Path(existing).resolve() != dll.resolve():
                raise ValueError(f"{name} already points elsewhere; preserve it: {existing}")
            winreg.SetValueEx(key, name, 0, winreg.REG_SZ, str(dll))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--skip-registration", action="store_true",
                        help="Download/install only; run setup again without this before COM use")
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("HML to PDF requires Windows and installed Hancom Office")
    runtime = args.runtime.resolve()
    runtime.mkdir(parents=True, exist_ok=True)
    engine = runtime / "HDHangyul"
    if not engine.exists():
        subprocess.run(["git", "clone", "--no-checkout", DEPS["engineRepository"], str(engine)], check=True)
        subprocess.run(["git", "-C", str(engine), "checkout", "--detach", DEPS["engineCommit"]], check=True)
    dll = verify_engine(engine)
    env = runtime / ".venv"
    if not env.exists():
        venv.EnvBuilder(with_pip=True).create(env)
    python = env / "Scripts/python.exe"
    subprocess.run([str(python), "-m", "pip", "install", *DEPS["pythonPackages"]], check=True)
    subprocess.run([str(python), "-c", "import lxml.etree, pythoncom, win32com.client"], check=True)
    if not args.skip_registration:
        register_module(dll)
    print(json.dumps({"status": "installed", "engineCommit": DEPS["engineCommit"],
                      "python": str(python), "securityModuleRegistered": not args.skip_registration}))


if __name__ == "__main__":
    main()
