"""Copy-only Hancom postprocessor. No rendering or delivery is performed.

CLI: --input ABS --output ABS --title NAME --report ABS [--template ABS]
[--logo ABS] [--style-json ABS] [--original-hml ABS].
Exit 0 means inspect report.status (complete or partial); exit 1
means failure. Existing output/report files are never overwritten.

The portable runner supplies a bundled, sanitized heading-resource template.
HDH_SUBI_HWPX_TEMPLATE or --template can supply a separately authorized branded
template. Its two images are reused unchanged. No private images are shipped.
"""

import argparse
from collections import Counter
from contextlib import ExitStack, contextmanager
from copy import deepcopy
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import struct
import sys
import tempfile
import zipfile
import zlib

from lxml import etree as E


NS = {
    "hp": "http://www.hancom.co.kr/hwpml/2011/paragraph",
    "hh": "http://www.hancom.co.kr/hwpml/2011/head",
    "hc": "http://www.hancom.co.kr/hwpml/2011/core",
    "opf": "http://www.idpf.org/2007/opf/",
}
GROUPS = {
    "borderFills": "borderFillIDRef", "charProperties": "charPrIDRef",
    "tabProperties": "tabPrIDRef", "numberings": "numberingIDRef",
    "paraProperties": "paraPrIDRef", "styles": "styleIDRef",
    "bullets": "bulletIDRef",
}
MAX_PACKAGE = 256 * 1024 * 1024
DEFAULT_TEMPLATE = Path(__file__).with_name("template.hwpx")
DEFAULT_STYLE = {
    "problemFont": "나눔명조", "problemSize": 11,
    "noteFont": "-윤고딕320", "numberFont": "-윤고딕340",
    "numberSize": 17, "problemIndent": -10,
}


def require(value, message):
    if value is None or (not isinstance(value, E._Element) and not value):
        raise ValueError(message)
    return value


def resolve_style(style=None):
    if style is None:
        return dict(DEFAULT_STYLE)
    require(isinstance(style, dict), "Style must be a JSON object")
    require(all(key in DEFAULT_STYLE for key in style), "Unknown style key")
    for key, value in style.items():
        if key.endswith("Font"):
            require(isinstance(value, str) and value.strip() and len(value) <= 100 and
                    value.splitlines() == [value] and not any(ord(c) < 32 for c in value),
                    "Style " + key + " must be a nonblank single-line font name of at most 100 characters")
        else:
            lower = -100 if key == "problemIndent" else 1
            require(type(value) in (int, float) and lower <= value <= 100 and math.isfinite(value),
                    "Style " + key + " must be a finite number in " + str(lower) + "..100")
    return {**DEFAULT_STYLE, **style}


def local(node):
    return E.QName(node).localname


def xml(data):
    require(len(data) <= MAX_PACKAGE, "XML size limit exceeded")
    root = E.fromstring(data, E.XMLParser(resolve_entities=False, no_network=True,
                                         load_dtd=False, huge_tree=False))
    require(not root.getroottree().docinfo.doctype, "DTD is not allowed")
    require(not any(isinstance(n, E._Entity) for n in root.iter()), "Entity is not allowed")
    return root


def text(node):
    return "".join(node.xpath(".//hp:t/text()", namespaces=NS))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def approved_logo(path):
    """Validate the requested combined PNG, then audit equivalent split reuse."""
    require(path.name == "_logo_5Ax.png" and path.is_file(), "Only approved combined _logo_5Ax.png is supported")
    data = path.read_bytes()
    require(len(data) <= 10 * 1024 * 1024 and data[:8] == b"\x89PNG\r\n\x1a\n", "Logo must be a PNG")
    offset, kinds, width, height = 8, [], None, None
    while offset < len(data):
        require(offset + 12 <= len(data), "Truncated logo PNG")
        size, kind = struct.unpack(">I4s", data[offset:offset + 8])
        end = offset + 12 + size
        require(end <= len(data), "Truncated logo PNG chunk")
        payload = data[offset + 8:offset + 8 + size]
        crc = struct.unpack(">I", data[end - 4:end])[0]
        require(zlib.crc32(kind + payload) & 0xffffffff == crc, "Logo PNG CRC mismatch")
        kinds.append(kind)
        if kind == b"IHDR":
            require(size == 13 and len(kinds) == 1, "Invalid logo PNG header")
            width, height = struct.unpack(">II", payload[:8])
        offset = end
    require(kinds and kinds[0] == b"IHDR" and kinds[-1] == b"IEND" and
            b"IDAT" in kinds and width and height and width > height,
            "Expected the approved horizontal combined logo PNG")
    return {"requestedPath": str(path), "requestedSha256": sha(path),
            "width": width, "height": height, "mode": "reference-split-equivalent"}


