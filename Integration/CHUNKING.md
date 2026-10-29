# Chunking: source paragraphs, lists and formula context

Policy: `paragraph_list_context_v6`.

The former exporter emitted one chunk per sentence. A sentence tokenizer could isolate an enumerator such as `1.`, and adjacent layout blocks left labels such as “Contoh:” or “Luas segitiga (L)” detached from their expression. A reader-only repair joined a subset of number fragments, while the canonical chunks still contained them.

The updated exporter uses bounded source paragraphs. Indonesian sentence tokenization supplies candidate boundaries, but short sentences in one source paragraph stay together. Explicit list starts on separate OCR source lines force separate units. Numeric/letter enumerators remain attached to the first sentence; decimal notation is not interpreted as a list marker. Formulas remain atomic. Long prose is divided at complete sentence or safe clause boundaries, with a preferred budget of 70 spoken words. An indivisible formula, long sentence without a safe boundary, or protected parenthesized span may exceed the budget.

A second pass joins spatially adjacent source blocks only when there is an explicit dependency:

- “Contoh:” joins the following example; short source lines of the form “x: disebut …” can remain with that example.
- A short formula introduction, including “Keliling segitiga (K):” or “Luas segitiga (L)”, joins its following formula.
- An incomplete comma-ended clause can join an explicit continuation such as “jadi” or “sehingga”.

This pass preserves page, column, source heading, confirmed question and answer-choice boundaries. It does not merge arbitrary adjacent paragraphs or infer a missing heading. Two consecutive source headings can form one title path, such as “B. PECAHAN — a. Jenis-jenis Bilangan Pecahan”, avoiding a separate navigation topic containing only the parent heading.

Every grouped chunk records its source blocks, absorbed chunk IDs and exact source slices. The production validator requires every text range and non-aliased formula occurrence exactly once. Validated formula speech and unresolved IDs survive grouping. Incomplete formulas remain under review; damaged formula OCR is kept as source evidence and receives a neutral reading preview. Single source variable letters retain their review preview.

The reader aligns a canonical list item's number and body in one accessibility element. Existing saved material keeps the prior conservative reader-only list repair. New imports use the new canonical chunk structure. Existing source runs and extraction artifacts are not rewritten by the verification replay.

## Verification scope

The user clarified that “student” meant several student materials/pages, not recruiting or testing people. No human student usability study was conducted.

Verification uses the exact production tokenizer and exporters on iPhone 16 Pro Max, with three cached extraction fixtures followed by a fresh five-page image import: fractions, algebra, triangles, graphs and a worked example of two-variable linear equations. Cached snapshots additionally cover multiple-choice questions and powered units. Cached replay validates chunk structure; only the fresh import executes image/OCR/formula/diagram models again.

Fifteen device boundary checks cover attached enumerators, short/long paragraphs, separate source list lines, decimal notation, formula context, unresolved speech, column/question/choice/heading boundaries, heading paths and reader marker alignment. The 14 existing legacy reader checks still pass on host Swift without model inference.

The first audit attempt stopped because its formula-speech comparison also expected suppressed diagram values to be spoken. The corrected audit requires visual chunks to match their existing FinalDiagram payload, while text/formula chunks retain their complete validated formula speech. The production chunking algorithm was unchanged by that audit correction.

Final device results are recorded after the completed run in `chunking-results.json`. Full immutable inputs, exports, per-chunk slices, reports and source hashes are stored locally under `Integration/verification/chunking-v6/` (excluded from Git).

## Completed result — build 35

Device: iPhone 16 Pro Max (`iPhone17,2`), iOS 27.0.1. Attempt: `9445bc35-bc8e-429b-8105-8fc92a668bc0`. Fresh run: `036b565f-af1a-402f-886e-3a8d0278b96a`.

| Cached extraction | Chunks before → after | Detached markers before → after | Additional checks |
| --- | --- | --- | --- |
| Four textbook pages | 84 → 62 | 11 → 0 | Five standalone example labels → zero; six context groups |
| Multiple-choice questions and units | 44 → 35 | 6 → 0 | Six questions and all 24 choices preserved |
| Formula/unit regression page | 51 → 33 | 14 → 0 | All 25 formula occurrences retained |

All three cached exports passed exact source-slice coverage, unchanged input hashes, unchanged unresolved-formula ID sets, formula speech preservation and reader/topic membership checks. Fewer chunks is an observation, not a standalone quality score: the intended improvements are attached markers and explicit context, with question and choice boundaries retained.

The fresh five-page import completed in 155.7 seconds and exported 76 canonical chunks (69 body chunks), with 92 formula occurrences represented exactly once. It has zero detached explicit markers and zero standalone example labels. Eight chunks retain their example/formula context. No nonformula prose chunk exceeds 90 source/spoken words in this sample. The first four pages' canonical IDs, kinds, source text, speech/previews and unresolved IDs match the corresponding cached replay exactly.

All 15 device boundary checks and 14 legacy reader checks passed. Signed build 35 is installed. The saved material is titled **Uji chunking — 5 halaman, build 35**. [Machine-readable results](chunking-results.json).

A worked SPLDV introduction and its complete five-line derivation form one 51-word chunk. Long explanatory paragraphs split into bounded chunks, while the nearby numbered conditions remain separate. Some circled source numbers are still misrecognized by OCR (including a source number read as `1`); chunking retains that source uncertainty instead of guessing a replacement. Diagram descriptions and other unresolved math retain their review state. Acoustic VoiceOver usability and general recognition accuracy were not established by these structural tests.
