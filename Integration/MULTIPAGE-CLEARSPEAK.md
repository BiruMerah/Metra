# Uji beberapa halaman SMP pada iPhone 16 Pro Max

Pada 28 Oktober 2026, build 28 menjalankan pipeline produksi dengan ClearSpeak di **iPhone 16 Pro Max (`iPhone17,2`), iOS 27.0.1**. Batch awal lima halaman berhenti saat memproses halaman akar. Batch diagnostik empat halaman lainnya selesai dalam **65,7 detik**, menghasilkan **84 chunk: 54 ready dan 30 needs_review**. Hasilnya masih partial; status ready tidak membuktikan matematika sumber sudah benar.

## Sumber dan metode

Sumber adalah PNG halaman utuh 1832×2600, 300 dpi, dari `_Temp Data/materi_matematika_smp_pages/`. Halaman PDF 12, 60, 116, 203 dan 346 dipilih dari pilot yang sudah ada untuk variasi notasi. Nomor cetak masing-masing 5, 53, 109, 196 dan 339. Ini render buku, bukan foto kamera atau sampel acak.

Probe Debug `--metra-multipage-probe` memanggil `OnDeviceExtractionService.extract(pages:)` yang sama dengan impor galeri, sekali untuk satu batch. Input diverifikasi SHA-256 pada Mac dan iPhone. Profil tetap `serial_baseline`, satu halaman dan satu heavy inference aktif; ONNX/model, aturan pengenalan/merge, serta deskripsi diagram tidak diubah. Mac dipakai untuk build, transfer dan audit JSON; seluruh inference berjalan pada iPhone.

Baseline source adalah commit `f3aab84`. Perubahan kode eksperimen hanya menambahkan probe Debug, launch flag dan nomor build 28. Build/sign/install berhasil. Launch awal ditolak LaunchServices setelah instalasi; retry berhasil dan memulai satu run lima halaman.

## Batch lima halaman yang berhenti

Run `20abe8a3-2489-401f-8f83-6a4d166d552a` memakai urutan PDF 12 → 60 → 116 → 203 → 346.

- Hasil halaman pertama tersimpan: 16 kandidat region rumus, 14 spoken mentah; dua kegagalan MathJax dan beberapa konflik merge tetap tercatat.
- Di PDF 60, DocLayout menggabungkan bagian besar materi akar menjadi crop rumus 981×2103 piksel. Artefak `model-input.png` tersedia untuk crop pertama, tetapi `unimernet.raw.json` belum terbentuk ketika proses berhenti.
- Progres terakhir pada 12:04:19 WIB. Sampel memori terakhir pada 12:04:25 WIB mencapai **3.155 GiB**, dibulatkan **3,16 GiB**. PID aplikasi kemudian tidak ada dalam daftar proses.
- Penyebab penghentian OS belum dikonfirmasi; tidak ditemukan log crash/Jetsam yang bertepatan. Kenaikan footprint mengarah ke dugaan tekanan memori. Status `running` pada report mentah adalah catatan yang belum sempat ditutup, bukan bukti proses masih aktif.
- Batch ini tidak menghasilkan `final_ready.json`. Bukti kegagalan tetap disimpan; halaman akar tidak dijalankan ulang atau diperbaiki diam-diam.

## Batch empat halaman yang selesai

Run `d62d043c-9e3a-42d7-840a-1876ddc9cebc` memakai PDF 12 → 116 → 203 → 346 dengan build dan pipeline yang sama. Batch ini secara sengaja mengecualikan halaman akar yang gagal, sehingga tidak menjadi bukti keberhasilan lima halaman.

| Halaman PDF / cetak | Materi | Kandidat rumus | Spoken mentah | Chunk ready | Chunk review |
|---|---|---:|---:|---:|---:|
| 12 / 5 | Pecahan dan aturan operasi | 16 | 14 | 26 | 8 |
| 116 / 109 | Aljabar dan pangkat | 14 | 14 | 13 | 10 |
| 203 / 196 | Segitiga dan rumus | 11 | 11 | 6 | 10 |
| 346 / 339 | Grafik garis dan diagram lingkaran | 14 | 14 | 9 | 2 |
| **Total** | | **55** | **53** | **54** | **30** |

