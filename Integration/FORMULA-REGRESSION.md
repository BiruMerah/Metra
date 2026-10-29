# Pemulihan bacaan rumus dan pemeriksaan regresi

## Pembaruan terbaru: filter font dihapus

`literal_identifier_agreement_v4` tidak menggunakan atribut font untuk menerima atau menahan identifier tunggal. Huruf dan kapitalisasi harus tetap persis cocok dengan sumber OCR, tanpa struktur tambahan. MathML serta ucapan MathCAT asli dipertahankan; gaya tidak dihapus atau diubah menjadi huruf biasa. Pemeriksaan karakter, angka, struktur dan penggabungan tetap aktif. Fallback Foundation otomatis tetap nonaktif. Materi tersimpan tidak ditulis ulang.

Pemeriksaan host 35/35 lulus, termasuk empat MathML asli build 43: tiga huruf cocok diterima dan perubahan x menjadi X tetap ditahan. Ini bukan inference baru atau uji VoiceOver. Catatan di bawah adalah riwayat kebijakan sebelumnya.


## Pembaruan 28 Oktober 2026: filter font dipersempit

`literal_identifier_agreement_v3` menerima satu identifier Latin yang persis sama dengan proposal OCR, termasuk kapitalisasi, meskipun MathML memiliki gaya bold, script, fraktur atau double-struck. Gaya tidak dihapus: MathML dan ucapan MathCAT asli dipertahankan, sehingga makna gaya masih dapat terdengar. Perubahan karakter, kapitalisasi, subskrip, pangkat, operator tambahan dan varian tidak dikenal tetap ditahan. Aturan pemisahan “atau”, pemeriksaan angka/satuan dan penggabungan tidak diubah. Fallback Foundation otomatis tetap nonaktif.

Pemeriksaan host terbaru: 35/35 lulus, termasuk empat MathML asli dari run build 43. Kandidat p0005.formula.0004, .0012 dan .0013 kini diterima; .0025 yang mengubah x menjadi X tetap ditahan. Ini pengujian aturan terhadap artefak tersimpan, bukan inference baru atau pengujian VoiceOver. Materi lama tidak ditulis ulang. Bagian berikut mendokumentasikan baseline build 41 dengan kebijakan v2.


Perubahan ini menargetkan kasus yang pernah terbaca benar tetapi kemudian ditahan, serta penolakan berlebihan yang ditemukan pada audit build 39. Baseline adalah lima halaman asli yang sama: pecahan, aljabar, segitiga, grafik, dan SPLDV. Input dan hasil lama tetap disimpan.

## Perubahan produksi

- **Crop pemulihan huruf tunggal.** Jalur awal tetap dijalankan. Hanya kandidat huruf Latin tunggal yang gagal pemeriksaan kecocokan yang boleh mencoba satu crop dari gambar asli dengan konteks sedikit lebih luas. Pencarian komponen glyph dimulai dari kotak Vision yang diperluas agar tepi goresan tidak terpotong. Hasil retry dipilih hanya jika huruf, kapitalisasi dan struktur persis cocok. Tidak ada penghapusan subskrip atau koreksi karakter pada LaTeX. Upaya awal, retry, crop, MathML dan keputusan pemilihan diarsipkan terpisah. Kebijakan: `inline_glyph_context_recovery_v1`.
- **Font presentasi huruf.** `normal`, `italic`, `sans-serif` dan `monospace` dapat diterima bila hanya satu identifier yang persis sama. Bold, script, double-struck, perubahan kapitalisasi, struktur tambahan dan huruf berbeda tetap ditahan. MathML dan bacaan mentah tidak diubah untuk menghilangkan font. Kebijakan: `literal_identifier_agreement_v2`.
- **Titik akhir kalimat.** Tanda titik OCR yang benar-benar ada dapat menjadi bagian rentang matematika hanya ketika Vision memberikan kotak yang sama untuk glyph terakhir dan titik tersebut. Seluruh token tetap harus cocok dengan MathML. Titik yang hanya ditambahkan model, angka berbeda, atau pangkat keliru tetap ditolak. Kebijakan: `ocr_unicode_math_proposal_v3` / `unicode_math_whole_source_check_v4`.

Tidak ada jawaban acuan halaman yang masuk ke model produksi. Formula salah tetap bisa menghasilkan placeholder. Penanganan gambar langsung melalui classifier dan Foundation tetap dipertahankan.

## Pemeriksaan yang dapat diulang

