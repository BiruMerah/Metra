# PP-DocLayout-L pada halaman soal lingkaran

Satu inference baru selesai pada **iPhone 17 (`iPhone18,3`), iOS 27.0.1, Metra Debug build 11**. Gambar lampiran berukuran 1127 × 1600; SHA-256 sumber `a9a40fccc471789ffaeffe64e0eac36bcf12bbce2a8d11fc4e8fab700307edcb` diperiksa di iPhone sebelum diproses. Mac hanya membangun, mentransfer, dan membaca hasil. Data/materi lama tidak diganti.

Model dan parameter produksi tetap: PP-DocLayout-L FP32, ONNX Runtime 1.24.2 CPU, 2 thread, resize 640 × 640, score threshold 0.5, NMS kelas sama 0.6/berbeda 0.98. Bobot/hash diverifikasi adapter produksi. Debug probe opt-in menjalankan adapter yang sama sekali, tanpa OCR, proposal formula tambahan, UniMERNet, MathCAT, atau Qwen. Build 11 menambahkan probe; perubahan tidak dipush otomatis.

## Hasil

300 baris output mentah menjadi **39 region** setelah filter/postprocessing: **31 text, 5 formula, 1 image, 1 number, 1 footer**.

| Bagian sumber, diperiksa visual | Label hasil |
| --- | --- |
| Soal 31: ∠AOB = 45° | formula, score 0.579 |
| Soal 31: ∠COD = 120° | formula, score 0.542 |
| Soal 31: kotak gabungan kedua sudut | formula, score 0.544; parent kedua formula di atas |
| Soal 31: AB = 18 cm | formula, score 0.601 |
| Soal 32: AOB = 314 cm² | formula, score 0.711 |
| Soal 33: keempat pilihan jawaban cm² | text, score 0.521–0.603 |
| Soal 34: keempat pilihan jawaban m² | text, score 0.529–0.594 |
| Soal 36: diagram lingkaran | image, score 0.893 |
| Soal 36: paragraf ∠DFE, ∠DPE, dan (3x + 4)° | text, score 0.848 |

Lima kotak formula termasuk satu deteksi gabungan; angka ini bukan lima ekspresi unik. Pada delapan pilihan satuan, raw output juga mempunyai kandidat formula yang bertumpang tindih (IoU minimal 0.3 terhadap region text), tetapi skor tertingginya hanya sekitar 0.096–0.351. Semua berada di bawah threshold 0.5. Analisis kandidat ini tidak menjalankan ulang model atau mengubah threshold, dan overlap bbox tidak membuktikan pengenalan benar.

Pada sampel ini, satuan berpangkat dalam pilihan jawaban tidak mendapat route formula dari output DocLayout yang diterima. Kemunculan cm² pada soal 32 justru terdeteksi sebagai bagian formula. Uji ini tidak menilai hasil crop satuan build 10 maupun kemampuan membaca hubungan geometri.

## Waktu perangkat

Model cold pada satu panggilan ini: load/hash **363.4 ms**, preprocessing **162.0 ms**, inference **350.4 ms**, postprocessing **1.7 ms**, penulisan artefak **54.9 ms**. Total komponen **932.5 ms**, tidak mencakup build, transfer, startup app, atau normalisasi input sebelumnya. Satu percobaan ini bukan benchmark repeatability atau audit akurasi seluruh halaman. Confidence adalah skor model, bukan persentase akurasi terukur.

## Artefak

- [Hasil terstruktur](doclayout-circle-page-results.json), termasuk 8 pilihan satuan dan kandidat raw masing-masing.
- [Overlay perangkat](verification/layout-only-v1/e6cf9bb5-b0c3-4ce7-960d-d7a35bfaca4c/device/pages/p0001/layout-overlay.png): merah formula, biru kelas lain.
- [Output lengkap DocLayout](verification/layout-only-v1/e6cf9bb5-b0c3-4ce7-960d-d7a35bfaca4c/device/pages/p0001/layout.raw.json).
- [Laporan perangkat](verification/layout-only-v1/e6cf9bb5-b0c3-4ce7-960d-d7a35bfaca4c/device/report.json), crop setiap region, input/normalisasi, sampel memori, log build/transfer, dan fingerprint source disimpan di folder attempt yang sama. Folder `verification/` diabaikan Git.

Untuk mengulangi probe secara eksplisit, transfer `input.png` dan `request.json` berisi `sourceSHA256` ke `Documents/verification/layout-only-v1/<UUID>/`, lalu launch Debug dengan `--metra-layout-only <UUID>`. UUID baru diperlukan untuk attempt baru; probe tidak aktif pada pembukaan biasa/Release dan tidak menyimpan materi SwiftData.
