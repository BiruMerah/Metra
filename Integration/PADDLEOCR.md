# PaddleOCR sebagai pembaca simbol pelengkap

Eksperimen build 24–26 pada branch `feat/poc-integration`, atas permintaan pengguna. Model yang dipilih adalah PP-OCRv5 mobile resmi. Build 26 sudah dipasang dan dijalankan di iPhone 16 Pro Max. [Hasil build 26 dan filter label pilihan](READER-SYMBOL-FIX.md); riwayat dua uji awal tercatat di [paddleocr-results.json](paddleocr-results.json).

## Model dan runtime

- Model: [PaddlePaddle/PP-OCRv5_mobile_rec_onnx](https://huggingface.co/PaddlePaddle/PP-OCRv5_mobile_rec_onnx/tree/ed152b8b495f84de93cda5709d768548a9127622), revision `ed152b8b495f84de93cda5709d768548a9127622`.
- `inference.onnx`: 16,534,782 byte, SHA-256 `da72dc72ca4dc220df0dfde68c1dedc31c58d3e76a25871122e5056227d50092`. Tidak diekspor ulang atau dikuantisasi lokal.
- ONNX Runtime 1.24.2 native, CPU, batch 1, dua intra-op thread. Seluruh recognition berjalan di iPhone.
- Kamus dari `PostProcess.character_dict` YAML resmi, dengan blank di indeks 0 dan spasi di akhir: 18,385 kelas. Kamus memuat `∠`, `°`, `²`, `³`; ini bukan bukti akurasi recognition simbol tersebut.
- Input BGR float32 `[1,3,48,W]`, output Softmax `[1,T,18385]`, CTC greedy decode. Preprocessing mengikuti [PaddleX text recognition processors](https://github.com/PaddlePaddle/PaddleX/blob/release/3.3/paddlex/inference/models/text_recognition/processors.py): lebar canvas 320–3200, normalisasi `/127.5 - 1`, padding nol setelah normalisasi. Decode sRGB dan bilinear Swift belum diukur paritas numeriknya terhadap OpenCV.

## Jalur aplikasi

1. Layout, MFD dan OCR Vision tetap menghasilkan region/baris serta geometry sumber. Ini menggunakan **text recognizer Paddle**, belum menambahkan text detector Paddle atau mengganti OCR satu halaman.
2. Baris Vision yang mempunyai petunjuk sudut, derajat, pangkat atau suffix satuan dikirim sebagai crop gambar asli. Maksimum 80 baris per halaman. OCR string dan expected transcription tidak menjadi input model.
3. Selector hanya dapat menyalin simbol Unicode yang benar-benar diprediksi Paddle, dengan probabilitas simbol minimal 0.70 sejak build 26 (build 24–25: 0.85) dan alignment seluruh karakter nonspasi. Ini operating threshold, bukan skor akurasi sumber. Build 25 menerapkan threshold per simbol: simbol yang lemah tetap memakai Vision, tanpa membuang simbol lain yang lolos. Perbedaan prosa, angka lain, jumlah karakter, atau pangkat eksplisit yang bertentangan tetap menahan seluruh perubahan baris.
4. Confusion yang diizinkan terbatas: `L/Z → ∠`, bentuk `o/O/0/º/apostrof → °`, dan suffix `2/3/r/г/apostrof/? → ²/³` yang sesuai. Simbol baru wajib berada di notasi matematika lengkap yang dikenali `UnicodeMathSource`. Tidak ada substitusi berdasarkan string Vision saja.
5. Kandidat Vision tidak diubah. Override simbol mempunyai engine dan artifact selection terpisah; panjang UTF-16 sumber tetap sama sehingga box Vision dapat dipakai. CTC timestep tidak diklaim sebagai box karakter.
6. Unicode terpilih masuk proposal crop utuh → UniMERNet → MathJax → MathCAT yang sudah ada. Pemeriksaan token, struktur dan basis pangkat tetap berlaku sebelum speech merge. Paddle session di-unload sebelum UniMERNet, dalam heavy-inference gate yang sama.
7. Kegagalan satu baris mempertahankan Vision dan direkam. Diagram tetap memakai Apple Foundation Models; tidak ada Qwen/MLX dalam target atau bundle.

## Persiapan pada clone baru

```sh
python3 Tools/prepare-paddle-ocr-assets.py --download
```

Alternatif: `--source /path/to/inference.onnx`. Script hanya menyalin/mengunduh checkpoint immutable dan memeriksa ukuran/hash; tidak menjalankan inference. Bobot diabaikan Git, config dan kamus masuk repo. Persiapan aset layout/MFD/UniMERNet tetap mengikuti README integrasi.

## Bukti yang disimpan

- `ocr.vision-working.raw.json`: hasil Vision sebelum pilihan Paddle.
- `ocr.raw.json`: working OCR setelah pilihan simbol, dengan kandidat Vision asli dan optional override/provenance.
- `paddleocr/<observation>/line.png`, `recognition.raw.json`, `selection.json` atau `error.json`: crop, hasil CTC, probabilitas dan alasan pilih/tolak.
- `paddleocr/selection.json`: ringkasan semua baris, budget, threshold dan batas geometry.
- `unicode-math-proposals.json`: engine/artifact selection sumber, range, keputusan route dan crop.
- MathML/LaTeX/MathCAT/raw/final lama tetap disimpan; run lama tidak ditulis ulang.

Debug flag `--metra-paddle-probe <UUID>` menjalankan satu input asli melalui service produksi tanpa menyimpan materi SwiftData. Input di `Documents/verification/paddleocr-v1/<UUID>/` berisi `input.png` dan `request.json` (`sourceSHA256`, optional `title`). Hash harus cocok. Setiap attempt memakai UUID baru.

`Tools/PaddleOCRChecks.swift` menguji CTC dan penjagaan alignment dengan fixture sintetis; 22/22 pemeriksaan awal serta 24/24 pemeriksaan build 25 lolos. Ini bukan uji recognition gambar. Log build gagal awal dan perbaikannya dipertahankan di folder verifikasi lokal.

## Hasil dua uji iPhone

Keduanya memakai gambar soal lingkaran nomor 31–36 yang sama, SHA-256 `a9a40fccc471789ffaeffe64e0eac36bcf12bbce2a8d11fc4e8fab700307edcb`, pada iPhone 16 Pro Max (`iPhone17,2`), iOS 27.0.1. Ini dua run dengan perubahan selector, bukan uji determinisme.

| Pemeriksaan | Hasil aktual |
|---|---|
| Runtime native | 17/17 baris berhasil pada masing-masing run. Pass Paddle build 25 sekitar 1.40 detik termasuk load, preprocessing, decoding dan penulisan artefak; waktu `session.run` total 151 ms. |
| Keluaran mentah Paddle | Pada masing-masing run: empat `∠`, enam `°`, lima `²`. Vision awal: nol `∠`, sepuluh `°`, nol `²`. Ini hitungan glyph hasil OCR, bukan skor akurasi seluruh halaman. |
| Build 24 | Nol override: threshold satu simbol lemah menahan seluruh baris, termasuk simbol kuat di baris yang sama. Raw dan hasil tetap disimpan. |
| Build 25 | Satu override aktual `LAOB → ∠AOB`, probabilitas simbol 0.909; `LCOD` di baris yang sama tetap asli karena probabilitas `∠` 0.738. Kandidat dan box Vision asli tetap identik. |
| Sudut soal diagram | Paddle mentah membaca `∠DFE` dan `∠DPE`, tetapi probabilitas simbol 0.635/0.843 berada di bawah ambang. `LDFE/LDPE` tidak dipromosikan. |
| Superscript | Lima `²` mentah semuanya di bawah ambang pada gambar ini. `616 cm2` belum menjadi `616 cm²` dari Paddle. Delapan crop nilai+satuan tetap ready melalui UniMERNet/normalizer yang sudah ada. |
| Unicode → rumus | Delapan proposal Unicode yang sudah ada lolos UniMERNet–MathJax–MathCAT, termasuk `(3x + 4)°` di kalimat dan diagram. Perbaikan koma dari eksperimen Unicode sudah aktif; keberhasilan ini tidak diatribusikan ke Paddle. |
| Angle AOB → speech | Pilihan simbol menggunakan region DocLayout yang sudah ada. Formula sudut gabungan yang overlap masih ditahan; satu override OCR bukan bukti tambahan bacaan sudut berhasil. |
| Merge | Source segments tetap tepat sekali, tidak ada satu formula ID dengan dua pemilik segmen. Lima soal mempunyai empat pilihan A–D, 49 chunk. Ini belum membuktikan dedup semantik atau kelengkapan seluruh foto. |
| Halaman/diagram | Halaman tetap partial, deskripsi diagram needs_review. Tidak ada klaim perbaikan relasi diagram, Handbook atau pemahaman VoiceOver. |
| Build/bundle | Build 25 signed/installed/launched, enam ONNX, tanpa Qwen/MLX/safetensors. Probe tidak menyimpan/mengubah materi SwiftData. |

Bukti lokal berada di `verification/paddleocr-v1/f7c762a9-c94d-4a43-b44b-192aa6edbda6/` (build 24) dan `verification/paddleocr-v1/ac6ba76e-53ea-43e5-b251-b7db699f64bf/` (build 25). Semua input, snapshot source, pinned weights/metadata, log, report iPhone, crop, raw decoder, keputusan selection dan output lengkap dipertahankan. Audit dapat diulang dengan `python3 Integration/verification/paddleocr-v1/audit.py` pada workspace yang memiliki artefak lokal tersebut.

## Batas

Selector konservatif dapat menolak simbol benar jika Paddle juga salah membaca satu huruf/angka lain, atau probabilitas glyph rendah. Baris yang tidak mempunyai petunjuk Vision tidak dikirim ke Paddle. Simbol yang hilang seluruhnya, perubahan jumlah karakter, keterbatasan box Vision, relasi diagram, dan kelengkapan seluruh halaman belum diselesaikan oleh integrasi ini. Paritas preprocessing OpenCV, pengaruh format/bahasa lain dan kalibrasi threshold belum diuji. Tidak ada klaim Handbook atau peningkatan akurasi umum dari keberhasilan build/decoder.

## Perubahan build 26

Atas permintaan pengguna, policy v3 menurunkan ambang per simbol ke 0.70. Pada satu uji gambar asli dari run pengguna, DFE/DPE kini terpilih dan menjadi bacaan MathCAT ready. Filter MFD v4 menahan label pilihan Kiril homoglyph bertanda titik/kurung sehingga chunk palsu A. hilang. Riwayat hasil build 24–25 di atas tidak ditulis ulang. Lihat [READER-SYMBOL-FIX.md](READER-SYMBOL-FIX.md) dan [reader-symbol-fix-results.json](reader-symbol-fix-results.json).