class Package:
    def __init__(self, path):
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            require(len(entries) <= 4096, "ZIP entry limit exceeded")
            require(sum(i.file_size for i in entries) <= MAX_PACKAGE, "ZIP size limit exceeded")
            names = [i.filename for i in entries]
            require(len(names) == len(set(n.casefold() for n in names)), "Duplicate ZIP path")
            for entry in entries:
                name = entry.filename
                require(not entry.flag_bits & 1, "Encrypted ZIP entry")
                require("\\" not in name and ":" not in name and
                        not PurePosixPath(name).is_absolute() and
                        ".." not in PurePosixPath(name).parts, "Unsafe ZIP path")
                require((entry.external_attr >> 16) & 0o170000 != 0o120000, "ZIP symlink")
                require(not name.lower().endswith((".js", ".vbs", ".hmi")), "Embedded script is not allowed")
                if name.lower().startswith("scripts/"):
                    # Hancom/MathSecr emits these inert document boilerplates.
                    # Permit only the exact observed stubs, never user macros.
                    allowed = {
                        "scripts/headerscripts": {"", "varDocuments=XHwpDocuments;varDocument=Documents.Active_XHwpDocument;"},
                        "scripts/sourcescripts": {"", "functionOnDocument_New(){//todo:}", "functionOnDocument_New(){}"},
                    }
                    code = archive.read(entry).decode("utf-16-le").lstrip("\ufeff")
                    require(re.sub(r"\s+", "", code) in allowed.get(name.lower(), set()),
                            "Embedded script is not an inert Hancom default stub")
            require(archive.testzip() is None, "ZIP CRC failure")
            self.parts = {i.filename: archive.read(i) for i in entries}
        require(self.parts.get("mimetype") == b"application/hwp+zip", "Not an HWPX package")
        self.trees = {name: xml(data) for name, data in self.parts.items()
                      if name.endswith((".xml", ".hpf", ".rdf"))}
        self.header = self.trees["Contents/header.xml"]
        self.content = self.trees["Contents/content.hpf"]
        self.sections = [(name, tree) for name, tree in self.trees.items()
                         if re.fullmatch(r"Contents/section\d+\.xml", name)]
        self.sections.sort(key=lambda pair: int(re.search(r"\d+", pair[0]).group()))
        require(self.sections, "Missing HWPX section")
        self.validate()

    def validate(self):
        ref = require(self.header.find("hh:refList", NS), "Missing reference list")
        mappings = {}
        for group, attr in GROUPS.items():
            nodes = ref.findall("hh:" + group + "/*", NS)
            ids = [n.get("id") for n in nodes]
            require(len(ids) == len(set(ids)), "Duplicate resource ID: " + group)
            mappings[attr] = set(ids)
        manifest = require(self.content.find("opf:manifest", NS), "Missing manifest")
        image_ids = set()
        for item in manifest:
            ident, href = item.get("id"), item.get("href", "")
            require(ident not in image_ids, "Duplicate manifest ID")
            image_ids.add(ident)
            if href.startswith("BinData/"):
                require(href in self.parts, "Missing binary: " + href)
        fonts = {}
        for face in ref.findall("hh:fontfaces/hh:fontface", NS):
            ids = [f.get("id") for f in face]
            require(len(ids) == len(set(ids)), "Duplicate font ID")
            fonts[face.get("lang", "").lower()] = set(ids)
        for root in [self.header] + [s for _, s in self.sections]:
            for node in root.iter():
                for attr, ids in mappings.items():
                    value = node.get(attr)
                    if value is None:
                        continue
                    if attr == "charPrIDRef" and local(node) == "paraHead" and value == "4294967295":
                        continue
                    require(value in ids, "Unresolved " + attr + ": " + value)
                if node.get("nextStyleIDRef") is not None:
                    require(node.get("nextStyleIDRef") in mappings["styleIDRef"], "Unresolved next style")
                if node.get("binaryItemIDRef") is not None:
                    require(node.get("binaryItemIDRef") in image_ids, "Unresolved image")
                if local(node) == "fontRef":
                    for lang, value in node.attrib.items():
                        require(value in fonts.get(lang, set()), "Unresolved font")
                if local(node) == "heading" and node.get("type") in ("NUMBER", "BULLET"):
                    attr = "numberingIDRef" if node.get("type") == "NUMBER" else "bulletIDRef"
                    require(node.get("idRef") in mappings[attr], "Unresolved paragraph heading")

    def save(self, path):
        for name, tree in self.trees.items():
            self.parts[name] = E.tostring(tree, encoding="UTF-8", xml_declaration=True,
                                         standalone=True)
        with path.open("xb") as stream, zipfile.ZipFile(stream, "w") as archive:
            archive.writestr("mimetype", self.parts["mimetype"], compress_type=zipfile.ZIP_STORED)
            for name, data in self.parts.items():
                if name != "mimetype":
                    archive.writestr(name, data, compress_type=zipfile.ZIP_DEFLATED)


def mathsecr_decoration(table, title, kind):
    if not title or table.findall(".//hp:tbl", NS) or table.findall(".//hp:pic", NS):
        return False
    values = [v.strip() for v in table.xpath(".//hp:t/text()", namespaces=NS) if v.strip()]
    cells = table.findall(".//hp:tc", NS)
    if kind == "header":
        return (table.get("rowCnt") == "2" and table.get("colCnt") == "3" and len(cells) == 5 and
                len(values) == 4 and values[0] == title and values[1].isdigit() and
                re.fullmatch(r"제\d+교시", values[2]) is not None and values[3] == "수학영역")
    label = "빠른 정답" if kind == "quick" else "해설"
    return (table.get("rowCnt") == "3" and table.get("colCnt") == "2" and len(cells) == 4 and
            len(values) == 3 and values[0] == title + "(" + label + ")" and
            re.fullmatch(r"\d{4}\.\d{2}\.\d{2}", values[2]) is not None)


def exact_decoration(table, title, kind):
    values = [v.strip() for v in table.xpath(".//hp:t/text()", namespaces=NS) if v.strip()]
    titles = {"프린트 제목"}
    if title:
        titles.add(title)
    if table.findall(".//hp:tbl", NS):
        return False
    if kind == "header":
        return (len(table.findall(".//hp:pic", NS)) == 2 and len(values) == 2 and
                values[0] in titles and values[1] == "공부하자")
    if table.findall(".//hp:pic", NS) or len(table.findall(".//hp:tc", NS)) > 4:
        return False
    labels = {"빠른 정답", "빠른정답"} if kind == "quick" else {"해설"}
    single_labels = labels | {t + "(" + label + ")" for t in titles for label in labels}
    return ((len(values) == 1 and values[0] in single_labels) or
            (len(values) == 2 and values[0] in labels and values[1] in titles) or
            mathsecr_decoration(table, title, kind))


