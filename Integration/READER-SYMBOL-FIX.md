# Ambang Paddle dan kandidat label pilihan

Build 26, 27 Oktober 2026, branch `feat/poc-integration`. Perubahan atas arahan pengguna: turunkan ambang PaddleOCR dan atasi pesan “Rumus belum dapat dibaca” pada tempat yang sebenarnya hanya label pilihan.

## Perubahan

- `paddle_unicode_symbol_selection_v3`: ambang per simbol **0.85 → 0.70**. Angka ini operating choice untuk PoC, belum hasil kalibrasi akurasi. Penjagaan karakter nonspasi, prosa, angka, konflik pangkat, panjang UTF-16 dan notasi utuh tetap aktif. Hanya Unicode yang benar-benar diprediksi Paddle yang bisa dipilih; UniMERNet/source validation tetap menentukan bacaan yang boleh digabung.
- `supplemental_mfd_crop_merge_v4`: source hint berisi label bertanda titik/kurung `А.`, `В.`, `С.`, `Е.` atau bentuk `)` mendapat veto yang sama seperti label Latin. Ini huruf Kiril homoglyph yang muncul dari Vision. OCR sumber tidak diganti; hanya kandidat MFD tambahan yang ditahan. Identifier Kiril tanpa tanda label dan ekspresi matematika tidak ikut dipetakan oleh tambahan ini.
- Tidak ada perubahan pada `ReadingPresentation`. Pesan gagal tetap tersedia untuk formula unresolved yang sesungguhnya; perbaikan mencegah kandidat palsu membuat chunk tambahan.

## Bukti sumber

Run pengguna `f23ae9fc-4bc4-459e-84d5-cfba9dbdd9c0` pada build 25 mempunyai MFD `p0001.mfd.05202` dengan crop hanya **A.**. Source hint sebenarnya `А.` (`U+0410`, `U+002E`), sehingga regex Latin pada filter lama tidak cocok. UniMERNet menghasilkan `\mathsf { A } .`, alignment tidak menemukan source range unik, lalu chunk tanpa source menampilkan placeholder.

Pada baris soal diagram yang sama, Paddle mentah membaca `∠DFE` dengan probabilitas simbol 0.744856 dan `∠DPE` 0.9820764. Ambang 0.85 menahan DFE. Skor ini bukan persentase akurasi sumber.

## Satu uji baru pada iPhone

Gambar asli dari run pengguna disalin byte-identik sebagai input baru, SHA-256 `44ae7503ee560c6582171b4c33ea006ad69a656759a2495873d2ee409b4d5f9d`. Tidak ada expected transcription yang dikirim ke model.

| Pemeriksaan | Hasil build 26 |
|---|---|
| Build/sign/install/launch | Berhasil pada iPhone 16 Pro Max (`iPhone17,2`), iOS 27.0.1 |
| Run baru | `13705219-8343-4dc7-9659-0fb94e70c8cd` |
| Paddle native | 17/17 baris selesai tanpa error, tujuh glyph Unicode dipilih; pass sekitar 1.30 detik, `session.run` total 140 ms |
| Sudut | `∠DFE` dan `∠DPE` terpilih, masing-masing menjalankan jalur UniMERNet–MathJax–MathCAT dan menjadi formula ready dengan bacaan “sudut, d f e” / “sudut, d p e” |
| Label A. | `withheld_plain_source_literal`; raw MFD dan gambar sumber tetap tersedia, tidak menjadi region aktif |
| Placeholder palsu | Chunk source-kosong unresolved turun dari satu menjadi nol; canonical chunks 44 → 43 |
| Satuan | Delapan bacaan kuadrat ready sama persis dengan run pengguna sebelumnya; `616 cm²` juga terpilih langsung oleh Paddle sebelum recognition gambar |
| Pilihan | Enam soal tetap mempunyai empat pilihan A–D |
| Provenance/merge | Kandidat serta box Vision asli identik; source segments tetap tepat sekali; tidak ada satu formula ID dengan dua pemilik segmen |
| Bundle | Enam ONNX, checkpoint Paddle tetap sama, tanpa Qwen/MLX/safetensors |
| Lingkup | Halaman tetap partial dan diagram needs_review. Tidak ada uji pemahaman VoiceOver atau klaim akurasi seluruh sumber. |

Hasil terstruktur: [reader-symbol-fix-results.json](reader-symbol-fix-results.json). Bukti lokal di `verification/paddleocr-v1/ddeabfff-c274-4244-9b5a-6bed597ead66/`: input, snapshot build 25/26, log, report perangkat, crop, raw, keputusan dan output lengkap. Audit JSON dapat diulang dengan `python3 Integration/verification/paddleocr-v1/ddeabfff-c274-4244-9b5a-6bed597ead66/audit.py` pada workspace yang mempunyai artefaknya.

Mac hanya dipakai untuk build/transfer dan membaca artefak. Tidak ada inference model di Mac, test target baru, atau materi SwiftData yang disimpan oleh probe. Uji ini satu gambar/run baru pada satu perangkat, bukan bukti repeatability atau kalibrasi threshold umum. Kesalahan alignment lain, termasuk `314 cm²` pada soal 32, belum ditangani oleh dua perubahan ini.

Untuk melihat hasil melalui UI, impor ulang gambar sebagai materi baru. Hasil extraction tersimpan tidak dihitung ulang saat aplikasi diperbarui. Semua run lama dipertahankan.
