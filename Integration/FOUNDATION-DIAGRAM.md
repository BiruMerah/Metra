# Diagram Foundation Models dan normalisasi derajat — build 17–19

Tanggal: 26 Oktober 2026. Branch `feat/poc-integration`. Build terakhir **19**, sudah build/sign/install dan diuji pada **iPhone 16 Pro Max (iPhone17,2), iOS 27.0.1 / 24A446**, UDID berakhir `2801C`. Semua inference berjalan pada iPhone. Mac hanya build, transfer dan audit artefak.

## Yang berubah

- Qwen, bobot safetensors, tokenizer, resource prompt lama, loader dan dependency MLX dikeluarkan dari target app. Checkpoint dan kode lama dipertahankan lokal di `legacy-qwen-build16/`, di luar target dan di luar Git untuk bobot besar. PoC sumber dan seluruh hasil eksperimen lama tetap ada.
- Bundle Debug build 19: **986.756.647 byte**, sebelumnya build 16 **2.869.097.519 byte**. Tidak ada path Qwen/MLX/safetensors pada bundle baru. Lima ONNX tetap **931.927.661 byte**. Instalasi masih membawa ONNX tersebut, sehingga tetap besar.
- Diagram memakai `SystemLanguageModel.default` dengan attachment crop asli, hasil `@Generable`, sampling greedy, maksimal 1.536 response token, deadline pembatalan 60 detik, sesi baru per diagram. Tidak ada provider cloud/PCC fallback. Model sistem dikelola iOS; tidak ada checkpoint hash, waktu load terpisah atau API unload yang diklaim.
- Schema v2 membatasi jenis visual dan referensi nilai `v001`–`v024`; setiap ID harus benar-benar ada pada evidence. Titik dan nilai sumber, asal dari gambar/konteks, respons mentah, transcript, penolakan, metadata OS dan metrik disimpan.
- Keterangan Vision di sekitar gambar membantu mengonfirmasi notasi sudut. Sisi/ruas yang dinarasikan memerlukan pasangan titik yang didukung notasi sudut sumber. Relasi sudut memerlukan tiga nama titik, vertex di tengah, dan nilai sumber yang cocok pada keterangan aslinya. Tidak ada asumsi titik pusat, penyelesaian soal atau koreksi angka oleh model.
- Nilai dan persamaan sudut dibacakan **MathCAT Indonesia**, bukan teks angka bebas dari Foundation. Overview visual tetap kandidat model. Relasi yang tidak lolos ditahan dan bacaan menyebut ketidakpastian.
- Impor checkpoint Qwen dihapus dari UI. Material baru mengikuti heading sumber untuk topik, dengan judul materi sebagai fallback. Index Qwen pada material lama tetap dapat dibaca tanpa inference ulang saat dibuka.

## Rumus: deteksi bukan satu-satunya penyebab

Pada soal **32**, DocLayout sudah mendeteksi `AOB = 314 cm²`; UniMERNet juga mengenali pangkat dua. Pencocokan gagal karena OCR Vision menulis `cm'` dan character box Vision memakai tinggi satu kata/baris. Normalisasi sekarang mencari subtree nilai+satuan yang lengkap, memeriksa angka/separator, semua huruf satuan, pangkat dari gambar, overlap posisi dan keunikan seluruh ekspresi. Anchor suffix tersimpan dengan observation ID dan rentang UTF-16. Raw OCR, LaTeX, MathML dan MathCAT tetap disimpan terpisah.

- Angka yang OCR-nya sudah mengandung simbol `°` mendapat jalur literal MathML → MathCAT. Tidak ada penambahan derajat ke angka tanpa simbol.
- `(3x + 4)°` mendapat crop lengkap dengan kurung dan derajat. Semua token hasil gambar harus cocok dengan sumber. Tambahan `1` atau koma tidak dibuang agar hasil tampak benar; spoken ditahan.
- Suffix OCR pendek yang rusak pada satuan hanya mengusulkan crop. Nilai, satuan dan pangkat tetap harus dikenali dari gambar dan lolos pemeriksaan lengkap.
- Soal **34** memakai **m²**, bukan derajat. Ekspresi `(3x + 4)°` ada pada soal **36**.

## Uji perangkat dan hasil

Gambar lampiran 1127×1600, SHA-256 `a9a40fccc471789ffaeffe64e0eac36bcf12bbce2a8d11fc4e8fab700307edcb`. Ini gambar yang sama dengan pilot build 14/16, tetapi OCR perangkat baru berbeda pada beberapa baris. Tiga ekstraksi baru dijalankan dengan output terpisah; tidak ada inference Mac.