def headings(package, title=None, warnings=None):
    """Only direct body tables qualify; never search note or nested table text."""
    found = {"header": [], "quick": [], "explanation": []}
    for _, section in package.sections:
        for index, paragraph in enumerate(section):
            if local(paragraph) != "p":
                continue
            for table in paragraph.findall("./hp:run/hp:tbl", NS):
                value = re.sub(r"\s+", "", text(table))
                heading_like = any(label in value for label in ("빠른정답", "해설", "공부하자"))
                if table.xpath(".//hp:endNote | .//hp:equation", namespaces=NS):
                    if warnings is not None and heading_like:
                        warnings.append("Ambiguous heading-like table retained without replacement")
                    continue
                kind = None
                if exact_decoration(table, title, "header"):
                    kind = "header"
                elif index == 0 and mathsecr_decoration(table, title, "header"):
                    kind = "header"
                elif exact_decoration(table, title, "quick"):
                    kind = "quick"
                elif exact_decoration(table, title, "explanation"):
                    kind = "explanation"
                if kind:
                    found[kind].append((section, index, paragraph, table))
                elif warnings is not None and heading_like:
                    warnings.append("Ambiguous heading-like table retained without replacement")
    return found


def fingerprint(package, excluded=()):
    texts, equations, notes = [], Counter(), []
    for _, section in package.sections:
        root = deepcopy(section)
        # Exclusions are actual nodes from this package, located before copying.
        pairs = list(zip(section.iter(), root.iter()))
        for original, copy in pairs:
            if any(original is node for node in excluded):
                copy.getparent().remove(copy)
        texts.append("".join(root.xpath(".//hp:t/text()", namespaces=NS)))
        equations.update(root.xpath(".//hp:equation/hp:script/text()", namespaces=NS))
        for note in root.findall(".//hp:endNote", NS):
            notes.append((text(note), tuple(note.xpath(".//hp:equation/hp:script/text()", namespaces=NS))))
    return texts, equations, notes


def macro_plan(package, found):
    reason = None
    start = end = None
    notes = [n for _, s in package.sections for n in s.findall(".//hp:endNote", NS)]
    if len(package.sections) != 1 or any(len(v) != 1 for v in found.values()):
        reason = "Macro skipped: one section and unique existing header/quick/explanation tables required"
    else:
        section = package.sections[0][1]
        start = found["header"][0][1] + 1
        end = found["quick"][0][1]
        if not (0 < start < end < found["explanation"][0][1]) or not notes:
            reason = "Macro skipped: problem boundary or endnote list is not proven"
        elif any(local(p) != "p" for p in section):
            reason = "Macro skipped: main-story paragraph mapping is ambiguous"
        elif any(p.findall(".//hp:endNote", NS) for p in list(section)[end:]):
            reason = "Macro skipped: endnotes occur outside the problem range"
    return {"status": "skipped" if reason else "pending", "reason": reason,
            "problemStartParagraph": start, "problemEndParagraph": end,
            "noteCount": len(notes), "noteLists": [], "steps": []}


def validate_conversion(original, converted):
    """HWPML 2.x and HWPX expose text/equations/notes with different tags."""
    source_text = "".join(original.xpath("//*[local-name()='CHAR']/text()"))
    source_equations = Counter(original.xpath(
        "//*[local-name()='EQUATION']/*[local-name()='SCRIPT']/text()"))
    source_notes = original.xpath("//*[local-name()='ENDNOTE']")
    target_text, target_equations, target_notes = fingerprint(converted)
    require(source_text == "".join(target_text), "HWPML conversion changed source text")
    require(source_equations == target_equations, "HWPML conversion changed equations")
    require(len(source_notes) == len(target_notes), "HWPML conversion changed endnote count")
    for source, target in zip(source_notes, target_notes):
        require("".join(source.xpath(".//*[local-name()='CHAR']/text()")) == target[0],
                "HWPML conversion changed endnote content")


@contextmanager
def fresh_hwp():
    import pythoncom
    from win32com.client import dynamic
    pythoncom.CoInitialize()
    hwp = None
    try:
        obj = pythoncom.CoCreateInstance(
            "{2291CF00-64A1-4877-A9B4-68CFE89612D6}", None,
            pythoncom.CLSCTX_LOCAL_SERVER | 0x40000, pythoncom.IID_IDispatch)
        hwp = dynamic.Dispatch(obj)
        hwp.XHwpWindows.Item(0).Visible = False
        hwp.SetMessageBoxMode(0x00010000)
        require(hwp.RegisterModule("FilePathCheckDLL", "HDHsubiPortableFilePathChecker"),
                "COM security module HDHsubiPortableFilePathChecker registration failed")
        yield hwp
    finally:
        failure = sys.exc_info()[1]
        try:
            if hwp is not None:
                try:
                    hwp.Clear(1)
                finally:
                    hwp.Quit()
        except Exception as cleanup_error:
            if failure is None:
                raise
            failure.add_note("Hancom cleanup also failed: " + str(cleanup_error))
        finally:
            pythoncom.CoUninitialize()


def character(hwp, face, size=None, number=False):
    params = hwp.HParameterSet.HCharShape
    hwp.HAction.GetDefault("CharShape", params.HSet)
    for language in ("Hangul", "Latin", "Hanja", "Japanese", "Other", "Symbol", "User"):
        setattr(params, "FaceName" + language, face)
        setattr(params, "FontType" + language, hwp.FontType("TTF"))
        if number:
            setattr(params, "Size" + language, 120)
            setattr(params, "Offset" + language, 25)
    if size is not None:
        params.Height = hwp.PointToHwpUnit(size)
    require(hwp.HAction.Execute("CharShape", params.HSet), "COM CharShape failed")


