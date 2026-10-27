# Perbaikan konsistensi request Foundation — build 20

Tanggal: **26 Oktober 2026**. Branch `feat/poc-integration`. Build **20** sudah build/sign/install dan diuji pada **iPhone 16 Pro Max, iPhone17,2, iOS 27.0.1 / 24A446**, UDID berakhir `2801C`.

## Perbaikan

Uji [build 19](CONSISTENCY.md) menemukan evidence yang bernilai sama tetapi urutan key JSON berubah antar-proses. String prompt akhirnya berbeda dan bacaan diagram tidak konsisten.

Build 20:

1. `FoundationDiagramRequestEncoding` membuat encoder baru dengan `.sortedKeys` untuk payload yang benar-benar dimasukkan ke prompt.
2. Observasi diurutkan berdasarkan raw source order, dengan ID sebagai penentu saat urutannya sama. Formula diurutkan menurut ID sumber sebelum enumerasi referensi diagram. Batas konteks, teks, angka dan rumus tidak ditulis ulang.
3. `evidence.prompt.json` menyimpan byte payload persis yang ditempelkan ke string prompt. `evidence.json` tetap menjadi salinan diagnostik yang mudah dibaca.
4. Setiap request menyimpan checksum prompt, instruksi, gambar dan canonical declared schema pada `generation/request.fingerprint.json`. `generation/schema.json` menyimpan schema yang dicatat. Serialisasi internal schema oleh iOS dan hash checkpoint model sistem tidak diekspos.
5. Policy dicatat sebagai `foundation_diagram_evidence_v3`, encoding `foundation_request_sorted_keys_v1`. Sampling tetap greedy, maksimum 1.536 response token, deadline pembatalan 60 detik, sesi baru per diagram dan output cache nonaktif.

Tidak ada perubahan checkpoint ONNX/MathCAT, prompt instruksi diagram, nilai OCR, validator relasi atau recognizer rumus. Qwen/MLX tetap tidak ada dalam bundle. Semua eksperimen sebelumnya dipertahankan.

## Pengujian ulang

Tiga ekstraksi penuh baru, masing-masing dari proses aplikasi baru, dijalankan serial pada **23.45–23.48 WIB**. Gambar dan judul sama dengan uji build 19. Semua inference di iPhone; Mac hanya build, transfer dan audit artefak.

Sumber: lampiran halaman soal 31–36, 1127×1600. SHA-256 `a9a40fccc471789ffaeffe64e0eac36bcf12bbce2a8d11fc4e8fab700307edcb`.

| Ukuran | Build 19: 3 run | Build 20: 3 run |
|---|---:|---:|
| Prompt byte berbeda | 3 versi | **1 versi** |
| Isi parsed JSON diagram | 3 versi | **1 versi** |
| Bacaan diagram setelah validasi | 2 versi | **1 versi** |
| Isi `final_ready`, metadata run diabaikan | 2 versi | **1 versi** |
| OCR, crop, formula dan struktur nonvisual | Sama | **Sama** |

Pada build 20, ketiganya mempunyai fingerprint request identik:

- Prompt: `8c1e8f7f70401d0e9c3bc43a04f1ab1f00b77c3e75f498d770a5761a2e18838d`
- Instruksi: `f34df26f68152b132fa25018ac745311a5fdbfcec798914dc82608aa4cfd29c0`
- Crop diagram: `a975cc23bd454532949f2f75c624b1fbae2930c278b68c438d9aa6de22236757`
- Canonical declared schema: `970d635f99632c6b4b6b8dacfae4bf866af635ba81a70970acc98896ebb84e3e`

Checksum yang direkam aplikasi diperiksa kembali terhadap file aktual; semua cocok. Payload yang disimpan persis sama dengan bagian JSON pada string prompt. Nilai evidence tetap sama dengan build 19; seluruh 20 pemeriksaan regresi sumber/rumus/struktur terhadap baseline lolos.

Setiap run tetap memuat **43 observasi OCR, 35 region rumus, 49 chunk, 5 soal/20 pilihan canonical dan satu grup topik berdasarkan heading/fallback**. Sembilan rentang satuan yang diperiksa ready pada semua run. Setiap run menghasilkan material baru yang tersimpan; seluruh segmen sumber tetap dipertahankan sekali.

Urutan key pada file respons SDK mentah masih berbeda (tiga hash byte respons), tetapi seluruh nilai JSON, urutan array, deskripsi, relasi, uncertainty dan bacaan akhirnya sama. Perbandingan parse JSON mengabaikan urutan key object, tanpa mengabaikan nilai atau urutan array.

Waktu request Foundation **10,12 / 8,68 / 9,43 detik**. Angka ini deskriptif; cache model sistem tidak dapat dikendalikan, dan transfer folder run selesai berlangsung saat inference berikutnya. Ini bukan perbandingan performa cold/warm.

## Batas hasil

**Konsistensi pada sampel ini membaik; akurasi diagram tetap parsial.** Model masih memasangkan 47° pada D–P–E dan `(3x+4)°` pada P–E–D. Validator menolak keduanya; bacaan menyebut nilai tanpa mengklaim vertex yang salah. Hasil tetap `needs_review` dan status engine `partial`.

Kegagalan crop kalimat `(3x+4)°`, notasi LDFE/LDPE yang belum diroute dan footer yang menghalangi normalisasi soal 36 tidak diubah oleh perbaikan serialisasi. Uji ini tidak membuktikan semua gambar, semua perangkat, input kamera atau pembaruan iOS selalu memberi hasil identik. Model sistem tetap dikelola iOS dan checkpoint aktualnya tidak dapat dipin oleh aplikasi.

Topik yang diuji mengikuti heading/fallback sumber. Tidak ada pengelompokan semantik Foundation dalam eksperimen ini.

## Bukti

Ringkasan yang masuk Git: [consistency-fix-results.json](consistency-fix-results.json).

Data lokal: `verification/consistency-fix-v1/5cd51b38-9941-4d38-a618-0acd74a40b63/`. Memuat snapshot sebelum perubahan, source yang dikompilasi, build/install log, input immutable, raw tiap run, fingerprint, hasil pembandingan dan `audit.py`.

| Run | Run ID |
|---|---|
| 1 | `b3778d33-c1a1-4c90-b3e0-32040b8dae4a` |
| 2 | `5989fc44-8088-4eff-8849-5b9a41e5cb63` |
| 3 | `b899ac0b-a275-4b03-90bc-72ae2f51e4af` |

Build 20 tetap terpasang pada iPhone. Tiga material uji baru menggunakan judul **Materi — uji konsistensi**. Material dan hasil lama tetap ada.
