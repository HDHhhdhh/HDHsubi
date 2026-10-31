"""Offline contracts only. These tests never create a Hancom COM object."""
from contextlib import contextmanager
from copy import deepcopy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
import postprocess as p
import run
from template import build_template


class PortableTests(unittest.TestCase):
    def test_public_template_has_only_heading_text_and_generated_images(self):
        with tempfile.TemporaryDirectory() as temp:
            package = p.Package(build_template(Path(temp) / "template.hwpx"))
            found = p.headings(package)
            self.assertEqual({k: len(v) for k, v in found.items()},
                             {"header": 1, "quick": 1, "explanation": 1})
            texts = [s.strip() for _, section in package.sections
                     for s in section.xpath(".//hp:t/text()", namespaces=p.NS) if s.strip()]
            self.assertEqual(texts, ["프린트 제목", "공부하자", "빠른 정답", "프린트 제목", "해설", "프린트 제목"])
            self.assertFalse(any(name.startswith(("Preview/", "Scripts/")) for name in package.parts))
            images = [data for name, data in package.parts.items() if name.startswith("BinData/")]
            self.assertEqual(len(images), 2)
            self.assertEqual(images[0], images[1])
            self.assertLess(len(images[0]), 100)
            self.assertFalse(package.sections[0][1].findall(".//hp:endNote", p.NS))

    def test_canonical_job_uses_tasks_and_does_not_request_deletion(self):
        source, target, cancel = map(Path, ("source.hml", "paper.hwpx", "cancel"))
        job = run.conversion_job(source, target, "hwpx", cancel)
        self.assertEqual(job["tasks"][0]["plannedOutputPaths"], {"hwpx": "paper.hwpx"})
        self.assertEqual(job["tasks"][0]["targets"], ["hwpx"])
        self.assertEqual(job["options"], {"cancelPath": "cancel"})
        self.assertNotIn("deleteOriginal", job)

    def test_converter_requires_success_event_not_only_exit_zero(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for index, (event, code, success) in enumerate([
                ({"type": "complete", "ok": True, "summary": {"failed": 0, "succeeded": 1}}, 0, True),
                ({"type": "complete", "ok": False, "summary": {"failed": 1, "succeeded": 0}}, 0, False),
                ({"type": "log", "ok": True}, 0, False),
                ({"type": "complete", "ok": True, "summary": {"failed": 0, "succeeded": 1}}, 1, False),
            ]):
                result = subprocess.CompletedProcess([], code, (json.dumps(event) + "\n").encode())
                with patch.object(run.subprocess, "run", return_value=result) as invoke:
                    args = (root, root / f"job{index}.json", {}, root / f"events{index}.jsonl")
                    if success:
                        self.assertEqual(run.convert(*args)["succeeded"], 1)
                    else:
                        with self.assertRaises(RuntimeError):
                            run.convert(*args)
                    command = invoke.call_args.args[0]
                    self.assertIn("-InputJsonPath", command)
                    self.assertTrue(command[command.index("-File") + 1].endswith("convert-hwp.ps1"))

    def test_existing_output_json_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / "receipt.json"
            run.write_json(target, {"original": True})
            with self.assertRaises(FileExistsError):
                run.write_json(target, {})
            self.assertEqual(json.loads(target.read_text()), {"original": True})

    def test_layout_keeps_order_and_overflow_as_singletons(self):
        columns = p.allocate_columns([2000, 2500, 9000], 10000, 1000, 2)
        self.assertEqual([c["problems"] for c in columns], [[0, 1], [2]])
        self.assertEqual(columns[0]["gap"], 2250)
        self.assertEqual(columns[1]["gap"], 0)

    def test_known_first_reference_repair_preserves_text_and_shared_style(self):
        with tempfile.TemporaryDirectory() as temp:
            package = p.Package(build_template(Path(temp) / "template.hwpx"))
            props = package.header.find(".//hh:paraProperties", p.NS)
            numbered = deepcopy(props[0])
            numbered.set("id", str(max(int(n.get("id")) for n in props) + 1))
            heading = numbered.find("hh:heading", p.NS)
            self.assertIsNotNone(heading)
            heading.set("type", "NUMBER")
            props.append(numbered)
            section = package.sections[0][1]
            references = []
            for index in range(2):
                paragraph = p.E.SubElement(section, "{" + p.NS["hp"] + "}p",
                                          paraPrIDRef=numbered.get("id"))
                ref = p.E.SubElement(paragraph, "{" + p.NS["hp"] + "}run", charPrIDRef=str(index))
                ctrl = p.E.SubElement(ref, "{" + p.NS["hp"] + "}ctrl")
                p.E.SubElement(ctrl, "{" + p.NS["hp"] + "}endNote")
                references.append(ref)
            before = p.fingerprint(package)
            self.assertTrue(run.repair_first_reference(p, package))
            self.assertEqual(p.fingerprint(package), before)
            self.assertEqual(references[0].get("charPrIDRef"), "1")
            self.assertEqual(heading.get("type"), "NUMBER")
            self.assertEqual(props[-1].find("hh:heading", p.NS).get("type"), "NONE")

    def test_com_session_closes_before_temporary_directory_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = build_template(root / "source.hwpx")
            donor = build_template(root / "donor.hwpx")
            events = []
            native_temp = tempfile.TemporaryDirectory

            @contextmanager
            def checked_temp(**kwargs):
                with native_temp(**kwargs) as work:
                    yield work
                    self.assertEqual(events, ["opened", "closed"])

            class Hwp:
                def Clear(self, mode):
                    pass

            @contextmanager
            def com():
                events.append("opened")
                yield Hwp()
                events.append("closed")

            def layout(package, title, work, session, replaced):
                with session():
                    pass
                return package, {"status": "complete"}

            with patch.object(p.tempfile, "TemporaryDirectory", checked_temp), \
                    patch.object(p, "auto_layout", layout):
                p.process(source, root / "output.hwpx", "Synthetic lifecycle",
                          root / "validation.json", template=donor, com_factory=com)
            self.assertEqual(events, ["opened", "closed"])


if __name__ == "__main__":
    unittest.main()
