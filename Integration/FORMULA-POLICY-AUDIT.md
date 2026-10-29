# Formula policy audit and regression — build 50

This supersedes the formula candidate/acceptance sections of the historical build45 audit. Text OCR remains Vision with a bounded Paddle Unicode supplement. Visuals retain the build48 image-only Foundation route. Automatic Foundation formula fallback stays disabled.

## Changed decisions

| Policy | Current behavior | Reason |
|---|---|---|
| Isolated Latin letters from OCR | No new formula crop; preserve the original text | Avoid title/list false positives, recognition requests for ordinary letters, and invented font speech |
| Generic OCR expression | Must contain an explicit arithmetic or relation operator | Bare `5n`, `x2` and `x'` no longer create speculative expression crops; explicit Unicode has its own route |
| Whole numeric length unit | Explicit power, flattened 2/3 or one bounded known confusion glyph | Retain useful `cm²`, `m3`, `cmг`/`mr` recovery; reject arbitrary suffixes such as `000,00 m` + `aka` |
| Detector-backed recognition | Image model, valid MathML and MathCAT own the content; OCR comparison results retained as advisory evidence | Damaged linear OCR must not invalidate a recognized fraction or exponent |
| Recognition structure | Empty fraction/power operands, merror, marker-only output and bare arithmetic operators used as power bases remain review cases | Do not release malformed or clearly ambiguous recognition |
| Source placement | Prefer whole-token matching; allow complete, owned geometric ranges for image-detected content | OCR need not reproduce every symbol. Shared boundaries, unrecognized source prose and competing source claims still withhold replacement |
| No OCR source | Only a dedicated, noncompeting DocLayout formula without any OCR overlap may speak independently | Retain real formula speech without allowing empty or ambiguous MFD crops to inject speech |
| OCR-only crops | Existing source checks remain strict | Text-generated hints do not acquire detector authority |
| Explicit `atau` split | Retain the parent detector provenance; OCR anchor disagreement is advisory for such image parts | Recognized area formulas can reach MathCAT/reader even when source OCR is damaged |
| MFD duplicate suppression | Compare raw detector boxes with raw detector boxes | Padded/unpadded comparisons had allowed two nested candidates for `c ∈` |
| Standalone bullet hint | Keep as text, skip the MFD gap crop | A bullet alone is not an independent formula |

Raw recognition, MathML, MathCAT and OCR remain unchanged in saved artifacts. Optional unit/scalar speech derivations still have separate provenance. Nothing restores missing digits or calculates answers. Recognition accepted from an image is still marked source-fidelity unassessed.

## Same-input iPhone comparison

Fresh baseline build48: attempt `2edb776a-f954-45ef-9016-d55ab13669a8`, run `bf201d7f-1834-4f2f-943c-e02a98c28648`. Final build50: attempt `1b6e1d55-0810-426b-994e-b769bcb08246`, run `346720ce-1cbc-4504-bb14-686cf74d3d41`. Both used the same five original pages on iPhone 16 Pro Max. Expected outputs were never supplied to a production model. All model inference ran on iPhone.

| Page | Before candidates / spoken | After candidates / spoken |
|---|---:|---:|
| Fractions | 16 / 8 | 8 / 6 |
| Algebra | 13 / 4 | 8 / 6 |
| Triangles | 9 / 8 | 6 / 6 |
| Graphs | 0 / 0 | 0 / 0 |
| SPLDV / materi_003 | 36 / 33 | 17 / 17 |
| Total | 74 / 53 | 39 / 35 |

These are candidate counts, not accuracy percentages. Of the 53 baseline spoken candidates, 25 were isolated letters that no longer need separate recognition, and two had visually identified recognition errors. All remaining 26 retain exact speech in the new persisted reader. Across all 35 removed letter candidates, 31 remain ordinary source text and four are covered by complete accepted formulas; no source letter is missing or held by a new candidate.

Five previously withheld expressions now have speech in the persisted reader and accessibility labels:

- `a × 1 = a`.
- The parenthesized mixed-fraction expression with whole term a, numerator b and denominator c. MathCAT still says “bold b” because of the recognized style.
- `5x² + 2x`.
- `4x³ + 2x² + 3x + 3x² + 8`.
- `2x²` (the recognized bold style still appears in speech).

For these five cases, an independent source review checked tokens and fraction/power structure, not only speech availability. Additionally, previous `x²` and `3x²` crop outputs had an invented i and leading 1 respectively; the new MFD crops recognize them as x² and 3x². The original rupiah amounts and five-equation MathCAT block are intact. Both triangle-area alternatives remain available. The four visual descriptions are generated; the decorative page-number crop still correctly skips as Others.

All 37 native policy/placement fixtures and seven live import/reader checks passed (44 total). The evidence includes an interim build49 failure to recognize legacy DocLayout regions without optional provenance. Build50 fixes this and has a regression fixture; the final comparison also exposed and fixed the raw/padded MFD duplicate issue. Interim outputs are retained as diagnostic evidence, not counted as the final result.

Primary UniMERNet calls decreased from 74 to 39; their recorded inference time decreased from 28.1 to 21.2 seconds. Full-page batch wall time was 127.9 seconds before and 119.9 seconds after. This single pair includes variable Foundation visual generation time and is not a general speed benchmark.

## Remaining limitations

Four candidates remain held: an MFD crop crossing heading/fraction content; a decimal-list crop whose recognizer corrupts digits/abbreviation; a decorative book banner detected as math; and `2x² + 3x² = 5x²` recognized with multiplication operators as the power bases. No Foundation formula requests are introduced for them. Detector/model fidelity work is still needed for those cases.

MathCAT typography words can still occur inside actual formula crops. There is no global removal of bold/vector/script semantics. The annotated five cases and unchanged baseline speech do not establish correctness of every output, and no human VoiceOver listening study was performed. Existing materials keep their saved extraction; the new test material is `Uji perbaikan aturan rumus — 5 halaman, build 50`.

Evidence: `verification/formula-policy-v1/0d1521e2-065c-4949-872d-b59f7de4e706/`, including baseline source checkpoint, before/after artifacts, native reports, persisted reader rows and `audit.json`. Reproduce the offline evidence comparison with `python3 Tools/audit-formula-policy.py <evidence-root>`; it performs no model inference.
