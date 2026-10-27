# Crop rumus dari Unicode OCR

Eksperimen 27 Oktober 2026, branch `feat/poc-integration`. Pilot perangkat: build 21. Build terbaru: 23, dengan policy crop `ocr_unicode_math_proposal_v2` dan validator `unicode_math_whole_source_check_v3`.

## Jalur produksi

1. Apple Vision membaca halaman seperti sebelumnya. Selected text, kandidat dan box karakter asli dipertahankan.
2. `UnicodeMathSource` menemukan notasi terbatas yang mengandung `∠`, `°`, pangkat Unicode `⁰¹²³⁴⁵⁶⁷⁸⁹`, atau operator `≤ ≥ ≠ × ÷ ±`.
3. Range UTF-16 mencakup operand dan notasi utuh: `∠DFE`, `∠AOB = 45°`, `(3x + 4)°`, `616 cm²`, `cm²`, `5x² + 2x`. Kata biasa, suhu Celsius/Fahrenheit/Kelvin, simbol tanpa operand dan bentuk di luar grammar tidak dikonversi.
4. Crop sumber asli memakai union box karakter, margin horizontal `max(2px, 0.05 × tinggi)` dan vertikal `max(3px, 0.25 × tinggi)`. Proposal Unicode yang overlap region formula DocLayout mempertahankan route DocLayout. Fusion MFD yang unik mempertahankan range dan policy Unicode. Raw detector/crop tidak ditimpa.
5. Proposal Unicode baru menjalankan UniMERNet yang sama, lalu MathJax lokal dan MathCAT Indonesia. Tidak ada PaddleOCR baru atau inferensi di Mac/cloud.
6. Sebelum speech menggantikan OCR, seluruh token harus sama dengan sumber dan pangkat harus mempunyai struktur `msup`, basis serta posisi attachment yang sesuai. `x² → x2`, `5x² → (5x)²`, perubahan digit/unit/titik sudut, simbol yang hilang dan token tambahan ditahan. Pemeriksaan satuan yang sudah ada tetap berlaku. Pemisahan model `cm²` menjadi `c` + `m²` hanya mendapat allowance suffix unit dengan token/posisi yang sama, mengikuti normalizer satuan yang sudah ada; koefisien numerik tidak boleh masuk ke basis pangkat.
7. Merge memakai source observation/range dan formula ID yang sama, sehingga satu occurrence mempunyai satu pemilik. Mapping superscript ke digit hanya dipakai untuk alignment setelah pemeriksaan struktur, tanpa mengubah teks sumber.
8. Jika derajat/karakter terakhir dan koma atau titik koma tepat setelahnya mempunyai **box Vision yang identik**, range sumber mencakup tanda baca yang memang ada itu. MathML mentah tidak dihapus atau ditulis ulang. Validator tetap menolak tanda baca model yang tidak ada pada range sumber dan tanda baca sumber yang hilang pada hasil model.

Ini proposal dari **hasil OCR yang masih memiliki Unicode eksplisit**. Tidak ada aturan `L/Z → ∠`, `x2/x' → x²`, atau `cmr → cm²`. Jika Vision kehilangan simbol, jalur ini belum memulihkannya. Menambah PaddleOCR memerlukan model/decoder/kamus dan pembuktian runtime iPhone terpisah. Tidak ada klaim peningkatan recall seluruh halaman atau kompatibilitas Handbook.

Grammar terbatas pada satu observation OCR, notasi sudut 1–3 huruf besar, variabel Latin tunggal, satuan panjang yang dikenal, ekspresi sederhana dan satu tingkat kurung. Pangkat basis angka, kurung bertingkat, akar, pecahan dan semua simbol Unicode belum dicakup oleh jalur tambahan ini. Route rumus yang sudah ada tetap tersedia. Overlap minimal 15% terhadap formula DocLayout mempertahankan route lama; ini bukan bukti seluruh notasi sudah tercakup.

## Artefak

- `pages/<page>/unicode-math-proposals.json`: range/simbol sumber, keputusan covered/proposed, bbox dan ID crop.
- `formula-roi-proposals.raw.json`: semua proposal asli, termasuk `sourceNotationPolicy` baru.
- `mfd-crop-merge.json`: keputusan overlap/fusion dan ID sumber.
- `formulas/<id>/unicode-source-consistency.json`: perbandingan token dan pangkat; raw UniMERNet, LaTeX, MathML dan MathCAT tetap tersedia.
- Source/final JSON tetap memakai kontrak aplikasi yang ada. Field `sourceNotationPolicy` opsional dan tidak diperlukan untuk membaca run lama.

## Pemeriksaan yang dapat diulang

`Tools/UnicodeMathChecks.swift` menguji matcher dan validator produksi dengan fixture teks/MathML. Tidak menjalankan OCR/model dan tidak mengukur akurasi foto:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -module-cache-path /private/tmp/MetraUnicodeSwiftCache \
  Metra/Data/Extraction/Engine/Pipeline/MathMLSourceTree.swift \
  Metra/Data/Extraction/Engine/Pipeline/UnicodeMathSource.swift \
  Tools/UnicodeMathChecks.swift -o /private/tmp/metra-unicode-checks