def run_macro(hwp, source, target, metadata, style=None):
    style = resolve_style(style)
    metadata["style"] = style
    require(hwp.Open(str(source), "HWPX", "versionwarning:false"), "COM Open HWPX failed")
    controls = []
    ctrl = hwp.HeadCtrl
    count = 0
    while ctrl:
        count += 1
        require(count < 10000, "COM control enumeration exceeded bound")
        if str(ctrl.CtrlID) == "en":
            controls.append(ctrl)
        ctrl = ctrl.Next
    require(len(controls) == metadata["noteCount"], "COM/XML note count mismatch")

    def action(name):
        require(hwp.HAction.Run(name), "COM action failed: " + name)
        metadata["steps"].append(name)

    start, end = metadata["problemStartParagraph"], metadata["problemEndParagraph"]
    action("MoveDocBegin")
    for paragraph in (start, end):
        require(hwp.SetPos(0, paragraph, 0), "COM problem position failed")
        require(tuple(hwp.GetPos()) == (0, paragraph, 0), "COM paragraph mapping mismatch")
    require(hwp.SelectText(start, 0, end, 0), "COM problem selection failed")
    action("StyleShortcut1")
    require(hwp.SelectText(start, 0, end, 0), "COM problem reselection failed")
    character(hwp, style["problemFont"], style["problemSize"])
    params = hwp.HParameterSet.HParaShape
    hwp.HAction.GetDefault("ParagraphShape", params.HSet)
    params.Indentation = hwp.PointToHwpUnit(style["problemIndent"])
    require(hwp.HAction.Execute("ParagraphShape", params.HSet), "COM ParagraphShape failed")
    action("MoveRight")
    params = hwp.HParameterSet.HSecDef
    hwp.HAction.GetDefault("FootnoteOption", params.HSet)
    params.FootnoteShape.LineLength = -1
    params.EndnoteShape.Suffix = 46
    params.EndnoteShape.LineLength = 28346
    params.HSet.SetItem("ApplyClass", 24)
    params.HSet.SetItem("ApplyTo", 3)
    require(hwp.HAction.Execute("FootnoteOption", params.HSet), "COM FootnoteOption failed")
    for note in controls:
        require(hwp.SetPosBySet(note.GetAnchorPos(0)), "COM note anchor failed")
        require(hwp.MovePos(14, 0, 0), "COM entering note failed")
        list_id = tuple(hwp.GetPos())[0]
        require(list_id != 0 and list_id not in metadata["noteLists"], "COM unsafe note list")
        metadata["noteLists"].append(list_id)
        action("SelectAll")
        character(hwp, style["noteFont"])
        action("MoveRight")
    action("MoveDocBegin")
    for note in controls:
        require(hwp.SetPosBySet(note.GetAnchorPos(0)), "COM reference anchor failed")
        require(tuple(hwp.GetPos())[0] == 0, "COM reference is outside main story")
        action("MoveSelRight")
        character(hwp, style["numberFont"], style["numberSize"], number=True)
        action("MoveRight")
    require(hwp.SaveAs(str(target), "HWPX", ""), "COM SaveAs HWPX failed")
    metadata["status"] = "complete"


def import_resources(dest, donor):
    ref = dest.header.find("hh:refList", NS)
    dref = donor.header.find("hh:refList", NS)
    mappings, fonts = {}, {}
    for group, attr in GROUPS.items():
        src = dref.find("hh:" + group, NS)
        if src is None:
            continue
        target = ref.find("hh:" + group, NS)
        if target is None:
            target = E.SubElement(ref, src.tag, itemCnt="0")
        next_id = max([int(n.get("id")) for n in target] + [-1]) + 1
        mappings[attr] = {n.get("id"): str(next_id + i) for i, n in enumerate(src)}
    faces = ref.find("hh:fontfaces", NS)
    if faces is None:
        faces = E.SubElement(ref, "{" + NS["hh"] + "}fontfaces")
    for face in dref.findall("hh:fontfaces/hh:fontface", NS):
        lang = face.get("lang")
        target = next((f for f in faces if f.get("lang") == lang), None)
        if target is None:
            target = E.SubElement(faces, face.tag, lang=lang, fontCnt="0")
        offset = max([int(f.get("id")) for f in target] + [-1]) + 1
        fonts[lang.lower()] = {}
        for i, font in enumerate(face):
            copy = deepcopy(font)
            copy.set("id", str(offset + i))
            fonts[lang.lower()][font.get("id")] = copy.get("id")
            target.append(copy)
        target.set("fontCnt", str(len(target)))
    faces.set("itemCnt", str(len(faces)))
    manifest = dest.content.find("opf:manifest", NS)
    used_ids = {n.get("id") for n in manifest}
    images = {}
    for item in donor.content.findall("opf:manifest/opf:item", NS):
        href = item.get("href", "")
        if not href.startswith("BinData/"):
            continue
        number = len(images)
        while True:
            ident = "hdh_donor_" + str(number)
            path = "BinData/" + ident + PurePosixPath(href).suffix
            if ident not in used_ids and path not in dest.parts:
                break
            number += 1
        images[item.get("id")] = ident
        used_ids.add(ident)
        copy = deepcopy(item)
        copy.set("id", ident)
        copy.set("href", path)
        manifest.append(copy)
        dest.parts[path] = donor.parts[href]

    def remap(node):
        for child in node.iter():
            for attr, mapping in mappings.items():
                if child.get(attr) in mapping:
                    child.set(attr, mapping[child.get(attr)])
            if child.get("nextStyleIDRef") in mappings.get("styleIDRef", {}):
                child.set("nextStyleIDRef", mappings["styleIDRef"][child.get("nextStyleIDRef")])
            if local(child) == "fontRef":
                for lang, value in list(child.attrib.items()):
                    child.set(lang, fonts[lang][value])
            if child.get("binaryItemIDRef") in images:
                child.set("binaryItemIDRef", images[child.get("binaryItemIDRef")])
            if local(child) == "heading":
                attr = {"NUMBER": "numberingIDRef", "BULLET": "bulletIDRef"}.get(child.get("type"))
                if attr and child.get("idRef") in mappings.get(attr, {}):
                    child.set("idRef", mappings[attr][child.get("idRef")])
        return node

    for group, attr in GROUPS.items():
        src = dref.find("hh:" + group, NS)
        if src is not None:
            target = ref.find("hh:" + group, NS)
            for node in src:
                copy = remap(deepcopy(node))
                copy.set("id", mappings[attr][node.get("id")])
                target.append(copy)
            target.set("itemCnt", str(len(target)))
    return remap


