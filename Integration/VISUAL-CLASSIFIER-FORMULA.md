# Visual classification and compound formula recognition

The production pipeline classifies each raw DocLayout visual crop on iPhone with the user-supplied `MathVisualRepresentationClassifier.mlmodel` before description generation. The model's exact classes are `graph`, `diagrams`, `geometry`, and `others`. It accepts a 360 × 360 RGB image. Vision `scaleFit` preserves edge labels and the full crop; the training crop policy was not supplied. The source model SHA-256 is `f5a6837fc1649b99172f621b9873f15de139f83e17c6a4ef74b811756adbb062`.

Routing uses the highest-scoring class and records all four scores, the crop hash, preprocessing, and timings in `visual-classification.json`. These scores are model outputs, not measured accuracy. Description failure or a missing classifier does not trigger an unclassified generative fallback. `others` creates no Foundation Models request and exports an auxiliary `ignored_visual` chunk, preserving source coverage without placing it in reading topics. Dense full-page document containers still enter the existing OCR/text route, with both raw classification and routing provenance retained.

Supported visual classes receive separate instructions adapted from [NCAM / DIAGRAM Center mathematics guidelines](https://www.wgbh.org/ncam-resources/2026-08-21/specific-guidelines-mathematics):

- `graph`: identify the subtype, describe axes and their meaning when present, list source data points, and speak a coordinate separator as “koma”. Pie charts do not receive invented axes.
- `diagrams`: use short bullets about visible parts, expand known unit abbreviations, and avoid teaching the surrounding concept.
- `geometry`: use short, specific descriptions of points and lines, arranged left to right, without repeating the caption or inferring unmarked relationships.

Generated details reference existing label/value IDs. MathCAT remains responsible for formula/value speech. The output uses line breaks and bullets; the reader exposes each line as an accessibility element. A description with rejected facts or unresolved evidence receives a neutral review preview; its full candidate remains available in extraction artifacts. This change implements routing and description constraints; it does not establish classifier or visual description accuracy.

## Two formulas separated by “atau”

The original whole crop for the triangle-area line contained both expressions and the word “atau”. UniMERNet recognized that word as letters within a mathematical identifier. The initial attempt to split using OCR box midpoints alone cut the last `t` and retained a fragment of “atau” in the second crop. That failed build 30 result is retained, separately from the correction.

`source_connector_formula_split_v2` requires one explicit whole-word connector on a short equation line, disjoint OCR word boxes, and two math-like sides. It retains the full vertical formula extent, then snaps each horizontal cut to a complete blank inter-word pixel gap near the OCR anchor. It never reconstructs a fraction, variable, or answer from OCR. Each source crop is recognized independently by UniMERNet → MathJax → MathCAT; the connector remains ordinary source text.

The recognition result must preserve the source's non-x Latin anchors and start with the observed initial identifier, contain one equality, and exclude the connector. A missing `t` or extra leading `1` is withheld. This check establishes source attachment and catches these observed errors; it does not prove every numeric/fraction glyph. Existing exponent/unit checks remain active. No global formula-alignment policy was loosened. Raw detector crops, OCR, split decisions, and recognition artifacts are retained.

## Verification

- Signed iPhone builds 30–32 succeeded.
- The real failure fixture yields two disjoint UTF-16 source ranges `[0,7]` and `[13,22]`, preserving “atau” at `[8,12]`.
- Host checks verify source range separation, full formula height, rejection of shared/missing OCR boxes, zero-ink cut selection, rejection when no blank gap exists, and rejection of missing-identifier/extra-leading-digit recognition.
- The 14 existing reader checks still pass against the immutable four-page extraction (84 canonical chunks, 73 display rows, six numbered fraction items).
- Build 30 completed all four pages on iPhone 16 Pro Max (`iPhone17,2`, iOS 27.0.1). One logo was classified `others` and produced no generation request. The line chart was classified `graph`; the pie chart was classified `geometry`, a clear classifier error. Four supported crops invoked Foundation Models and all four remained under review. The initial compound formula crops produced incorrect speech; that run is failure evidence, not a successful formula result.

Build 30 attempt: `6d37959b-b766-471a-8616-7099675842da`; run: `bd15bca6-650b-4632-8f6f-8134312f0d21`. Local artifacts are under `Integration/verification/visual-classifier-formula-v1/` (excluded from Git).

Build 31 completed the same four pages in 128.0 seconds (attempt `7263e5a1-19a3-44d9-9d1a-3932e595e757`, run `b2efe7ab-14b7-49c5-b9b6-e51b8a5abc3a`). Both corrected crops recognized all identifiers, the fraction, and the multiplication signs, and passed source-anchor checks. MathCAT interpreted uniformly bold `a × t` as a vector cross product, so this was recognition success with a speech semantics issue.

Build 32 adds `captioned_triangle_area_scalar_font_v1`. Only a nearby explicit “Luas segitiga” caption plus a complete `L = ...` scalar structure with uniformly bold identifiers enables removal of font variants for speech. It does not alter any identifier, number, fraction or operator, and does not apply to accents/arrows or uncaptioned formulas. Raw LaTeX, MathML and MathCAT speech remain alongside the derived speech MathML. This is a bounded source-context rule, not a replacement for the general MathCAT profile.

The compound-formula host harness has 18 passing assertions, including unchanged mathematical tokens after font normalization, a required source caption, and rejection of arrow/accent structures. Build 33 additionally keeps speech withheld if the second MathCAT conversion fails; this changes the error path only.

Build 32 completed all four pages in 129.8 seconds (attempt `7a0f7d84-31f0-4cda-9466-4ab0385a0962`, run `8b906a2c-3bf3-4903-be25-5f2a295b37e8`). The final area chunk is ready and reads:

> l sama dengan, 1 perdua kali a kali t atau l sama dengan, 1 perdua kali a b kali t

Both complete image formulas passed source-anchor checks. The left formula has separate raw/normalized MathCAT artifacts; its final speech contains neither “bold” nor “cross product”. All native speech artifacts use Indonesian ClearSpeak. The export retains 84 canonical chunks: 55 ready, 28 under review, and one skipped `others` visual. Four supported descriptions remain under review and use neutral reader previews. This is not a claim that the rest of the page or all diagram descriptions are correct.

[Machine-readable audit](visual-classifier-formula-results.json). The installed build 33 includes the same successful path plus the error guard; its signed build succeeded.
