#!/usr/bin/env python3
"""Build a compact PDF containing crops of source problems that were not found.

The input manifest is UTF-8 JSON with this shape::

    {
      "title": "Paper title",
      "source": "Original source.pdf",
      "items": [
        {"problem_number": 6, "image": "path/to/page.png",
         "crop": [left, top, right, bottom]}
      ]
    }

Relative image and output paths are resolved from ``--project-root``.  The
generated document uses one landscape A4 page per failed problem so that math
and diagrams remain legible.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path
from typing import Any

from PIL import Image
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas


PAGE_SIZE = landscape(A4)
REGULAR_FONT = Path(r"C:\Windows\Fonts\malgun.ttf")
BOLD_FONT = Path(r"C:\Windows\Fonts\malgunbd.ttf")


@dataclass(frozen=True)
class CropItem:
    problem_number: str
    image_path: Path
    crop: tuple[int, int, int, int]


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create a MathSecr failed-problem crop report PDF."
    )
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--project-root", type=Path, default=Path.cwd())
    parser.add_argument("--regular-font", type=Path, default=REGULAR_FONT)
    parser.add_argument("--bold-font", type=Path, default=BOLD_FONT)
    return parser.parse_args()


def _resolve(root: Path, value: Path) -> Path:
    return value.resolve() if value.is_absolute() else (root / value).resolve()


def _load_manifest(manifest_path: Path, root: Path) -> tuple[str, str, list[CropItem]]:
    try:
        raw: dict[str, Any] = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"Cannot read manifest {manifest_path}: {exc}") from exc

    title = str(raw.get("title", "")).strip()
    source = str(raw.get("source", "")).strip()
    raw_items = raw.get("items")
    if not title or not source:
        raise ValueError("Manifest fields 'title' and 'source' must be non-empty.")
    if not isinstance(raw_items, list) or not raw_items:
        raise ValueError("Manifest field 'items' must be a non-empty list.")

    items: list[CropItem] = []
    seen: set[str] = set()
    for index, raw_item in enumerate(raw_items, start=1):
        if not isinstance(raw_item, dict):
            raise ValueError(f"Item {index} must be an object.")
        number = str(raw_item.get("problem_number", "")).strip()
        image_value = raw_item.get("image")
        crop_value = raw_item.get("crop")
        if not number or number in seen:
            raise ValueError(f"Item {index} has a missing or duplicate problem number.")
        if not isinstance(image_value, str) or not image_value.strip():
            raise ValueError(f"Item {index} field 'image' must be a non-empty string.")
        if (
            not isinstance(crop_value, list)
            or len(crop_value) != 4
            or any(not isinstance(value, int) for value in crop_value)
        ):
            raise ValueError(f"Item {index} field 'crop' must contain four integers.")
        left, top, right, bottom = crop_value
        if left < 0 or top < 0 or right <= left or bottom <= top:
            raise ValueError(f"Item {index} has invalid crop bounds {crop_value}.")
        image_path = _resolve(root, Path(image_value))
        if not image_path.is_file():
            raise ValueError(f"Item {index} image does not exist: {image_path}")
        items.append(CropItem(number, image_path, (left, top, right, bottom)))
        seen.add(number)
    return title, source, items


def _register_fonts(regular: Path, bold: Path) -> None:
    missing = [str(path) for path in (regular, bold) if not path.is_file()]
    if missing:
        raise ValueError("Required Korean font file is missing: " + ", ".join(missing))
    pdfmetrics.registerFont(TTFont("MathSecrKorean", str(regular)))
    pdfmetrics.registerFont(TTFont("MathSecrKoreanBold", str(bold)))


def _crop_image(item: CropItem) -> Image.Image:
    with Image.open(item.image_path) as source_image:
        width, height = source_image.size
        left, top, right, bottom = item.crop
        if right > width or bottom > height:
            raise ValueError(
                f"Problem {item.problem_number} crop {item.crop} exceeds "
                f"image size {width}x{height}: {item.image_path}"
            )
        crop = source_image.convert("RGB").crop(item.crop)
    return crop


def _draw_page(
    pdf: canvas.Canvas,
    *,
    title: str,
    source: str,
    item: CropItem,
    page_index: int,
    page_count: int,
) -> None:
    page_width, page_height = PAGE_SIZE
    navy = colors.HexColor("#17324D")
    blue = colors.HexColor("#2A6FDB")
    muted = colors.HexColor("#627387")
    panel = colors.HexColor("#F4F7FA")
    border = colors.HexColor("#D8E0E8")

    pdf.setFillColor(colors.white)
    pdf.rect(0, 0, page_width, page_height, stroke=0, fill=1)
    pdf.setFillColor(blue)
    pdf.rect(0, page_height - 9, page_width, 9, stroke=0, fill=1)

    pdf.setFillColor(navy)
    pdf.setFont("MathSecrKoreanBold", 19)
    pdf.drawString(42, page_height - 48, "실패 문제 이미지 크롭 보고서")
    pdf.setFillColor(muted)
    pdf.setFont("MathSecrKorean", 10)
    pdf.drawString(42, page_height - 67, title)

    badge_width = 77
    badge_height = 35
    badge_x = page_width - 42 - badge_width
    badge_y = page_height - 70
    pdf.setFillColor(navy)
    pdf.roundRect(badge_x, badge_y, badge_width, badge_height, 8, stroke=0, fill=1)
    pdf.setFillColor(colors.white)
    pdf.setFont("MathSecrKoreanBold", 16)
    badge_text = f"{item.problem_number}번"
    pdf.drawCentredString(badge_x + badge_width / 2, badge_y + 10, badge_text)

    panel_x = 42
    panel_y = 47
    panel_width = page_width - 84
    panel_height = page_height - 137
    pdf.setFillColor(panel)
    pdf.setStrokeColor(border)
    pdf.setLineWidth(0.8)
    pdf.roundRect(panel_x, panel_y, panel_width, panel_height, 8, stroke=1, fill=1)

    crop = _crop_image(item)
    image_width, image_height = crop.size
    inset = 14
    available_width = panel_width - inset * 2
    available_height = panel_height - inset * 2
    scale = min(available_width / image_width, available_height / image_height)
    draw_width = image_width * scale
    draw_height = image_height * scale
    draw_x = panel_x + (panel_width - draw_width) / 2
    draw_y = panel_y + (panel_height - draw_height) / 2

    buffer = BytesIO()
    crop.save(buffer, format="PNG", optimize=True)
    buffer.seek(0)
    pdf.drawImage(
        ImageReader(buffer),
        draw_x,
        draw_y,
        width=draw_width,
        height=draw_height,
        preserveAspectRatio=True,
        mask="auto",
    )

    pdf.setFillColor(muted)
    pdf.setFont("MathSecrKorean", 8.5)
    pdf.drawString(42, 24, f"원본: {source}")
    pdf.drawRightString(page_width - 42, 24, f"{page_index} / {page_count}")
    pdf.showPage()


def build_report(
    manifest_path: Path,
    output_path: Path,
    root: Path,
    regular_font: Path,
    bold_font: Path,
) -> None:
    root = root.resolve()
    manifest_path = _resolve(root, manifest_path)
    output_path = _resolve(root, output_path)
    regular_font = _resolve(root, regular_font)
    bold_font = _resolve(root, bold_font)

    title, source, items = _load_manifest(manifest_path, root)
    _register_fonts(regular_font, bold_font)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    pdf = canvas.Canvas(str(output_path), pagesize=PAGE_SIZE, pageCompression=1)
    pdf.setTitle(f"{title} - 실패 문제 이미지 크롭 보고서")
    pdf.setAuthor("MathSecr Paper Builder")
    for index, item in enumerate(items, start=1):
        _draw_page(
            pdf,
            title=title,
            source=source,
            item=item,
            page_index=index,
            page_count=len(items),
        )
    pdf.save()

    if not output_path.is_file() or output_path.stat().st_size == 0:
        raise RuntimeError(f"PDF was not created: {output_path}")
    print(f"created={output_path}")
    print(f"pages={len(items)}")


def main() -> int:
    args = _parse_args()
    try:
        build_report(
            args.manifest,
            args.output,
            args.project_root,
            args.regular_font,
            args.bold_font,
        )
    except (ValueError, OSError, RuntimeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
