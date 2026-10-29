# Detector-only formula routing and PP-OCR text

**Historical experiment. This is not the active source configuration.** The source has been returned to the pre-build46 OCR/proposal pipeline for rule audit. The measurements below describe the installed build46 binary only.

Build 46 implemented the following routing boundary:

1. PP-DocLayout-L and Pix2Text MFD are the only sources of new formula detections. Existing overlap merging and source-connector crop splitting remain; neither creates a formula from an OCR pattern.
2. Ordinary text OCR uses PP-OCRv5 mobile detection plus recognition on iPhone. Production RunCoordinator no longer calls VisionOCRAdapter, PaddleOCRService.supplement, or OCRMathROIProposer.propose. Vision/Core ML is still used for visual classification, not text recognition.
3. Uncaptured math notation remains OCR text. `literal_text_math_speech_v1` only changes derived speech: `^2`, `^{2}` and `²` become “kuadrat”; other literal numeric exponents become “pangkat …”; explicit Unicode operators have Indonesian speech replacements. `x2`, apostrophes, missing exponents, missing digits and currency values are not reconstructed. Original source text/ranges remain unchanged. No new crop, UniMERNet request, MathCAT request or Foundation request is created for these text replacements.
4. Formula Foundation fallback remains disabled. Image-only class-specific visual descriptions remain active. Existing recognition and source-attachment checks still apply to detector-owned formulas.

## PP-OCR implementation and limits

Detector: official `PaddlePaddle/PP-OCRv5_mobile_det_onnx`, revision `e6f4fa85f00e168c862bc462aebca69eef9b3d3d`; SHA-256 `a431985659dc921974177a95adcfbb90fd9e51989a5e04d70d0b75f597b6e61d`, 4,826,518 bytes. Source inference.yml SHA-256 `98069072e1b6b37d727fd9d9f11725faa46d6ea0de012f2ed26caea011c37699`. The recognizer is the already pinned PP-OCRv5_mobile_rec model. Model inference runs on iPhone, with no host inference or cloud provider.

Native detector preprocessing uses BGR, long side 960 rounded to multiples of 32, ImageNet mean/std. Native DB postprocessing uses threshold 0.3, axis-aligned component rectangle mean ≥0.6, rectangle offset with unclip ratio 1.5, and maximum 1,000 retained lines. This is an upright textbook-line implementation, not a claim of equivalence to OpenCV rotated minAreaRect/Clipper DB postprocessing. CoreGraphics resize also differs from the reference OpenCV resize. Arbitrary rotated-text robustness and reference numerical parity have not been established.

Recognizer CTC timing is mapped to approximate horizontal text alignment for existing source-range consumers. These are not independently detected character boxes. Raw probability maps, detector decisions, line crops, recognition traces and source text are retained. Detector and recognizer errors are reported; there is no silent fallback to Apple text recognition.

PP-OCR and Vision are different pipelines. This change follows the user's engine preference; it does not establish that PP-OCR is more accurate for all Indonesian text, math notation or photo conditions.

## Verification

`Tools/TextMathSpeechChecks.swift`: 30/30 passed, including idempotence, multi-digit exponents, no inference from x2/apostrophes, and unchanged rupiah values. Build 46 compiled successfully. Fresh five-page device results will be recorded under `Integration/verification/detector-only-ppocr-v1/`.

The historical build-45 audit and source hashes are preserved as evidence of the earlier pipeline; they do not describe this new production routing.

## Fresh iPhone result

Attempt `e1f2a65c-5e65-46cf-ad1d-ed6368b58f78`, run `4e98bf92-bec0-4262-bb28-b2703bbfc345`: five pages completed in 129.4 seconds on iPhone 16 Pro Max, build 46. All 31 routing checks passed. Per-page detector candidate/accepted-MathCAT counts: 8/2, 8/5, 3/1, 0/0, 15/15 (34/23 total). These counts are not directly comparable to build45's 74/53 because OCR-generated candidates have been removed.

`Rp3.000,00 maka` survives intact in the source and speech text of the saved page5 chunk, with no unresolved formula in that paragraph. The five-equation MathCAT block survives. There are zero Vision text recognition components, zero OCR-derived formula proposals, and zero Foundation formula fallback outputs.

Content limitations remain: PP-OCR reads one tuple as `(3.000, 2.00o)`; both area-formula crops have correct UniMERNet/MathCAT raw outputs but final speech remains withheld by existing connector OCR-anchor checks because the new OCR transcription is damaged. This is a remaining downstream validation issue, not a claim that the detectors missed those formulas. No human listening or full semantic audit performed. See `verification/detector-only-ppocr-v1/e1f2a65c-5e65-46cf-ad1d-ed6368b58f78/audit.json`.
