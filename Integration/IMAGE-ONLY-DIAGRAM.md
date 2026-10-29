# Direct image descriptions with Foundation Models

Policy: `foundation_diagram_image_only_v8`; routing: `visual_image_only_routing_v1`.

The user explicitly requested that graphs, math diagrams and geometry images go directly to Foundation Models with their class-specific NCAM/DIAGRAM Center guideline. OCR is no longer an evidence dependency for visual descriptions.

The new path is DocLayout visual crop → bounded context crop → Core ML classifier → Foundation Models original-image attachment + class guideline → Indonesian overview and bullet lines. `others` still skips generation. The classifier, original image and all raw detector outputs remain separately recorded.

Foundation receives no OCR labels, formula IDs, MathML, MathCAT speech or nearby OCR context. It reads visible labels and values from the image. The guided output schema contains an overview, a list of visible image parts (position, printed labels, printed values, visual appearance), and unreadable details. The renderer turns each part into a separate Indonesian bullet line. Values remain direct model readings of the image; the schema does not turn them into independently verified facts. A partially readable image can still produce a useful description with its uncertainty; it is not rejected solely because OCR failed. Raw generation, prompt, schema, image hash, environment and request fingerprint are preserved. This is model-generated image speech, not independently verified OCR evidence.

Actual visual regions are masked out of the page input used by Vision text OCR. Visual crop OCR and numeric OCR requests are disabled. Paddle supplemental text recognition uses the same masked page. Formula candidates inside visual regions are excluded before UniMERNet and MathCAT; they are handled by the image description. Consequently point labels such as A and G are not exported as separate failed formulas. Raw detector candidates are retained in the MFD/layout artifacts and routing report.

Context crops add a small margin to retain edge labels, clamped before neighboring prose. Both original DocLayout boxes/crops and derived input boxes/crops are recorded. The original page is never overwritten.

A full photographed text page can occasionally be labeled as one giant image. Only that ambiguous document-container case retains one routing OCR pass to recover prose, using the existing dense-document heuristic. Routing OCR is never sent to Foundation or used to transcribe a real diagram. The separate `container_routing_ocr_requests` metric makes this exception observable. All ordinary visual descriptions remain image-only.

Text and formulas outside images continue through their existing OCR → UniMERNet/MathJax/MathCAT paths, with the paragraph/list/context chunking from build 35.

## Verification

Signed build 39 succeeded, was installed and executed on iPhone 16 Pro Max. Its completion report was retrieved after device reconnection. Five pages completed in 90.2 seconds with policy v8; 30 routing checks and 19 independent artifact checks passed. The device probe imports the same five original pages used for chunking verification: fractions, algebra, triangles, graphs and SPLDV. It checks that visual crop/numeric OCR requests are zero, working OCR and independent formulas do not belong to visuals, Foundation inputs have no OCR/MathCAT payload, supported visual descriptions are present, point labels A/G are not orphan formula chunks, and all five pages complete.

An independent host artifact audit compares original crop pixels, input hashes, white masks, and the source/LaTeX/speech of formulas outside visuals against build 35. It performs no model inference on the Mac. The existing seven presentation checks cover bullet boundaries, sentence splitting, decimal values, and negative signs.

Model accuracy is evaluated separately from routing success. Direct vision can still misread a small label, omit data or infer a wrong relationship. Empty model-reported uncertainty is not proof of source fidelity. Earlier free-text prompt trials demonstrated both incorrect angle transfer between panels and overly generic descriptions; these results remain in the local verification history.

Full reports and immutable inputs are retained locally under `Integration/verification/image-only-diagram-v1/`.

### Previous completed device run (build 38)

- Attempt: `953726bb-dd9a-4198-a653-d92fa0d90435`; run: `b1cbf09b-427b-4cc9-8e8f-2515485507c9`.
- Five pages completed in 70.6 seconds, with 74 chunks. Four supported visual crops produced descriptions; the one `others` crop was skipped.
- 30/30 routing checks and 19/19 independent artifact checks passed. Zero visual OCR, zero document-container routing OCR, zero independent visual formulas. The A/G orphan formula chunks are absent.
- The 74 formulas outside visuals retain the same source text, LaTeX and speech as build 35, including both triangle-area formulas. Generated IDs and small OCR bounding-box shifts are excluded from this comparison.
- Seven host presentation checks passed.
- **Source review did not pass for useful detail.** All four build-38 descriptions are too general. The line graph omits axis meanings and its six data pairs; triangle descriptions omit printed labels and incorrectly generalize numbers/marks across panels. The pie chart omits its six labeled percentages. Empty model-reported uncertainty does not catch these failures.
- An earlier trial did read all six line-graph values correctly, but copied 60-degree labels into another triangle panel. The second triangle group really does have A–I labels and the captions right-angle, obtuse, acute in left-to-right order; an earlier provisional claim that these point labels were invented was incorrect.

Build 39 replaces the free-text response with explicit image-part fields. The saved material title is `Uji visual langsung Foundation — 5 halaman, build 39`; persistence and completion are confirmed. Attempt `1a45f786-ce61-4214-995d-0c0cd9803e8d`, run `350fc27d-a9d1-4115-9f2e-cccf05b53375`.

Source review of build 39 found correct A–I labels for both triangle groups, correct left-to-right triangle captions and right-angle marker B, and all six line-chart values and all six pie-chart percentages. Significant errors remain: tick marks described as perpendicular lines, the vertical axis mislabeled as a title, and incorrect pie-sector positions. Empty model uncertainty does not establish fidelity.

The [formula withholding audit](formula-withholding-audit.json) explains the separate remaining formula messages: 36 of 74 formula candidates are held, including 22 identifier checks. 34 of the 36 have generated raw speech but fail a downstream check; two fail MathJax parsing. No inference was repeated for this audit.

[Machine-readable evidence and trial history](image-only-diagram-results.json). Immutable per-run snapshots describe the actual bundled configuration; repository metadata was updated after building.
