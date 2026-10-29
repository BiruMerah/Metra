# Visual classification metadata regression — build 48

The pre-build46 pipeline restoration accidentally fed raw PP-DocLayout regions into document routing after computing `classifiedRegions`. These raw regions lack the classifier label and expanded source-crop reference. Since routed regions take precedence in downstream merges, Foundation received no class and returned `skipped_classification_unavailable`. The classifier itself was successful.

The failing user import is run `ff475dd7-43ef-4b69-b6b3-7d23f62918d0`, build 47. Its D–E–F–P circle crop has a `geometry` score of 0.9998867511749268; the classifier-only attached JPEG previously scored 0.9999164938926697. Both are classifier scores, not guarantees of Foundation completion or factual description accuracy.

Build 48 carries the classified regions and exact crop through container routing, OCR candidate creation, MFD merging, visual exclusion and Foundation. Vision text OCR and the supplemental Paddle recognizer remain active. Visual OCR/numeric crop requests accidentally reintroduced during restoration are again skipped: actual visuals use image-only Foundation descriptions. The existing dense document-container routing exception remains. Formula proposal and validation rules are otherwise unchanged; Foundation formula fallback remains disabled.

Same-page device evidence: attempt `1e096f19-385c-4d46-8f2c-3e0c560e4940`, new run `7b7afd9c-2eb1-40f3-94c4-f3ece7fba859` on iPhone 16 Pro Max. The original normalized page hash and classifier crop hash match before/after. The diagram changed from `skipped_classification_unavailable` to `generated`. All 11 route/reader checks passed, including matching classifier/Foundation image hashes, image-only Foundation input, final speech, SwiftData read-back, and the reader text/accessibility labels. Full-page processing completed in 27.58 seconds. Build 48 is installed; the saved test material is `Uji perbaikan deskripsi geometri — build 48`.

The old import had 38 formula candidates and 31 final spoken formulas; the new import has 37/30. The removed candidate was the answer-choice marker A. Its reader text remains `A. 10`; all other 30 previously accepted formula occurrences retain exact speech. All nonvisual exported reading payloads are preserved.

This fixes description availability. A source review still finds descriptive errors: Foundation divides this single figure into “panels” and groups both angle expressions on the right instead of attaching them to their respective angles. The output is preserved for review; no claim of semantic correctness or human listening validation is made.

Evidence is under `verification/visual-route-metadata-v1/1e096f19-385c-4d46-8f2c-3e0c560e4940/`: before/after extraction artifacts, the on-device report and persisted reader rows, `audit.json`, and source hashes. Existing saved materials retain their original extraction until explicitly reprocessed.
