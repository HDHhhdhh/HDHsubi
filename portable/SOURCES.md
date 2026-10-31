# Portable conversion sources

- `postprocess.py`: exported from HDHcontents
  `apps/workroom/server/modules/reconstruct/hwpx/postprocess.py`,
  file revision `f565f2c23f06cd59dba3fc38763ac393819207f3`.
  Portable changes: local template default, package-specific security-module
  name and template documentation/report labels; close COM sessions before
  deleting their temporary files (avoids Windows sharing violations).
  Macro, preservation and measured spacing logic are unchanged.
- `template-parts.json`: only the three heading paragraphs and style resources
  from the owner's reference template. Contains no problems, answers, signature
  artwork, academy artwork, document preview, author metadata or embedded macro.
  `template.py` generates two neutral gray images in place of private artwork.
  This is a resource donor consumed by the postprocessor, not an example exam
  or a standalone editable document.
- `run.py` carries the guarded first-reference numbering repair and native
  reopen verification used by the 2026-10-30 routine. It has no fixed paper
  title, personal directory, input digest, live service or delivery dependency.
- `dependencies.json` pins HDHangyul, the canonical HWPML2X/HWPX/PDF converter.
  `setup.py` obtains it from GitHub rather than maintaining a second converter.
  Its security DLL is already tracked upstream; source attribution and hash
  are in HDHangyul `scripts/SOURCES.md`. Neither Hancom nor fonts are bundled.

Do not replace the neutral images with signatures, private screenshots or
exam content in this repository. Supply an authorized template locally with
`--template` when exact branding is needed.