`Tools/FormulaRegressionChecks.swift` memakai pemeriksa produksi serta `ReadingPresentation` yang sama dengan reader. Sebanyak 26 pemeriksaan meliputi huruf benar/salah, font, subskrip, pangkat, pecahan, tanda baca dengan bukti sumber, bacaan yang diterima dan fallback yang tetap diperlukan. Sebanyak 38 pemeriksaan Unicode yang sudah ada juga lulus. Pemeriksaan host tidak menjalankan model.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -module-cache-path .build/reader-module-cache \
  Metra/Data/Extraction/Engine/Pipeline/MathMLSourceTree.swift \
  Metra/Data/Extraction/Engine/Pipeline/UnicodeMathSource.swift \
  Metra/Data/Extraction/Engine/Pipeline/FormulaIdentifierCheck.swift \
  Metra/Domain/Models/MathChunkModel.swift \
  Metra/Presentation/ReadingPresentation.swift \
  Tools/FormulaRegressionChecks.swift -o /tmp/metra-formula-regression-checks
/tmp/metra-formula-regression-checks
```

Probe Debug `--metra-formula-regression-probe` menjalankan impor produksi lima halaman pada iPhone. Sesudah inferensi selesai, probe membandingkan 38 rumus yang diterima build 39 menggunakan hash halaman dan lokasi sumber, lalu memeriksa tujuh kasus pemulihan. Ekspektasi uji tidak dikirim ke model. Reader diperiksa dari material yang dibaca kembali melalui penyimpanan SwiftData, menggunakan teks dan label aksesibilitas produksi.

## Hasil

Build 40 pada iPhone 16 Pro Max: seluruh 38 bacaan baseline dipertahankan; tujuh kasus pemulihan lulus sampai ke reader. Rumus diterima naik dari 38 menjadi 47 dari total 74 kandidat; 27 masih memerlukan tinjauan. Waktu impor lima halaman 116,4 detik. Build akhir 41 pada perangkat yang sama juga lulus **86/86 pemeriksaan regresi** dan **30/30 pemeriksaan jalur visual**. Hasil tetap 47/74 diterima, dengan seluruh 38 bacaan baseline dipertahankan. Waktu impor lima halaman 93,7 detik. Ketujuh kasus pemulihan memiliki bacaan yang sesuai ekspektasi pada data reader yang dibaca kembali dari SwiftData. Ketiga retry terpilih untuk x/x/y memiliki MathML yang sama pada formula-result, artefak terpilih dan input bacaan; output awal tetap tersimpan.

Kesembilan hasil yang pulih: dua a sans-serif; dua 90° dengan titik kalimat; label K dan L; serta dua x dan satu y yang crop-nya semula terpotong. Perbandingan tambahan terhadap snapshot build 3 menemukan 28/28 lokasi rumus yang dahulu diterima kembali memiliki bacaan. Snapshot lama memakai iPhone berbeda dan profil MathCAT lama; ini hanya pemeriksaan penerimaan berdasarkan lokasi/sumber yang sama, bukan uji penyebab terkontrol atau kesamaan redaksi lintasprofil.

Material baru yang tersimpan: **Uji pemulihan rumus — 5 halaman, build 41**. Material lama tidak ditulis ulang. Attempt `834d0113-3baf-44cd-ae9e-fb0305ea314b`, run `f36d2543-20c5-42d8-8a0a-e5e52dc82d00`. [Laporan hasil lengkap](formula-regression-results.json). Metadata sumber diperbarui setelah build; snapshot konfigurasi bundle tetap disimpan dalam run.

Cakupan bukti adalah halaman uji ini, bukan semua buku matematika. Pemeriksaan kompatibilitas tidak mengesahkan kebenaran semua hasil baseline. Deskripsi Foundation tetap memiliki keterbatasan relasi/sumbu/posisi seperti yang didokumentasikan sebelumnya. Belum ada uji mendengarkan bersama siswa/guru atau penilaian pemahaman VoiceOver.

[Audit awal](formula-regression-audit.json), [audit penolakan build 39](formula-withholding-audit.json). Artefak percobaan tersimpan di `Integration/verification/formula-regression-v1/`.


## Uji iPhone build 45 — tanpa filter font

Attempt `96a803ca-98c6-48ae-8a33-fde6dd3e2cc5`, run `c91a8fac-6736-4a43-8d29-5ed8be74e9f5`, iPhone 16 Pro Max: lima halaman asli selesai dalam 104,6 detik. Sebanyak 104/104 pemeriksaan regresi lulus dan seluruh 47 bacaan baseline bertahan di reader tersimpan. Total diterima 53/74 kandidat; enam bacaan tambahan ditemukan pada teks dan accessibility label reader. Pada materi_003 diterima 33/36, naik dari 30/36. Tiga yang ditahan adalah rentang rupiah, bullet palsu, dan perubahan x menjadi X. Formula Foundation fallback nonaktif dengan nol permintaan. Deskripsi diagram tetap berjalan. Tidak ada uji mendengarkan manusia.

Bukti: [audit perangkat](verification/formula-font-filter-removed-v1/96a803ca-98c6-48ae-8a33-fde6dd3e2cc5/audit.json).