Kandidat mencakup label, angka dan false positive; bukan jumlah unik rumus yang benar. Dari 55 kandidat, 27 mempunyai izin merge pada tahap raw; setelah pemetaan rentang/struktur, 17 formula memiliki spoken pada ekspor final. Angka ini tidak mengukur recall atau akurasi.

Seluruh **53 artefak MathCAT** memverifikasi profil efektif **Language=id, SpeechStyle=ClearSpeak, Verbosity=Medium**. Lima keluaran diagram, termasuk dekorasi bab aljabar yang dianggap ilustrasi, semuanya berstatus needs_review.

| Pengukuran | Hasil |
|---|---:|
| Layanan impor sampai ekspor dan penyimpanan materi | 65,712 detik |
| Batch inti, dengan scope menurut report perangkat | 65,312 detik |
| Request deskripsi Foundation Models, total | 33,748 detik |
| Inference UniMERNet, total | 14,029 detik |
| MathJax, total | 338,23 ms |
| MathCAT, total | 144,18 ms |
| Peak footprint aplikasi yang tersampel | 2,28 GiB |
| Thermal selama sampling | Nominal, 313 sampel |

Memori diukur tiap 200 ms untuk proses aplikasi; WebContent dan layanan model sistem tidak termasuk. Komponen waktu mengikuti scope masing-masing, bukan angka yang harus dijumlahkan menjadi wall time.

Materi **“Uji 4 halaman SMP — ClearSpeak”** tersimpan di aplikasi dan pembaca materi dibuka. Save/reopen setelah restart dan pendengaran VoiceOver belum diuji.

## Temuan kualitas dari pemeriksaan sumber

1. **ClearSpeak aktif, tetapi kesalahan input masih diteruskan.** Persamaan sederhana `9+0=9` dan `8×1=8` terbaca. Pecahan biasa/campuran dan daftar desimal masih tertahan. Tanda permil menjadi `%%`/`%o` pada chunk prosa yang justru berstatus ready.
2. **Sebagian pangkat sudah benar pada pengenalan, tetapi gagal masuk bacaan final.** UniMERNet mengenali `5x²+2x` serta polinom dengan pangkat dua/tiga dengan benar; pemetaan terhadap OCR yang kehilangan pangkat menahan spoken dengan alasan `ambiguous_geometry_withheld`.
3. **Ada pengenalan salah yang lolos sebagai ready.** Pada kalimat koefisien `x²`, spoken menyisipkan `bold i` sebelum `x kuadrat` (`p0002.layout.0007.c0001`). Bagian lain membaca `3x²` sebagai `13 x kuadrat` dalam chunk review. Ini membutuhkan pemeriksaan fidelitas hasil pengenalan, bukan pergantian gaya speech.
4. **Geometri masih parsial.** Keliling `K=AB+BC+AC` dibacakan, tetapi rumus luas segitiga dan hubungan label gambar belum lengkap.
5. **Grafik belum menyampaikan data utamanya.** Grafik garis dan diagram lingkaran hanya menghasilkan overview umum; pasangan hari–jumlah atau hari–persentase yang terlihat pada sumber belum disampaikan dalam spoken final. Keduanya ditandai needs_review.

Prioritas dari uji ini adalah membatasi/menangani crop rumus besar dan memeriksa penggunaan memori decoder, menyelaraskan pangkat pada merge, lalu memperbaiki validasi hasil pengenalan serta pasangan label–nilai grafik. Tidak ada perbaikan produksi tersebut diterapkan dalam eksperimen ini.

## Artefak

[Hasil terstruktur](multipage-clearspeak-results.json) memuat kedua percobaan, profil efektif, metrik, status per halaman dan spot check. Folder bukti lokal (diabaikan Git):

- `verification/multipage-clearspeak-v1/99aad38a-97d4-4209-bd71-f53734085d24/`: input, snapshot source, build/install/launch, run parsial, memory samples dan observasi proses berhenti.
- `verification/multipage-clearspeak-v1/1d5b99dd-f121-437a-9693-b2d934cccafa/`: batch selesai, raw lengkap, `audit.json`, `spoken-review.txt` dan `run/final_ready.json`.

Audit dapat diulang pada workspace yang memuat artefak dengan `python3 <folder-percobaan-pertama>/audit.py <folder-percobaan-yang-diaudit>`. Kelengkapan sumber dan akurasi umum tetap belum dinilai; pengecekan visual di atas adalah spot check, bukan benchmark beranotasi.
