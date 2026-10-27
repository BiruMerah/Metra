# Pilot Apple Foundation Models di iPhone

**Bahasa Indonesia berhasil dihasilkan pada iPhone dengan bahasa utama English.** Pilot build 15 memakai `FoundationModels.SystemLanguageModel.default` pada iPhone 17 (`iPhone18,3`), iOS 27.0.1 build 24A446. Availability `available`, locale `en_ID`, preferred languages `en-ID`, `id-ID`. `supportsLocale(id_ID)` justru mengembalikan `false`; informasi dukungan tersebut tidak menghalangi dua permintaan Indonesia dalam pilot ini. Hasil ini membuktikan konfigurasi dan prompt yang dicoba, bukan jaminan dukungan semua permintaan atau versi OS.

## Hasil nyata

| Permintaan | Waktu request | Hasil |
| --- | ---: | --- |
| Prompt English, jawaban English sebagai kontrol | 3,97 detik | Berhasil; definisi radius dalam dua kalimat. |
| Prompt English, instruksi jawaban Indonesia | 1,82 detik | Berhasil menghasilkan Indonesia. |
| Prompt dan instruksi Indonesia | 1,35 detik | Berhasil menghasilkan Indonesia; ada pengulangan kata “luas dan luas”. |
| Topik dari 53 canonical chunk sumber | 12,05 detik | JSON terstruktur berhasil, tetapi validasi topik gagal. |
| Deskripsi crop diagram geometri | 6,07 detik | Input gambar dan JSON Indonesia berhasil; relasi sudut salah. |

Contoh respons asli dari prompt English yang meminta Bahasa Indonesia:

> Radius sebuah lingkaran adalah garis lurus yang menghubungkan pusat lingkaran dengan titik pada kelilingnya. Ukurannya menentukan besarnya lingkaran.

Semua lima generation selesai tanpa error runtime. Angka waktu merupakan satu request per kasus, termasuk persiapan sistem yang tidak diekspos terpisah. Session baru dibuat untuk setiap kasus; cache model sistem tidak dikontrol. Urutan request adalah kontrol English, English→Indonesia, Indonesia→Indonesia, topik, lalu diagram. Jangan menyimpulkan perbandingan kecepatan bahasa atau Qwen dari angka ini.

### Topik belum diterima

Input menyalin `id` dan `sourceText` seluruh 53 chunk dari run `e54cb8be-a426-472f-9b74-26155e2d9d0b` tanpa koreksi, termasuk chunk kosong, OCR yang salah, dan footer. Output menghasilkan 7 topik meskipun prompt meminta 1–6. Rentang chunk bertumpang tindih/terbalik, terdapat ID yang tidak ada, dan coverage tidak lengkap. Judul seperti “Suhu sudut pada lingkaran” juga belum layak.

Schema `@Generable` pada pilot membentuk field judul dan ID rentang; jumlah, referensi, urutan dan coverage diperiksa kode sesudah generation. Validasi menolak hasil ini. Tidak ada topic index atau canonical chunk pengguna yang diubah. Pilot ini belum mengevaluasi pembagian pada materi yang urutan soalnya sudah dinormalisasi.

### Diagram belum diterima

Input adalah crop aktual yang juga dipakai Qwen pada run sebelumnya, tanpa petunjuk label atau jawaban pada prompt. Model membaca D, E, F, P, 47°, dan `(3x + 4)°`. Tetapi deskripsinya menempatkan `(3x + 4)°` **di titik E**, sedangkan busur pada gambar menandai **sudut DPE di P**. Model juga menyebut P titik tengah tanpa konfirmasi tekstual dalam crop, meskipun prompt meminta tidak mengasumsikannya. Hasil tidak dipromosikan menjadi bacaan pengguna. Tidak ada kesimpulan bahwa fine-tuning diperlukan atau bahwa model ini lebih baik daripada Qwen.

## Implementasi dan reproduksi

`Metra/App/FoundationModelsDeviceProbe.swift` adalah jalur Debug yang hanya aktif melalui `--metra-foundation-probe <UUID>`. Tidak dipanggil saat impor biasa. Seluruh request serial, memakai `SystemLanguageModel.default`, guardrail default, greedy sampling, maksimum 1024 output token, session baru per kasus, serta permintaan cancel setelah 60 detik. Tidak ada cloud fallback, bypass bahasa, atau inference Mac. Mac hanya membangun, memasang, mentransfer input, dan membaca laporan.

Folder input sandbox: `Documents/verification/foundation-models-v1/<UUID>/`, berisi:

- `request.json`: `sourceRunID`, `chunksSHA256`, `diagramSHA256`.
- `chunks.json`: array berurutan `{id, sourceText}` dari hasil asli.
- `diagram.png`: crop gambar sumber asli.

Probe memeriksa hash, menyimpan prompt/instructions, response, transcript, validasi, usage token, waktu, thermal, dan sampler memori app. Sampler **tidak** mengukur memori service model sistem. Checkpoint model dikelola OS; hash/revision model terpisah tidak tersedia dalam probe. Attempt yang sudah mempunyai `completed.json` tidak ditimpa; gunakan UUID baru untuk pilot berikutnya.

Build 15 berhasil sign/install, lima request dijalankan, lalu aplikasi dibuka kembali tanpa flag eksperimen. Pipeline produksi tetap memakai adapter Qwen yang sudah ada. Percobaan ini tidak memperbaiki satuan `cm²`, urutan A–B–C–D, OCR atau MathCAT, dan tidak mengubah SwiftData. PoC asli serta artefak eksperimen sebelumnya dipertahankan.

## Bukti dan batas

- [Ringkasan hasil dan respons asli](foundation-models-results.json).
- Laporan lengkap lokal: `verification/foundation-models-v1/04cce97b-4dec-4f5f-bda7-4d358e15d319/device-output/report.json`.
- Dalam folder yang sama terdapat response, transcript, input dan completed report. Folder induk menyimpan log build awal yang gagal karena akses macro, build berhasil, install/launch/transfer, source snapshot, input provenance dan pemeriksaan hash.
- Fingerprint source Swift/project sesuai build yang diuji; fingerprint 22 source PoC asli tetap sama.
- Tidak ada test suite ditambahkan. Lima permintaan perangkat dijalankan atas permintaan pengguna. Stabilitas ulang, learning assistant percakapan, benchmark Qwen dengan prompt identik, serta dataset diagram luas belum diuji.

Referensi API: [bahasa dan locale](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models), [image input dan model on-device iOS 27](https://developer.apple.com/videos/play/wwdc2026/241/).
