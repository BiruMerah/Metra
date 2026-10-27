# Uji kecil konsistensi pipeline — build 19

Tanggal: **26 Oktober 2026**, pukul **23.22–23.25 WIB** untuk eksekusi perangkat. Branch `feat/poc-integration`.

## Metode

Tiga ekstraksi baru pada **iPhone 16 Pro Max / iPhone17,2**, UDID berakhir `2801C`, iOS 27.0.1 / 24A446. Ketiganya memakai aplikasi terpasang **build 19**, gambar 1127×1600 yang sama, judul yang sama, profil serial, policy `foundation_diagram_evidence_v2`, sampling greedy dan sesi Foundation baru per gambar. Setiap percobaan dimulai dari proses aplikasi baru, dengan output cache dinonaktifkan. Kode/config/model tidak diubah selama uji. Mac hanya menyiapkan input, mengendalikan transfer/launch dan membandingkan artefak; seluruh inference pada iPhone.

SHA-256 gambar: `a9a40fccc471789ffaeffe64e0eac36bcf12bbce2a8d11fc4e8fab700307edcb`.

Pembandingan konten mengabaikan UUID run/export/input, timestamp dan telemetri. Urutan chunk, isi OCR, LaTeX, speech, status, source ranges, relasi dan struktur topik tetap dibandingkan. Hash JSON dihitung setelah pengurutan key untuk pembandingan **nilai JSON**; hash prompt dihitung dari **byte string asli yang dikirim**, tanpa normalisasi. Dengan demikian perubahan urutan key pada prompt tidak disembunyikan.

## Hasil

| Tahap | Run 1 | Run 2 | Run 3 | Konsistensi |
|---|---:|---:|---:|---|
| Layout PP-DocLayout | Sama | Sama | Sama | Raw tensor dan seluruh bbox/label identik |
| Pix2Text-MFD dan merge | Sama | Sama | Sama | Raw tensor, kandidat dan keputusan merge identik |
| Vision OCR | 43 observasi | 43 observasi | 43 observasi | Semua teks, confidence, bbox dan evidence sama |
| Region rumus | 35 | 35 | 35 | Crop byte-identik; LaTeX, MathML, MathCAT, gate dan status sama |
| Satuan berpangkat yang diperiksa | 9 ready | 9 ready | 9 ready | Termasuk stem 314 cm² dan 8 opsi cm²/m² |
| Struktur chunks | 49 | 49 | 49 | ID sumber, urutan, jenis dan referensi sama |
| Index topik berdasarkan heading | 1 grup | 1 grup | 1 grup | Judul, anggota dan urutan sama |
| Foundation raw plan | Versi 1 | Versi 2 | Versi 3 | Tiga plan berbeda; dua himpunan relasi berbeda |
| Bacaan diagram setelah validasi | Versi A | Versi B | Versi B | Dua bacaan akhir berbeda |
| `final_ready` tanpa metadata berubah | Versi A | Versi B | Versi B | Perbedaan berasal dari diagram; chunks nonvisual sama |

Ketiga run selesai dan tersimpan. Status engine tetap `partial`, dengan diagram `needs_review`; ini bukan tiga halaman yang telah dibuktikan lengkap/akurat. Seluruh source segment tetap dipertahankan sekali.

Waktu request Foundation masing-masing **12,39 / 8,44 / 8,36 detik**. Ini angka deskriptif, bukan benchmark cold/warm: cache model sistem tidak dapat dikendalikan. Dua folder run selesai diambil saat run ketiga sedang inference, sehingga kondisi I/O juga bukan kontrol performa yang ketat.

### Apa yang berubah pada diagram?

- Run 1 mengulang pasangan D–P hingga batas 12 koneksi dan mengusulkan sudut D–P–D. Renderer merangkum koneksi berulang menjadi satu ruas dan validator menolak referensi sudut dengan titik berulang.
- Run 2/3 mengusulkan tiga koneksi D–P, P–E, E–F. Keduanya memasangkan 47° pada D–P–E dan `(3x+4)°` pada P–E–D; validator menolak keduanya karena vertex/nilai tidak cocok dengan keterangan sumber.
- Run 2/3 berbeda pada teks uncertainty mentah, tetapi menghasilkan bacaan akhir yang sama. Nilai 47° dan `(3x+4)°` tetap disebut tanpa penetapan vertex yang tidak lolos validasi.

