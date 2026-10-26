# Navigasi topik dan pembaca pengguna

## Alur build 6

Materi → daftar judul topik → bacaan topik. Tombol **Topik sebelumnya** dan **Topik berikutnya** berada di atas, dengan target sentuh minimum 44 poin dan label teks. Perpindahan memperbarui topik dalam halaman yang sama, mengembalikan scroll ke atas dan meminta fokus VoiceOver ke judul. Font mengikuti Dynamic Type; chunk bacaan tidak diberi nomor UI.

Label review, disclosure teks sumber, dan toolbar ekspor diagnostik dihapus dari alur pengguna. Penanda preview seperti `[perlu review: n]` ditampilkan sebagai `n`; anotasi review yang hanya berisi metadata disembunyikan. Ini adalah pemetaan presentasi: status, teks sumber, preview, unresolved IDs dan hasil MathCAT asli tetap disimpan. Perubahan ini tidak membuat pangkat baru atau mempromosikan hasil yang ditahan menjadi spoken yang terverifikasi. Gambar dekoratif pada pembaca tidak dibacakan sebagai elemen VoiceOver terpisah dari deskripsinya.

## Eksperimen Qwen

Checkpoint tetap `mlx-community/Qwen3-VL-2B-Instruct-4bit`, revision `9c4f5209e57b31f4b9dfba735de3fb983739c9cc`, runtime MLXVLM Swift 3.32.3. Untuk topik, checkpoint VLM menerima **teks hasil ekstraksi**, tanpa gambar atau eksekusi vision encoder. Diagram tetap memakai jalur vision yang sudah ada. Tidak ada inference Mac/cloud, model baru, training atau perubahan parameter sampling.

`TopicNavigationService` mengirim alias ID, kind dan sourceText. Qwen hanya mengembalikan judul dan chunk IDs. Flatten semua anggota harus sama persis dengan urutan body chunks; ID asing, hilang, duplikat, perubahan urutan, JSON tidak sesuai atau generation tidak selesai ditolak. Batas: 32 chunk/10.000 karakter per window, berhenti di batas halaman dan judul utama, maksimum delapan request serial, prompt 6.000 token, generation 2.048 token, deadline sesudah load 120 detik, temperature 0, top_p 1, seed 0, tanpa retry. Chunk tunggal yang melebihi budget token tetap utuh dan memakai fallback.

Prompt v1 dan v2 dipertahankan. Keduanya masih menghasilkan satu topik besar pada sampel ini. Kebijakan v3 memakai judul/subjudul sumber yang berisi bahasan sebagai batas window. Label generik seperti Contoh, Alternatif Penyelesaian, Jawaban atau Solusi tetap bersama contoh yang sama. Heading berurutan tanpa isi di antaranya tidak dipecah sendiri. Qwen kemudian memberi judul kontekstual dan boleh membagi topik di dalam window. Ini adalah pembagian gabungan aturan sumber dan Qwen; model tidak menentukan batas melintasi heading utama. Model tidak menyalin ulang, memperbaiki OCR/matematika atau menyelesaikan soal. Jika suatu window gagal, kode memakai judul/subjudul sumber atau judul materi umum untuk window itu. Kegagalan ekspor topik juga tidak menggugurkan bacaan yang telah selesai. Pembatalan menyimpan raw yang sempat dihasilkan dan menunggu generation berhenti sebelum melepas model.

Materi baru disusun topiknya sesudah seluruh ekstraksi selesai. Materi lama mencoba kebijakan topik terbaru saat dibuka, sekali per versi kebijakan yang tersimpan. Setelah itu daftar langsung dibuka dari SwiftData; pembukaan ulang tidak menjalankan Qwen lagi. Pengguna dapat membatalkan pengelompokan materi lama untuk membaca berdasarkan judul yang tersedia.

## Data dan bukti

Canonical chunks tetap satu kali di SwiftData dan `final_ready.json` sumber. `topicIndexJSON` hanya menyimpan judul, referensi ID, asal judul, versi kebijakan serta referensi laporan. Header/footer/nomor halaman tetap disimpan sebagai auxiliary, di luar bacaan utama. Tidak ada perubahan schema SwiftData baru pada tahap ini.

