# Nomor daftar dan fallback rumus pada pembaca

Build 29 memperbaiki dua masalah yang terlihat pada materi batch SMP build 28.

Nomor seperti `1.` sebelumnya menjadi chunk kalimat tersendiri, sehingga VStack memberi jarak vertikal sebelum isi daftar. Reader kini memproyeksikan marker dan kalimat berikutnya menjadi satu baris tampilan hanya jika keduanya berurutan, berada pada halaman dan blok sumber yang sama, serta tidak memuat gambar. Penanda dan awal teks memakai HStack dengan alignment firstTextBaseline; baris lanjutan mengikuti indentasi isi. VoiceOver menerima satu label gabungan. Pengelompokan berjalan di dalam topik saat membuka materi tersimpan, tanpa impor/inference ulang atau perubahan canonical chunks.

Teks `L-_xaxt atau L- ¿XABXt` berasal dari OCR rumus luas segitiga pada PDF 203, halaman cetak 196. Sumbernya menulis `L = 1/2 × a × t` atau `L = 1/2 × AB × t`. Hasil rumus tersebut belum lolos pemetaan OCR/MathML; pembaca sebelumnya menghapus penanda review lalu menampilkan payload OCR yang rusak. Formula-only chunk tanpa spoken tervalidasi kini menampilkan **“Rumus belum dapat dibaca.”** Nomor daftar di awal chunk tetap dipertahankan. Rumus sumber tidak ditebak atau dimasukkan sebagai hasil ekstraksi baru; raw, status dan artefak tetap tersedia.

## Verifikasi

Pengecekan Foundation terhadap `final_ready.json` asli run `d62d043c-9e3a-42d7-840a-1876ddc9cebc` meloloskan 14 kondisi: enam nomor daftar pecahan sejajar dengan isinya, coverage/urutan ID tetap, batas blok/halaman/urutan tidak dilintasi, fallback rumus luas dan nomor inline benar, serta formula tervalidasi dan peran question_start dipertahankan. Dari 84 chunk kanonik terbentuk 73 baris proyeksi sebelum filter topik, dengan 11 pasangan marker/isi. Hash ekspor sumber tetap sama.

Build/sign Debug SDK iPhoneOS berhasil. iPhone 16 Pro Max tidak tersedia saat pemeriksaan, sehingga build 29 **belum dipasang** dan tampilan/fokus/ucapan VoiceOver aktual belum diuji. Perbaikan hanya pada presentasi; inference serta validasi matematika belum berubah.

Hasil terstruktur: [reader-list-fallback-results.json](reader-list-fallback-results.json). Snapshot source, pemeriksaan Swift, output dan log build lokal berada di `verification/reader-list-fallback-v1/d951843c-4978-4919-969b-165a0bcfc944/`.
