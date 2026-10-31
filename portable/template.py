"""Build the public donor template without private images or binary sources."""
import json
from pathlib import Path
import struct
import zipfile
import zlib


def build_template(target):
    parts = json.loads(Path(__file__).with_name("template-parts.json").read_text(encoding="utf-8"))["parts"]

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    # Opaque neutral gray; not the owner's signature or academy artwork.
    png = (b"\x89PNG\r\n\x1a\n" +
           chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)) +
           chunk(b"IDAT", zlib.compress(b"\x00\xd0\xd0\xd0")) + chunk(b"IEND", b""))
    with zipfile.ZipFile(target, "x") as archive:
        archive.writestr("mimetype", "application/hwp+zip")
        for name, data in parts.items():
            archive.writestr(name, data)
        for index in (1, 2):
            archive.writestr(f"BinData/image{index}.PNG", png)
    return Path(target)