/private/tmp/metra-unicode-checks
```

Tambahkan `--cached-device-run /path/to/recorded/run` untuk memeriksa ulang range Unicode dan validator pada OCR/box serta MathML mentah yang sudah tersimpan. Mode ini tidak menjalankan OCR/model atau merge final baru.

Debug flag `--metra-unicode-probe <UUID>` memproses satu gambar nyata melalui service produksi. Input berada di `Documents/verification/unicode-math-v1/<UUID>/input.png` dan `request.json` (`sourceSHA256`, optional `title`). Hash wajib cocok. Tidak ada expected transcription yang masuk ke request model; probe tidak menyimpan atau mengubah materi SwiftData. Setiap attempt baru memakai UUID baru.

## Hasil dan batas bukti

Ringkasan terstruktur: [unicode-math-results.json](unicode-math-results.json).

| Pemeriksaan | Hasil aktual |
|---|---|
| Build 21 pada iPhone 16 Pro Max, iOS 27.0.1 | Satu ekstraksi gambar nyata selesai, run `c181f143-5d43-4de3-a6a1-13a9fe5cb7a9`, 17.46–17.47 WIB. Status halaman tetap partial. |
| Unicode pada selected OCR | 10 simbol `°`, 0 `∠`, 0 `²`, 0 `³`. Dua notasi mengikuti region DocLayout, delapan masuk proposal Unicode. |
| Delapan crop Unicode | Seluruhnya menjalankan UniMERNet–MathJax–MathCAT; tujuh lolos validator. `(3x + 4)°` di kalimat ditahan karena crop memuat koma sumber di luar range awal. `(3x + 4)°` di diagram lolos. |
| Source dan ownership build 21 | Delapan range sesuai OCR asli, tiap occurrence mempunyai satu segmen pemilik, tidak ada formula dengan dua segmen pemilik. Normalisasi mempertahankan source segments. Ini bukan audit semantic dedup seluruh halaman. |
| Satuan yang sudah ada | Delapan crop nilai+satuan dan satu notasi embedded `314 cm²` tetap ready dengan bacaan yang sama seperti baseline tersimpan. |
| Build 22 | Berhasil build/sign/install/launch. iPhone terputus sebelum laporan diambil; pengguna memilih melanjutkan dengan hasil uji pertama. Completion dan final merge build 22 belum diamati. |
| Pemeriksaan artefak perangkat dengan validator terbaru | 8/8 OCR/MathML dari run build 21 lolos setelah range koma diperiksa melalui box identik. Raw MathML tetap sama. Ini pemeriksaan artefak tersimpan, bukan inference atau merge final baru. |
| Pemeriksaan basis pangkat | Dua fixture mereproduksi celah basis pada validator lama. Setelah diperketat, seluruh 38 fixture matcher/validator lulus, termasuk kedua kasus tersebut. |
| Build terbaru | Build 23 berhasil untuk SDK iPhone dan ditandatangani. Belum dipasang atau dijalankan di perangkat; pengguna memilih menggunakan hasil uji pertama. Lima ONNX tetap dibundel, tanpa path Qwen/MLX/safetensors. |

Hasil `∠` dan superscript pada matcher/validator masih merupakan **fixture teks/MathML**. Gambar nyata pada pilot ini belum memberikan Unicode tersebut dari Vision. Ini belum membuktikan PaddleOCR, pembacaan gambar pangkat secara umum, atau pemulihan simbol yang sudah hilang dari OCR. Relasi diagram, OCR ambigu, formula lain yang ditahan, footer, tabel dan pemahaman VoiceOver tetap di luar keberhasilan terbatas ini.

Folder bukti lokal, semuanya dipertahankan:

- `verification/unicode-math-v1/6577fb40-85fd-4af6-85db-1273c8ab6ec1/`: input asli, snapshot sebelum perubahan, build 21, report/crop/raw/final iPhone, audit dan kasus koma.
- `verification/unicode-math-v1/2202b62f-a99e-4091-a6f6-496e32495cf5/`: build 22, install/launch, status laporan belum diambil, 34 fixture dan pemeriksaan artefak tersimpan saat itu.
- `verification/unicode-math-v1/53b68e3b-2e7b-4467-9d6f-971d09b12209/`: reproduksi kegagalan dua fixture basis pangkat, perbaikan validator, 38 fixture, pemeriksaan artefak terbaru, source fingerprint dan build 23.

## Perluasan PaddleOCR build 24–25

Batas dan klaim di atas adalah riwayat eksperimen build 21–23. Atas permintaan pengguna berikutnya, build 24–25 memasang PP-OCRv5 mobile resmi sebagai pembaca pelengkap pada crop baris Vision. Kandidat Vision tetap asli; pilihan simbol Paddle mempunyai override serta provenance terpisah sebelum proposal Unicode yang sama. Tidak ada substitusi hanya berdasarkan string `L`, `x2` atau `cmr`. Lihat [PADDLEOCR.md](PADDLEOCR.md) dan `paddleocr-results.json` untuk hasil baru; raw/output Unicode lama tetap dipertahankan.