| Build | Hasil |
|---|---|
| 17 | Teks/rumus selesai. Foundation melaporkan `modelNotReady`, walaupun kapabilitas vision tersedia. Kegagalan dan evidence disimpan; jalur independen tetap lanjut. |
| 18 | Model Apple sudah tersedia. Respons Indonesia dalam 11,96 detik. Model menebak ruas D–E yang tidak tampak pada sumber dan mengisi valueID dengan teks nilai. Hasil awal dipertahankan sebagai bukti kegagalan; schema dan validasi diperketat. |
| 19 | Respons Indonesia **9,53 detik**, 2.671 input token dan 145 output token. ID/schema benar. Model masih memasangkan 47° ke D–P–E; validator **menolak** relasi itu. D–P–E = `(3x + 4)°` diterima berdasarkan gambar + keterangan sumber dan dibacakan MathCAT. 47° disebut sebagai nilai tanpa memasangkannya ke vertex. Diagram tetap `needs_review`. |

Pada build 19:

- Soal 32: `314 senti-meter kuadrat`; empat pilihan **A. 30 derajat, B. 40 derajat, C. 50 derajat, D. 60 derajat**.
- Soal 34: **616, 770, 1386, 1540 meter kuadrat**, sesuai urutan A–B–C–D.
- **9/9** rentang satuan yang diperiksa ready: 314 cm² pada stem + delapan pilihan cm²/m².
- `(3x + 4)°` **di crop diagram** terbaca lengkap. Crop ekspresi yang sama **di kalimat** masih menghasilkan `1 (3x+4)° ,`; hasil itu ditahan dan raw tetap tersedia.
- Semua rentang UTF-16 final valid; setiap formula final memiliki satu pemilik segmen; normalizer mempertahankan semua segmen sekali. Raw OCR dan raw LaTeX **35 region bersama** sama antara build 18 dan 19.
- 14 pemeriksaan artefak lolos. Ini bukan skor akurasi seluruh halaman atau test suite umum. VoiceOver audio, kamera langsung, batch baru dan buka ulang setelah restart belum diuji pada sesi ini.

### Batas yang masih ada

Diagram **belum akurat penuh**. Relasi 47° masih salah pada respons model dan ditahan; satu sisi D–F tidak disebut pada hasil akhir. Validasi memakai keterangan sumber, sehingga ini bukan bukti bahwa model memahami gambar tanpa konteks. Bentuk/overview masih kandidat model. Diagram lain, terutama yang tidak mempunyai notasi relasi eksplisit pada keterangan, belum dibuktikan.

Pada OCR iPhone ini footer buku menjadi satu baris `unclassified_vision_line`. Guard normalizer mempertahankan soal 36 beserta empat pilihannya dalam struktur asal, sehingga canonical `questions[]` hanya berisi **5 soal / 20 pilihan**; pilihan soal 36 tetap ada dan berurutan di chunks. Hasil 6 soal/24 pilihan build 16 pada perangkat lama tetap bukti historis yang berbeda. Tidak ada klaim normalisasi seluruh halaman sudah selesai.

`supportsLocale(id_ID)` tetap false, tetapi permintaan Indonesia pada uji ini berhasil. Tidak ada jaminan semua permintaan, semua OS atau semua diagram akan berhasil.

## Artefak

Ringkasan yang masuk Git: `foundation-diagram-results.json`. Data lokal (diabaikan Git):

- Build 17: `verification/foundation-diagram-v1/6dea8590-2729-496f-ac23-99c6746c466e/`, run `ece37704-fa62-4e44-aedb-20f8a242989c`.
- Build 18: `verification/foundation-diagram-v1/4777f3d8-c327-441c-afa6-09fbe976ff68/`, run `8dea568a-bcd5-4e22-851f-06afbc600391`.
- Build 19: `verification/foundation-diagram-v1/0a55231b-43f2-4d1b-8c37-9de2f3a9ef82/`, run `08dde9ed-7b8e-4c36-8c20-627ed8c2abf1`. Memuat input immutable, build log, fingerprint/snapshot source, inspeksi bundle, laporan simpan SwiftData, `audit.json`, dan run lengkap.

Materi terbaru di iPhone: **Materi — diagram Apple v2**. Eksperimen gagal/parsial sebelumnya tetap tersimpan.