def empty_paragraph(node):
    allowed = {"p", "run", "t", "linesegarray", "lineseg"}
    return not text(node) and all(local(n) in allowed for n in node.iter())


def decorate(package, donor, title, warnings):
    templates = headings(donor)
    require(all(len(v) == 1 for v in templates.values()), "Template requires three unique heading tables")
    found = headings(package, title, warnings)
    remap = import_resources(package, donor)
    inserted, replaced, removed = [], [], 0
    # Object/paragraph instance IDs are independent of header resource IDs.
    next_id = max([int(n.get(a)) for _, s in package.sections for n in s.iter()
                   for a in ("id", "instid") if n.get(a, "").isdigit()] + [0]) + 1
    for kind in ("header", "quick", "explanation"):
        template_p, template_table = templates[kind][0][2:]
        table = remap(deepcopy(template_table))
        require(sum((t.text or "").count("프린트 제목") for t in table.findall(".//hp:t", NS)) == 1,
                "Template requires one title slot per heading")
        for node in table.findall(".//hp:t", NS):
            if node.text:
                node.text = node.text.replace("프린트 제목", title)
        for node in table.iter():
            for attr in ("id", "instid"):
                if node.get(attr) is not None:
                    node.set(attr, str(next_id))
                    next_id += 1
        matches = found[kind]
        # Replacing only a decorative-only table prevents losing source answers,
        # images or arbitrary prose in a table that happens to mention a heading.
        if len(matches) == 1:
            old = matches[0][3]
            old.getparent().replace(old, table)
            replaced.append(kind)
        else:
            p = E.Element(template_p.tag, attrib=dict(template_p.attrib))
            remap(p)
            p.set("id", str(next_id))
            next_id += 1
            run = E.SubElement(p, "{" + NS["hp"] + "}run", charPrIDRef=table.xpath(
                ".//hp:run/@charPrIDRef", namespaces=NS)[0])
            run.append(table)
            section = package.sections[0 if kind == "header" else -1][1]
            if len(matches) == 1:
                matches[0][2].addprevious(p)
            elif kind == "header":
                if len(section):
                    # Section properties must remain before the inserted table.
                    for secpr in section[0].findall("./hp:run/hp:secPr", NS):
                        secpr.getparent().remove(secpr)
                        run.insert(0, secpr)
                section.insert(0, p)
            else:
                p.set("pageBreak", "1")
                section.append(p)
            warnings.append(kind + " heading missing or ambiguous; added box without moving source content")
        inserted.append(table)
    for _, section in package.sections:
        for note in section.findall(".//hp:endNote", NS):
            body = note.find("hp:subList", NS)
            if body is None:
                continue
            for heading in list(body):
                if text(heading) == "[해설]":
                    previous = heading.getprevious()
                    if previous is not None and empty_paragraph(previous):
                        body.remove(previous)
                        removed += 1
                    else:
                        warnings.append("AltShift4 skipped: [해설] is not preceded by a proven empty paragraph")
        for cache in section.findall(".//hp:linesegarray", NS):
            cache.getparent().remove(cache)
    for node in package.content.xpath("//*[local-name()='title']"):
        node.text = title
    package.validate()
    return inserted, replaced, removed


def absolute(value):
    path = Path(value)
    require(path.is_absolute(), "Paths must be absolute: " + value)
    return path.resolve()


class LayoutGap(ValueError):
    """A structure/capacity gap leaves the already decorated document intact."""


def layout_require(value, message):
    if not value:
        raise LayoutGap(message)


def problem_blocks(package, title):
    found = headings(package, title)
    layout_require(len(package.sections) == 1 and all(len(v) == 1 for v in found.values()),
                   "one section and unique existing header/quick/explanation boundaries required")
    section = package.sections[0][1]
    header, quick, explanation = (found[k][0][1] for k in ("header", "quick", "explanation"))
    layout_require(header == 0 and header < quick < explanation and
                   all(local(n) == "p" for n in section), "main-story boundaries are ambiguous")
    anchors = []
    for index, paragraph in enumerate(section):
        notes = paragraph.findall(".//hp:endNote", NS)
        if not notes:
            continue
        direct = paragraph.xpath("./hp:run/hp:ctrl/hp:endNote | ./hp:run/hp:endNote", namespaces=NS)
        layout_require(len(notes) == len(direct) == 1 and header <= index < quick,
                       "each problem must have one main-story endnote anchor before quick answers")
        anchors.append(index)
    layout_require(anchors, "no proven problem anchors")
    layout_require(all(empty_paragraph(n) for n in list(section)[header + 1:anchors[0]]),
                   "unassigned content before first problem")
    return section, [list(section)[a:b] for a, b in
                     zip(anchors, anchors[1:] + [quick])], found


def allocate_columns(heights, body_height, first_top, column_count):
    """Port variant slot_guard's measured pair rule, without its A4 geometry.

    Keep source order, at most two problems per column, and divide remaining
    height into equal trailing gaps. An overflowing pair becomes full columns;
    never shrink text or truncate a problem. Five mm is rounded up to HWPUNIT.
    """
    minimum_gap = 1418
    columns, index = [], 0
    while index < len(heights):
        capacity = body_height - (first_top if len(columns) < column_count else 0)
        layout_require(0 < heights[index] <= capacity, "a problem exceeds a full column")
        count = 1
        if index + 1 < len(heights) and sum(heights[index:index + 2]) + 2 * minimum_gap <= capacity:
            count = 2
        gap = (capacity - sum(heights[index:index + count])) // count
        columns.append({"problems": list(range(index, index + count)),
                        "capacity": capacity, "gap": gap})
        index += count
    return columns


