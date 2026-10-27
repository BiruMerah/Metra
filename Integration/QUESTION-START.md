# Nomor soal dan kalimat awal

Build 27, branch `feat/poc-integration`. Atas permintaan pengguna, nomor soal yang terpisah akibat sentence tokenizer digabung dengan kalimat pertamanya pada ekspor baru.

## Aturan

`ReadingChunkBuilder` memakai policy `sentence_atomic_math_question_choices_v5`:

1. Blok mempunyai `questionID` dan `questionNumber` yang sudah ditentukan dari struktur sumber, serta tidak mempunyai `choiceLabel`.
2. Jika kelompok kalimat pertama hanya berisi marker nomor yang sama (`33.` atau `33)`) dan berupa teks, atomnya digabung dengan kelompok kalimat berikutnya yang mempunyai isi. Penggabungan terbatas pada blok sumber dan halaman yang sama.
3. Awal soal yang mempunyai marker terkonfirmasi, whitespace dan isi diberi `kind: question_start`, termasuk bila tokenizer sudah mempertahankannya sebagai satu kalimat. Satu questionID memperoleh paling banyak satu penanda awal per halaman.
4. Kalimat berikutnya tetap mengikuti batas kalimat. Blok heading, auxiliary, formula, tabel, diagram dan answer_choice tetap memakai pengelompokan masing-masing.
5. Source slices, formula atomik, unresolved IDs dan status dihitung dari atom gabungan oleh mekanisme yang sama. Validator coverage yang sudah ada tetap aktif sebelum ekspor.

Contoh tampilan yang dituju:

> 33. Keliling sebuah lingkaran adalah 88 cm.
>
> Luas lingkaran tersebut adalah ....

## VoiceOver dan penyimpanan

Reader mempertahankan satu Text/elemen aksesibilitas per chunk. Untuk `question_start`, label aksesibilitas diberi awalan peran: “Soal 33. Keliling …”. Pilihan jawaban dan kalimat lanjutan tetap mempunyai fokus masing-masing. Urutan sumber dan bacaan matematika tidak ditulis ulang oleh label ini.

`question_start` memakai field `kind` yang sudah disimpan dan dipetakan oleh domain/repository SwiftData. Tidak ada field model database atau dependency baru. Schema tetap `metra-ready-chunks-v4`; laporan ekspor mencatat policy v5 dan jumlah question_start. `questions[].stemChunkIDs` serta topic index dibentuk setelah penggabungan, sehingga memakai ID chunk ekspor baru.

Raw/run dan materi tersimpan lama dipertahankan. Untuk mendapat chunk baru melalui UI, impor ulang gambar sebagai materi baru; membuka materi lama memakai hasil yang sudah disimpan.

## Bukti dan batas

Kasus sumber yang diperiksa adalah run build 26 `13705219-8343-4dc7-9659-0fb94e70c8cd`. Nomor 33 dan kalimat awal berasal dari blok teks yang sama, tetapi ekspor lama menghasilkan tiga chunk: nomor, kalimat keliling, dan pertanyaan luas.

Status build/install terbaru dicatat di [question-start-status.json](question-start-status.json). Log dan snapshot lokal berada di `verification/question-start-v1/99a2d7f8-eab0-4973-bf95-386c419ce572/`.

Build bukan bukti hasil runtime atau pengalaman VoiceOver. Belum ada inference, ekspor ulang, pengujian fokus/ucapan VoiceOver atau test baru dijalankan untuk perubahan ini. Nomor yang terpisah menjadi blok layout tersendiri, atau belum mempunyai metadata soal terkonfirmasi, belum dicakup aturan penggabungan ini.
