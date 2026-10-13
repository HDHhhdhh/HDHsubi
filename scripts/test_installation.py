"""Public installer contracts and optional real, cross-platform installation."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import install

# macOS exposes its temp tree through /var -> /private/var. Use its canonical
# spelling for the synthetic harness, whose cleanup rejects linked ancestors.
if sys.platform == 'darwin':
    tempfile.tempdir = str(Path(tempfile.gettempdir()).resolve())
    os.environ['TMPDIR'] = tempfile.tempdir


class InstallerTests(unittest.TestCase):
    def test_public_sources_complete(self):
        files = install.package_files()
        self.assertIn('mathsecr-paper-builder-kit/scripts/production_validation.ps1', [p for p, _ in files])
        self.assertFalse(any(p.startswith('.omo/') for p, _ in files))

    def test_missing_modified_duplicate_sources(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'scripts').mkdir()
            file = root / 'payload.md'
            file.write_text('original', encoding='utf-8')
            record = {'path': 'payload.md', 'sha256': install.digest(file)}
            manifest = root / 'scripts/runtime-package.json'
            manifest.write_text(json.dumps({'schemaVersion': 1, 'files': [record]}))
            self.assertEqual(len(install.package_files(root)), 1)
            file.write_text('modified')
            with self.assertRaisesRegex(ValueError, 'modified source'):
                install.package_files(root)
            file.unlink()
            with self.assertRaisesRegex(ValueError, 'Missing'):
                install.package_files(root)
            file.write_text('original')
            manifest.write_text(json.dumps({'schemaVersion': 1, 'files': [record, record]}))
            with self.assertRaisesRegex(ValueError, 'Duplicate'):
                install.package_files(root)

    def test_traversal_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            for path in ('../outside.md', '/absolute.md', 'a/../outside.md', 'a//b.md', 'C:/file.md', 'a\\b.md'):
                with self.subTest(path=path), self.assertRaises(ValueError):
                    install.safe_path(Path(temp), path)

    def test_linked_path_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'outside').mkdir()
            try:
                (root / 'link').symlink_to(root / 'outside', target_is_directory=True)
            except OSError:
                self.skipTest('This Windows user cannot create symlinks; macOS CI exercises the link gate')
            with self.assertRaisesRegex(ValueError, 'Linked'):
                install.safe_path(root, 'link/file.md')

    def test_conflict_stops_before_environment_mutation(self):
        with tempfile.TemporaryDirectory() as temp:
            project = Path(temp) / 'workspace'; project.mkdir()
            codex = Path(temp) / 'codex'
            (project / 'AGENTS.md').write_text('custom policy')
            with patch.object(install, 'prepare_runtime') as prepare:
                with self.assertRaisesRegex(ValueError, 'Existing file differs'):
                    install.install(project, codex)
                prepare.assert_not_called()
                self.assertFalse(codex.exists())
                self.assertEqual((project / 'AGENTS.md').read_text(), 'custom policy')

    def test_force_preserves_custom_files_and_backs_up_conflict(self):
        with tempfile.TemporaryDirectory() as temp:
            project = Path(temp) / 'workspace'; project.mkdir()
            codex = Path(temp) / 'codex'
            (project / 'AGENTS.md').write_text('custom policy')
            (project / 'custom.md').write_text('keep')
            # This unit test verifies copy/backup behavior only, not runtime readiness.
            with patch.object(install, 'ensure_tools'), patch.object(install, 'prepare_runtime', return_value=install.runtime_python(project)), patch.object(install, 'check'):
                install.install(project, codex, force=True)
            backups = list((project / '.hdhsubi/backups').iterdir())
            self.assertTrue(any(p.read_text() == 'custom policy' for p in backups))
            self.assertEqual((project / 'custom.md').read_text(), 'keep')
            skill = codex / 'skills/mathsecr-paper-builder/SKILL.md'
            self.assertTrue((codex / 'skills/aside-browser/SKILL.md').is_file())
            self.assertEqual(install.digest(skill), install.digest(install.ROOT / 'mathsecr-paper-builder-kit/skills/mathsecr-paper-builder/SKILL.md'))
            skill.write_text('drift')
            with self.assertRaisesRegex(ValueError, 'sync failure'):
                install.check(project, codex)


def integration():
    with tempfile.TemporaryDirectory(prefix='hdhsubi-install-') as temp:
        project = Path(temp) / '작업 공간'; codex = Path(temp) / 'codex home'
        command = [sys.executable, str(install.ROOT / 'scripts/install.py'), '--project-root', str(project), '--codex-home', str(codex)]
        subprocess.run(command, check=True)
        subprocess.run(command, check=True)  # Same source reinstall is idempotent.
        subprocess.run(command + ['--check'], check=True)
        py = install.runtime_python(project)
        env = os.environ.copy(); env['PATH'] = str(py.parent) + os.pathsep + env.get('PATH', ''); env['PYTHONUTF8'] = '1'
        # Generate a real Korean PDF from public synthetic image bytes.
        code = '''
from pathlib import Path
import json, sys, subprocess
from PIL import Image
from pypdf import PdfReader
r=Path(sys.argv[1]); Image.new('RGB',(320,240),'white').save(r/'synthetic.png')
(r/'crop.json').write_text(json.dumps({'title':'공개 설치 검사','source':'synthetic source','items':[{'problem_number':'1','image':'synthetic.png','crop':[0,0,320,240]}]},ensure_ascii=False),encoding='utf-8')
subprocess.run([sys.executable,str(r/'mathsecr-paper-builder-kit/scripts/create_failed_problem_report.py'),'--manifest','crop.json','--output','report.pdf','--project-root',str(r)],check=True)
pdf=PdfReader(r/'report.pdf'); assert len(pdf.pages)==1; assert '실패 문제 이미지 크롭 보고서' in pdf.pages[0].extract_text()
print('KoreanPdf PASS')
'''
        subprocess.run([str(py), '-c', code, str(project)], env=env, check=True)
        pwsh = install.tool_path('pwsh')
        subprocess.run([pwsh, '-NoProfile', '-File', str(install.ROOT / 'scripts/test_runtime_paths.ps1')], env=env, check=True)
        subprocess.run([pwsh, '-NoProfile', '-File', str(install.ROOT / 'scripts/test_surface_contract.ps1')], env=env, check=True)
        print('PublicInstallationIntegration PASS (fresh runtime, repeat install, sync, Korean PDF, production Select/BeforeNext/AfterReload; no live browser claim)')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--integration', action='store_true'); args = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(InstallerTests))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if args.integration:
        integration()