Tidak ada klaim bahwa kestabilan OCR/rumus berarti benar: kegagalan crop kalimat `(3x+4)°`, notasi sudut LDFE/LDPE yang belum diroute, dan masalah footer soal 36 tetap berulang. `questions[]` tetap **5 soal / 20 pilihan canonical**; empat pilihan soal 36 tetap berada dalam chunks sumber.

## Temuan input prompt

**Isi evidence JSON, instruksi, prefix prompt, crop diagram, konfigurasi dan metadata model sama. Byte prompt berbeda pada ketiga run.** Perbedaannya adalah urutan property JSON yang dihasilkan encoder sebelum dimasukkan ke string prompt.

Contoh awal payload:

- Run 1: `{"nearbySource":[...]...}`
- Run 2: `{"points":[...]...}`

Fingerprint nilai evidence setelah canonical JSON tetap sama di tiga run:
`39ce9821cdbf242f8a3e66a6147fea33a6d450e8f56347662543f0cb24ca6aee`.

Sumber produksi saat ini memakai `JSONEncoder().encode(evidence)` untuk string prompt pada `FoundationDiagramService.swift`; encoder ini belum mengaktifkan `.sortedKeys`. Penulisan `evidence.json` ke artefak sudah memakai sorted keys, tetapi file itu berbeda dari string yang benar-benar dimasukkan ke prompt.

**Kesimpulan:** pipeline end-to-end belum sepenuhnya konsisten. Uji ini juga menemukan bahwa kondisi *prompt byte-identik* belum terpenuhi. Karena itu hasil ini **tidak membuktikan** Foundation greedy nondeterministik untuk input persis sama, dan tidak membuktikan urutan key sebagai satu-satunya penyebab perbedaan. Pengaruh schema/session/model belum diisolasi.

## Langkah berikutnya

1. Canonicalize serialisasi evidence untuk prompt, termasuk sorted keys dan urutan array sumber yang tetap.
2. Bekukan hash gambar, prompt, instruksi, schema dan konfigurasi; ulangi dengan satu build.
3. Ukur konsistensi dan akurasi relasi secara terpisah. Jawaban yang selalu salah tetap belum dapat dipakai sebagai fakta.
4. Jika output masih berubah pada input persis sama, lakukan pengujian komponen Foundation yang terisolasi sebelum menyimpulkan penyebabnya.

Perbaikan serialisasi tersebut **belum diterapkan pada pengukuran ini**, agar tiga run tetap memakai build 19 yang sama. Tidak ada training, model baru, inference cloud atau perubahan aplikasi pada sesi uji ini.

Pembagian topik yang diuji hanya index berbasis heading/fallback di ekspor `final_ready`. Halaman ini menghasilkan satu grup umum; hasil ini belum menguji kualitas pengelompokan makna dengan Foundation atau lintas halaman.

## Bukti

Ringkasan yang masuk Git: [consistency-results.json](consistency-results.json).

Data lokal (diabaikan Git): `verification/consistency-v1/4c61dda0-4cb9-46df-bd6d-a0c7c071a9d2/`.

| Percobaan | Run ID |
|---|---|
| 1 | `55d492dd-2a31-4421-a770-e959c1c31c19` |
| 2 | `99bfd715-ad38-45b4-a1aa-eaca63748263` |
| 3 | `7a6cc3dc-ebbb-461c-93b2-d49fdc9298a5` |

Folder tersebut memuat manifest input, fingerprint source build, laporan perangkat, raw lengkap tiap run, input pembandingan per tahap, `results.full.json` dan `audit.py`. Tiga materi baru tersimpan dengan judul identik **Materi — uji konsistensi**; hasil lama tetap ada.

## Tindak lanjut

Perbaikan serialisasi sudah diuji terpisah pada build 20. Lihat [CONSISTENCY-FIX.md](CONSISTENCY-FIX.md). Data build 19 di atas tetap merupakan baseline sebelum perubahan.