Percobaan tersimpan di `Documents/topic-navigation/<material UUID>/<attempt UUID>/`: chunks snapshot, index awal, manifest model, prompt, peta alias, respons mentah, generation metrics, plan tervalidasi, index akhir, status, sampel memori dan laporan. Hasil PoC/eksperimen lama serta JSON ekstraksi asli tidak ditimpa.

Untuk pengukuran eksplisit, Debug menerima `--metra-topic-experiment <UUID materi yang sudah tersimpan>`. Flag hanya membuka materi itu, tanpa OCR baru. Probe startup mengekspor snapshot data yang benar-benar dibaca ulang dari repository, teks presentasi, coverage dan perjalanan ViewModel maju/mundur ke `Documents/topic-navigation/probes`. Flag ini tidak aktif pada pembukaan biasa dan tidak ada pada Release.

Pilot memakai materi tersimpan `34134240-d310-4b64-ad3c-debb45ab3360` pada iPhone 17 (`iPhone18,3`), iOS 27.0.1. Bahan awal berisi 26 canonical chunks: 24 isi dan dua auxiliary. Artefak lokal di `verification/topic-navigation-v1/` (diabaikan Git).

Percobaan prompt v1/build 4 selesai: satu topik besar, coverage 24/24 tepat sekali, semua field konten tetap sama terhadap JSON sebelum eksperimen. Load 1.015 ms, generation 7.532 ms, stage wall 8.640 ms, sampled app peak 2.482.441.568 byte, thermal nominal. Stage wall tidak memasukkan verifikasi hash model sebelum tahap ini; peak hanya proses app, bukan keseluruhan perangkat. Satu topik valid secara struktur belum memberi granularitas navigasi yang diinginkan, sehingga dua percobaan berikutnya memperjelas unit navigasi dan memakai batas heading sumber.

Lihat `topic-navigation-results.json` untuk hasil perangkat terbaru. Build/install, runtime generation, integritas referensi, kualitas semantik dan interaksi VoiceOver merupakan bukti berbeda. Probe ViewModel bukan pengujian gesture/fokus/suara VoiceOver oleh pengguna. Ekstraksi gambar baru, multi-page topic continuity, fallback/cancellation fault injection, dan akurasi sumber menyeluruh belum diuji pada pilot ini.

## Hasil akhir pilot

Kebijakan v3/build 6 menghasilkan dua topik: **Contoh 1.1: Menyelesaikan Persamaan Linear Dua Variabel** (13 chunk) dan **Penyelesaian Persamaan Linear Dua Variabel** (11 chunk). Dua request serial selesai dengan JSON dan coverage yang valid. Load total 962 ms, prepare 28 ms, generation total 5.585 ms, stage wall 6.624 ms. Request kedua memakai model yang sudah dimuat. Sampled app peak 2.530.938.232 byte; thermal awal/akhir nominal.

Sesudah aplikasi dihentikan dan dibuka ulang, index v3 yang sama dibaca dari SwiftData tanpa generation baru. Semua field 26 canonical chunks tetap identik dengan pemetaan JSON awal, dan `final_ready.json` di iPhone tetap identik byte demi byte. Probe ViewModel menelusuri dua topik maju, lalu mundur, dengan state tombol batas awal/akhir yang sesuai. Seluruh penanda `perlu review` hilang dari teks presentasi sampel; preview asli tetap ada. Contoh bacaan: “Apabila nilai m berubah maka nilai n bergantung pada nilai m, begitu pun sebaliknya.”

Build 6 bertanda tangan berhasil dan sudah terpasang di iPhone. Kode sumber PoC asli dan pin runtime/model tidak berubah. Tiga percobaan dan prompt sebelumnya dipertahankan. Judul model masih merupakan keluaran eksperimen, belum audit kualitas semantik; alur gesture/fokus VoiceOver perlu dicoba langsung oleh pengguna.
