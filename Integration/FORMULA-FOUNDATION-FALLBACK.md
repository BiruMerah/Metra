# Deskripsi Foundation untuk rumus yang ditahan

**Status 28 Oktober 2026: fallback rumus otomatis dinonaktifkan.** RunCoordinator tidak lagi memanggil layanan Foundation untuk rumus. Run baru memakai hasil utama MathCAT dan menyimpan alasan tinjauan jika bacaan ditahan; report/config mencatat `enabled: false` dan nol permintaan fallback. Jalur deskripsi diagram tetap aktif. Materi lama yang sudah tersimpan tidak ditulis ulang dan bisa tetap memuat deskripsi dari percobaan sebelumnya.

Catatan di bawah mendokumentasikan percobaan sebelumnya, bukan perilaku aktif.

Kebijakan `foundation_formula_image_fallback_v1` menambahkan jalur kedua setelah hasil utama selesai dibentuk. Rumus dengan `spokenText` yang sudah diterima tetap memakai hasil MathCAT yang sama. Hanya rumus yang belum memiliki bacaan dan bukan alias deteksi duplikat yang dikirim ke Foundation.

## Input dan hasil

Foundation menerima satu crop gambar rumus, instruksi pembacaan Indonesia, dan skema terstruktur: apakah terdapat matematika, notasi yang terlihat, deskripsi lisan, serta bagian yang tidak jelas. OCR, LaTeX gagal, hasil MathCAT yang ditahan, jawaban acuan dan hasil percobaan sebelumnya tidak dikirim. Model berjalan lokal pada iPhone, tanpa provider jaringan atau cloud fallback. Setiap formula memakai sesi baru, greedy sampling, paling banyak 768 token, dan tenggat 30 detik.

Prompt meminta pembacaan simbol dan struktur yang terlihat, termasuk pembilang/penyebut, pangkat, tanda dan kurung. Model tidak diminta menghitung, menyederhanakan, menjawab soal atau mengisi simbol yang hilang. Prompt, instruksi, skema, hash gambar, respons mentah, transcript dan waktu permintaan disimpan per kandidat.

Hasil ditambahkan sebagai `formulaFallbacks` pada dokumen final turunan. `final-extraction.primary.json`, source/spoken extraction dan semua formula utama tetap tersimpan. Field formula utama, status `needs_review`, alasan penolakan dan ID belum terselesaikan tidak diubah menjadi hasil tervalidasi.

## Reader dan penyimpanan

Deskripsi yang tersedia tampil sebagai **Deskripsi alternatif rumus: …** pada teks dan label aksesibilitas reader. Bagian yang belum jelas tetap disertakan. Output kosong, gagal, tidak terbaca atau diklasifikasikan bukan matematika tidak dijadikan bacaan rumus. Pesan netral tetap tersedia ketika fallback tidak menghasilkan deskripsi yang berguna.

ID fallback ikut tersimpan dalam chunk dan melewati penggabungan konteks, konversi domain serta SwiftData. Tambahan penyimpanan berupa Data opsional agar record lama tetap dapat dibaca. Kehadiran teks yang menyerupai label fallback saja tidak melewati penjagaan reader; metadata fallback eksplisit juga diperlukan. Hasil MathCAT selalu diprioritaskan.

## Pengujian

- `Tools/FormulaFallbackChecks.swift`: 15 pemeriksaan produksi untuk label alternatif, ketidakpastian, prioritas bacaan utama, status tinjauan, kompatibilitas Codable lama dan metadata fallback.
- 26 pemeriksaan aturan/reader dari `Tools/FormulaRegressionChecks.swift` dijalankan kembali dan lulus.
- Probe iPhone mengimpor lima halaman asli yang sama, membandingkan seluruh 47 bacaan build 41, memeriksa hasil turunan identik pada halaman/formula utama, memeriksa bahwa hanya formula ditahan yang diminta, hash crop dan input tanpa OCR/candidate, serta teks dan metadata yang dibaca kembali dari SwiftData.
- Materi build 41 juga dibaca kembali untuk memeriksa bahwa penambahan field penyimpanan tidak menghapus hasil lama.

Build 42 berhasil dan uji perangkat sedang berlangsung. Pemeriksaan routing/format bukan pengesahan akurasi konten Foundation; isi deskripsi perlu dibandingkan dengan crop sumber. Belum ada uji mendengarkan atau pemahaman siswa.