def layout_style(package, paragraph, following, gap=0):
    """Clone rather than mutate shared styles (notes/answers use them too)."""
    props = package.header.find("hh:refList/hh:paraProperties", NS)
    source = next(n for n in props if n.get("id") == paragraph.get("paraPrIDRef"))
    style = deepcopy(source)
    ident = str(max(int(n.get("id")) for n in props) + 1)
    style.set("id", ident)
    setting = style.find("hh:breakSetting", NS)
    layout_require(setting is not None, "paragraph break settings missing")
    setting.set("keepWithNext", "1" if following else "0")
    setting.set("keepLines", "1")
    setting.set("pageBreakBefore", "0")
    margins = style.findall(".//hh:margin", NS)
    layout_require(margins, "paragraph margins missing")
    for margin in margins:
        for name, value in (("prev", 0), ("next", gap)):
            node = margin.find("hc:" + name, NS)
            layout_require(node is not None, "paragraph spacing missing")
            node.set("value", str(value))
            node.set("unit", "HWPUNIT")
    props.append(style)
    props.set("itemCnt", str(len(props)))
    paragraph.set("paraPrIDRef", ident)


def clear_layout_cache(package):
    for _, section in package.sections:
        for node in section.findall(".//hp:linesegarray", NS):
            node.getparent().remove(node)


def layout_roundtrip(package, work, stem, blocks, com_factory):
    """Obtain fresh Hancom geometry, never trust input lineseg caches."""
    source, target = work / (stem + "-input.hwpx"), work / (stem + ".hwpx")
    before = fingerprint(package)
    clear_layout_cache(package)
    package.save(source)
    section = package.sections[0][1]
    spans = [(section.index(block[0]), section.index(block[-1])) for block in blocks]
    positions = []
    with com_factory() as hwp:
        require(hwp.Open(str(source), "HWPX", "versionwarning:false"), "COM layout Open failed")
        require(hwp.HAction.Run("MoveDocEnd"), "COM layout pagination failed")
        for start, end in spans:
            endpoints = []
            for index, at_end in ((start, False), (end, True)):
                require(hwp.SetPos(0, index, 0), "COM layout paragraph position failed")
                # Hancom advances past section/column controls at paragraph zero.
                # The main-story paragraph must match; its first valid character
                # need not be position zero.
                actual_pos = tuple(hwp.GetPos())
                require(actual_pos[:2] == (0, index),
                        f"COM layout paragraph mapping changed: {index} -> {actual_pos}")
                if at_end:
                    require(hwp.HAction.Run("MoveParaEnd"), "COM layout paragraph end failed")
                indicator = tuple(hwp.KeyIndicator())
                require(indicator[0], "COM layout position unavailable")
                endpoints.append(list(indicator[3:5]))
            positions.append(endpoints)
        pages = int(hwp.PageCount)
        # KeyIndicator/PageCount force pagination. Saving before these calls
        # simply preserves the cache-less input package on Hancom 2024.
        require(hwp.SaveAs(str(target), "HWPX", ""), "COM layout SaveAs failed")
    result = Package(target)
    require(fingerprint(result) == before, "COM layout changed source content")
    require(len(result.sections[0][1]) == len(section), "COM layout changed paragraph mapping")
    return result, positions, pages


def layout_geometry(paragraphs):
    lines = [line for paragraph in paragraphs for line in
             paragraph.findall("./hp:linesegarray/hp:lineseg", NS)]
    layout_require(lines and all(p.findall("./hp:linesegarray/hp:lineseg", NS)
                                 for p in paragraphs),
                   "fresh Hancom line measurements missing")
    ys = [int(n.get("vertpos")) for n in lines]
    layout_require(ys == sorted(ys), "non-monotonic natural problem layout")
    bottom = max(int(n.get("vertpos")) + int(n.get("vertsize")) for n in lines)
    return {"top": ys[0], "bottom": bottom, "height": bottom - ys[0],
            "lineSpacing": max(0, int(lines[-1].get("spacing")))}


