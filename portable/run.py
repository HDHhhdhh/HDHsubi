"""HML -> canonical HDHangyul -> heading/macro/spacing -> canonical PDF export."""
import argparse
from contextlib import contextmanager
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
from setup import verify_engine
from template import build_template


def write_json(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)


def conversion_job(source, target, kind, cancel_path):
    return {"options": {"cancelPath": str(cancel_path)}, "tasks": [{
        "id": kind, "inputPath": str(source), "inputName": source.name,
        "targets": [kind], "plannedOutputPaths": {kind: str(target)}}]}


def convert(engine, job_path, job, log_path):
    write_json(job_path, job)
    result = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                             "-File", str(engine / "scripts/convert-hwp.ps1"),
                             "-InputJsonPath", str(job_path)],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log_path.write_bytes(result.stdout)
    events = [json.loads(line) for line in result.stdout.decode("utf-8-sig").splitlines() if line.strip()]
    complete = [e for e in events if e.get("type") == "complete"]
    summary = complete[-1].get("summary", {}) if complete else {}
    if (result.returncode or not complete or not complete[-1].get("ok") or
            summary.get("failed") != 0 or summary.get("succeeded") != 1):
        raise RuntimeError(f"Converter failed; inspect {log_path}")
    return summary


def repair_first_reference(p, package):
    """Apply only the known first-note duplicate-number pattern, not arbitrary edits."""
    notes = [n for _, section in package.sections for n in section.findall(".//hp:endNote", p.NS)]
    if len(notes) < 2:
        return False
    runs = [n.getparent().getparent() for n in notes]
    first = runs[0]
    paragraph = first.getparent()
    props = package.header.find(".//hh:paraProperties", p.NS)
    original = next(n for n in props if n.get("id") == paragraph.get("paraPrIDRef"))
    heading = original.find("hh:heading", p.NS)
    if heading is None or heading.get("type") != "NUMBER":
        return False
    styles = {r.get("charPrIDRef") for r in runs[1:]}
    p.require(len(styles) == 1 and p.local(paragraph) == "p" and
              not first.findall("./hp:t", p.NS) and not first.findall("./hp:equation", p.NS),
              "First reference repair is ambiguous")
    before = p.fingerprint(package)
    first.set("charPrIDRef", styles.pop())
    cloned = deepcopy(original)
    cloned.set("id", str(max(int(n.get("id")) for n in props) + 1))
    cloned.find("hh:heading", p.NS).attrib.update({"type": "NONE", "idRef": "0", "level": "0"})
    props.append(cloned)
    props.set("itemCnt", str(len(props)))
    paragraph.set("paraPrIDRef", cloned.get("id"))
    p.require(p.fingerprint(package) == before, "First reference repair changed content")
    return True


def run(args):
    if os.name != "nt":
        raise ValueError("Windows with Hancom Office is required")
    source, runtime, output = args.input.resolve(), args.runtime.resolve(), args.output.resolve()
    if source.suffix.lower() != ".hml" or not source.is_file():
        raise ValueError("Supply an existing HML file")
    if not args.title.strip() or args.title == "프린트 제목" or any(ord(c) < 32 for c in args.title):
        raise ValueError("Supply the actual single-line paper title")
    engine = runtime / "HDHangyul"
    verify_engine(engine)
    if Path(sys.prefix).resolve() != (runtime / ".venv").resolve():
        raise ValueError("Run using the Python installed at RUNTIME/.venv/Scripts/python.exe")
    # Exclusive local ownership; stale locks need manual investigation, never reclamation.
    lock_path = runtime / "hancom.lock"
    with lock_path.open("x", encoding="utf-8") as lock:
        lock.write(str(os.getpid()))
    try:
        output.mkdir(parents=True, exist_ok=False)
        converted = output / "converted.hwpx"
        styled = output / "styled.hwpx"
        final = output / "paper.hwpx"
        pdf = output / "paper.pdf"
        original_hash = hashlib.sha256(source.read_bytes()).hexdigest()
        template = args.template.resolve() if args.template else build_template(output / "template.hwpx")
        report = {"status": "running", "sourceSha256": original_hash, "title": args.title}
        job = conversion_job(source, converted, "hwpx", output / "cancel")
        if args.plan_only:
            write_json(output / "conversion-job.json", job)
            report["status"] = "planned"
            write_json(output / "receipt.json", report)
            return report
        report["conversion"] = convert(engine, output / "conversion-job.json", job,
                                       output / "conversion-events.jsonl")
        import postprocess as p
        original = p.xml(source.read_bytes())
        package = p.Package(converted)
        # Master pages are outside fingerprint's main-story scope; compare separately.
        masters = original.xpath("//*[local-name()='MASTERPAGE']")
        source_masters = ["".join(n.xpath(".//*[local-name()='CHAR']/text()")) for n in masters]
        target_masters = [p.text(tree) for name, tree in sorted(package.trees.items())
                          if name.startswith("Contents/masterpage")]
        p.require(source_masters == target_masters, "Masterpage text changed")
        for master in masters:
            master.getparent().remove(master)
        p.validate_conversion(original, package)
        style = json.loads(args.style_json.read_text(encoding="utf-8")) if args.style_json else None
        validation = p.process(converted, styled, args.title, output / "validation.json",
                               template=template, style=style)
        p.require(validation["status"] == "complete" and not validation["warnings"],
                  "Macro/layout is partial; PDF export stopped. Inspect validation.json")
        package = p.Package(styled)
        report["firstReferenceRepaired"] = repair_first_reference(p, package)
        before = p.fingerprint(package)
        work = output / "intermediate"
        work.mkdir()
        with p.fresh_hwp() as hwp:
            @contextmanager
            def session():
                hwp.Clear(1)
                yield hwp
            if report["firstReferenceRepaired"]:
                package, layout = p.auto_layout(package, args.title, work, session,
                                                {"header", "quick", "explanation"})
            else:
                layout = validation["layout"]
            p.require(layout["status"] == "complete", "Final layout incomplete")
            package.save(final)
            section, blocks, _ = p.problem_blocks(package, args.title)
            reopened, positions, pages = p.layout_roundtrip(package, work, "reopened", blocks, session)
            geometry = [p.layout_geometry([reopened.sections[0][1][section.index(n)] for n in block])
                        for block in blocks]
            p.require(positions == layout["positions"] and geometry == layout["geometry"],
                      "Native reopen changed spacing")
            p.require(p.fingerprint(reopened) == before, "Native reopen changed content")
        report.update({"layout": layout, "pages": pages, "nativeReopenVerified": True})
        report["pdf"] = convert(engine, output / "pdf-job.json",
                                conversion_job(final, pdf, "pdf", output / "cancel"),
                                output / "pdf-events.jsonl")
        p.require(pdf.is_file() and pdf.read_bytes().startswith(b"%PDF-"), "PDF missing or invalid")
        p.require(hashlib.sha256(source.read_bytes()).hexdigest() == original_hash, "Original HML changed")
        report.update({"status": "produced-needs-visual-qa",
                       "outputs": {path.name: p.sha(path) for path in (converted, final, pdf)}})
        write_json(output / "receipt.json", report)
        return report
    finally:
        lock_path.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New directory; never overwrite")
    parser.add_argument("--title", required=True)
    parser.add_argument("--template", type=Path)
    parser.add_argument("--style-json", type=Path)
    parser.add_argument("--plan-only", action="store_true", help="No Hancom, registry write or PDF export")
    print(json.dumps(run(parser.parse_args()), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