def auto_layout(package, title, work, com_factory, replaced):
    metadata = {"status": "skipped", "rule": "measured-pairs-equal-trailing-space",
                "problemCount": 0, "columns": [], "minimumPairGap": 1418}
    try:
        layout_require(set(replaced) == {"header", "quick", "explanation"},
                       "original problem/answer boundaries were missing or ambiguous")
        candidate = deepcopy(package)
        section, blocks, found = problem_blocks(candidate, title)
        metadata["problemCount"] = len(blocks)
        secprs = section.findall("./hp:p/hp:run/hp:secPr", NS)
        colprs = section.findall("./hp:p/hp:run/hp:ctrl/hp:colPr", NS)
        layout_require(len(secprs) == len(colprs) == 1, "unique section and column geometry required")
        layout_require(not section.findall(".//hp:footNote", NS),
                       "footnote space cannot be reserved by the problem layout")
        page = secprs[0].find("hp:pagePr", NS)
        layout_require(page is not None and page.find("hp:margin", NS) is not None,
                       "page geometry missing")
        margin = page.find("hp:margin", NS)
        body_height = int(page.get("height")) - sum(int(margin.get(k, "0")) for k in
                                                   ("top", "bottom", "header", "footer"))
        colpr = colprs[0]
        layout_require(secprs[0].get("textDirection") == "HORIZONTAL" and
                       colpr.get("type") == "NEWSPAPER" and colpr.get("layout") == "LEFT" and
                       colpr.get("sameSz") == "1" and colpr.get("colCount") in ("1", "2"),
                       "only horizontal equal-width one/two-column newspaper layout is supported")
        # Preserve paper margins and the answer layout. A one-column source
        # acquires two problem columns only when there is more than one problem.
        original_colpr = deepcopy(colpr)
        column_count = 2 if len(blocks) > 1 else int(colpr.get("colCount"))
        colpr.set("colCount", str(column_count))
        width = (int(page.get("width")) - int(margin.get("left")) - int(margin.get("right")) -
                 int(margin.get("gutter", "0")) - (column_count - 1) * int(colpr.get("sameGap"))) // column_count
        layout_require(body_height > 0 and width > 0, "invalid usable page geometry")
        header_table = found["header"][0][3]
        removed = 0
        for block in blocks:
            for paragraph in list(block):
                if empty_paragraph(paragraph):
                    section.remove(paragraph)
                    block.remove(paragraph)
                    removed += 1
            for index, paragraph in enumerate(block):
                for obj in paragraph.xpath("./hp:run/*[hp:pos]", namespaces=NS):
                    if obj is header_table or (local(obj) == "line" and obj.get("textWrap") == "IN_FRONT_OF_TEXT"):
                        continue
                    pos, size = obj.find("hp:pos", NS), obj.find("hp:sz", NS)
                    layout_require(pos.get("treatAsChar") == "1", "floating problem object cannot be measured safely")
                    layout_require(size is not None and size.get("widthRelTo") == "ABSOLUTE" and
                                   int(size.get("width")) <= width, "problem object exceeds column width")
                paragraph.set("pageBreak", "0")
                paragraph.set("columnBreak", "0")
                layout_style(candidate, paragraph, index + 1 < len(block))
        for block in blocks[1:]:
            block[0].set("pageBreak", "1")
        quick = found["quick"][0][2]
        quick.set("pageBreak", "1")
        if original_colpr.get("colCount") != colpr.get("colCount"):
            run = quick.find("hp:run", NS)
            ctrl = E.Element("{" + NS["hp"] + "}ctrl")
            ctrl.append(original_colpr)
            run.insert(0, ctrl)
        measured, positions, _ = layout_roundtrip(candidate, work, "layout-measure", blocks, com_factory)
        measured_section = measured.sections[0][1]
        metrics = []
        for block, endpoints in zip(blocks, positions):
            layout_require(endpoints[0] == endpoints[1], "a problem crosses a page or column at natural size")
            paragraphs = [measured_section[section.index(n)] for n in block]
            metrics.append(layout_geometry(paragraphs))
        heights = [m["height"] for m in metrics]
        tops = [m["top"] for m in metrics]
        layout_require(all(top == 0 for top in tops[1:]),
                       "later-page top reservation is not supported")
        columns = allocate_columns(heights, body_height, tops[0], column_count)
        for block in blocks:
            block[0].set("pageBreak", "0")
        for column_index, column in enumerate(columns):
            first = column["problems"][0]
            blocks[first][0].set("columnBreak", "1" if column_index else "0")
            if len(column["problems"]) == 2:
                spacing = column["gap"] - metrics[first]["lineSpacing"]
                layout_require(spacing >= 0, "native line spacing exceeds the equal problem gap")
                layout_style(candidate, blocks[first][-1], False, spacing)
        final, actual, pages = layout_roundtrip(candidate, work, "layout-final", blocks, com_factory)
        final_section = final.sections[0][1]
        final_metrics = [layout_geometry([final_section[section.index(n)] for n in block])
                         for block in blocks]
        first_page, first_column = actual[0][0]
        layout_require(first_column == 1, "first problem does not start in the first column")
        for index, column in enumerate(columns):
            expected = [first_page + index // column_count, 1 + index % column_count]
            expected_top = body_height - column["capacity"]
            for problem in column["problems"]:
                layout_require(actual[problem] == [expected, expected],
                               "Hancom placement does not fit the allocated problem column")
                geometry = final_metrics[problem]
                layout_require(abs(geometry["top"] - expected_top) <= 2 and
                               abs(geometry["height"] - heights[problem]) <= 2,
                               "Hancom did not retain measured equal problem spacing")
                layout_require(geometry["bottom"] <= body_height,
                               "final problem exceeds column capacity")
                expected_top += heights[problem] + column["gap"]
            column["page"], column["column"] = expected
        metadata.update(status="complete", columnCount=column_count, bodyHeight=body_height,
                        firstPageTop=tops[0], problemHeights=heights, columns=columns,
                        removedBlankParagraphs=removed, pages=pages, positions=actual,
                        geometry=final_metrics, unit="HWPUNIT",
                        verifiedBy="fresh-Hancom-save-position-and-equal-gap-readback")
        return final, metadata
    except LayoutGap as error:
        metadata["reason"] = "Auto layout skipped: " + str(error)
        return package, metadata


def process(source, output, title, report_path, template=None, logo=None, com_factory=fresh_hwp,
            style=None, original_hml=None):
    style = resolve_style(style)
    source, output, report_path = map(absolute, map(str, (source, output, report_path)))
    template_value = template or os.environ.get("HDH_SUBI_HWPX_TEMPLATE") or DEFAULT_TEMPLATE
    template = absolute(str(template_value))
    paths = [source, output, report_path, template]
    logo_metadata = None
    if logo:
        logo = absolute(str(logo))
        logo_metadata = approved_logo(logo)
        paths.append(logo)
    if original_hml is not None:
        original_hml = absolute(str(original_hml))
        paths.append(original_hml)
    require(len(set(paths)) == len(paths), "Input/output/report/template paths must differ")
    require(not output.exists() and not report_path.exists(), "Output or report already exists")
    require(output.suffix.lower() == ".hwpx", "Output must be .hwpx")
    require(title.strip() and title != "프린트 제목" and not any(ord(c) < 32 for c in title),
            "A nonblank, single-line actual title is required")
    require(source.is_file() and template.is_file(), "Missing source or approved template")
    require(output.parent.is_dir() and report_path.parent.is_dir(), "Output/report parent must exist")
    report = {"status": "failed", "title": title, "warnings": [], "style": style,
              "sourceSha256": sha(source), "outputSha256": None,
              "macro": {"status": "not_started"}, "template": str(template),
              "templatePrerequisite": "Heading template and registered HDHsubiPortableFilePathChecker",
              "scriptPolicy": "Only exact inert Hancom document boilerplate; no macro import or replay",
              "logos": "Template images reused unchanged; bundled template uses neutral placeholders"}
    if logo_metadata:
        report["logo"] = logo_metadata
    try:
        if original_hml is not None:
            report["originalHmlSha256"] = sha(original_hml)
            original = xml(original_hml.read_bytes())
            require(local(original) == "HWPML", "Original HML must be HWPML")
            validate_conversion(original, Package(source))
        donor = Package(template)
        donor_headers = headings(donor)["header"]
        require(len(donor_headers) == 1, "Template requires unique split-logo header")
        image_ids = donor_headers[0][3].xpath(".//@binaryItemIDRef")
        manifest = {n.get("id"): n.get("href") for n in donor.content.findall("opf:manifest/opf:item", NS)}
        report["appliedLogoSha256"] = [
            hashlib.sha256(donor.parts[manifest[ident]]).hexdigest() for ident in image_ids]
        # Release the COM document before removing its temporary input/output files.
        with tempfile.TemporaryDirectory(prefix="hdh-hwpx-") as work, ExitStack() as sessions:
            work = Path(work)
            hwp_session = None

            @contextmanager
            def session():
                # Retain one isolated COM server through conversion, styling and
                # both measurements. Recreating HwpObject while its old proxies
                # still exist can attach to a server that is shutting down.
                nonlocal hwp_session
                if hwp_session is None:
                    hwp_session = sessions.enter_context(com_factory())
                else:
                    hwp_session.Clear(1)
                yield hwp_session

            hwpx = source
            is_zip = zipfile.is_zipfile(source)
            report["inputFormat"] = "HWPX" if is_zip else "HWPML"
            if not is_zip:
                root = xml(source.read_bytes())
                require(local(root) == "HWPML", "Input is neither HWPX nor HWPML")
                require(not root.xpath("//*[local-name()='SCRIPTCODE' or "
                                       "(local-name()='SCRIPT' and not(parent::*[local-name()='EQUATION']))]"),
                        "Embedded HWPML script is not allowed")
                hwpx = work / "converted.hwpx"
                hml_copy = work / "source-copy.hml"
                hml_copy.write_bytes(source.read_bytes())
                with session() as hwp:
                    require(hwp.Open(str(hml_copy), "HWPML2X", "versionwarning:false"),
                            "COM Open HWPML2X failed")
                    require(hwp.SaveAs(str(hwpx), "HWPX", ""), "COM conversion SaveAs HWPX failed")
                report["conversion"] = {"status": "complete", "format": "HWPML2X"}
            else:
                hwpx = work / "source-copy.hwpx"
                hwpx.write_bytes(source.read_bytes())
            package = Package(hwpx)
            if not is_zip:
                validate_conversion(root, package)
            found = headings(package, title)
            # Macro roundtrip must preserve ALL text/equations/notes, including headings.
            macro_before = fingerprint(package)
            plan = macro_plan(package, found)
            report["macro"] = plan
            if plan["status"] == "pending":
                macro_path = work / "macro.hwpx"
                with session() as hwp:
                    run_macro(hwp, hwpx, macro_path, plan, style=style)
                package = Package(macro_path)
                require(fingerprint(package) == macro_before, "COM changed source content")
            else:
                report["warnings"].append(plan["reason"])
            tables, replaced, removed = decorate(package, donor, title, report["warnings"])
            after = fingerprint(package, tables)
            # Unreplaced source headings remain in the output and therefore remain
            # part of its preservation baseline.
            original_package = Package(hwpx)
            current_found = headings(original_package, title)
            excluded = [v[0][3] for k, v in current_found.items() if len(v) == 1 and k in replaced]
            before = fingerprint(original_package, excluded)
            # Compare exact text order, equation scripts and ordered notes.
            require(before == after, "Static processing changed source text, equations or endnotes")
            package, report["layout"] = auto_layout(
                package, title, work, session, replaced)
            if report["layout"]["status"] != "complete":
                report["warnings"].append(report["layout"]["reason"])
            require(sha(source) == report["sourceSha256"], "Original input changed during processing")
            if original_hml is not None:
                require(sha(original_hml) == report["originalHmlSha256"],
                        "Original HML changed during processing")
            candidate = work / "final.hwpx"
            package.save(candidate)
            Package(candidate)
            report["outputSha256"] = sha(candidate)
            report["validation"] = {"textPreserved": True, "equationsPreserved": True,
                                    "endnotesPreserved": True, "zipXmlReferences": True,
                                    "endnoteCount": len(after[2]), "equationCount": sum(after[1].values())}
            report["macro"]["altShift4BlankParagraphsRemoved"] = removed
            report["status"] = "partial" if report["warnings"] else "complete"
            # Exclusive creation closes the duplicate-output race; no overwrite.
            with output.open("xb") as stream:
                stream.write(candidate.read_bytes())
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        with report_path.open("x", encoding="utf-8") as stream:
            json.dump(report, stream, ensure_ascii=False, indent=2)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("input", "output", "title", "report"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--template")
    parser.add_argument("--logo")
    parser.add_argument("--style-json")
    parser.add_argument("--original-hml")
    args = parser.parse_args(argv)
    try:
        style = None
        if args.style_json:
            style = json.loads(absolute(args.style_json).read_text(encoding="utf-8"))
            require(isinstance(style, dict), "Style must be a JSON object")
        report = process(args.input, args.output, args.title, args.report, args.template, args.logo,
                         style=style, original_hml=args.original_hml)
        print(json.dumps({"status": report["status"], "report": args.report}, ensure_ascii=False))
        return 0
    except Exception as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
