# Normalisasi bacaan dan pilihan jawaban — build 16

Build/sign/install berhasil pada iPhone 17 `valentino` (`iPhone18,3`, iOS 27.0.1). Satu gambar pengguna dijalankan ulang atas izin pengguna. Hasil tersimpan sebagai **Materi — normalisasi bacaan**, material/run `d1bc57d4-45d0-41a3-9bd9-13584ff0d7ab`.

## Hasil yang diperiksa

- Enam soal 31–36 masing-masing mempunyai empat pilihan **A, B, C, D**, seluruh 24 pilihan berstatus ready dan masing-masing menjadi satu chunk.
- `C.` dan `300` yang sebelumnya tersusun terbalik sekarang menjadi satu bacaan **C. 300** berdasarkan posisi sumber.
- Delapan dari delapan satuan berpangkat ready, dibandingkan enam pada baseline build 14. Contoh hasil MathCAT asli: **616 senti-meter kuadrat**, **324 senti-meter kuadrat**, dan **770 meter kuadrat**.
- 14 guard check di iPhone lolos, termasuk penolakan perubahan angka, operator tambahan, satuan salah, pangkat bertentangan dan hasil tanpa struktur pangkat gambar. Guard memakai artefak lama dan fixture MathML yang dinyatakan terpisah dari inference gambar baru.
- Hash gambar asli dan normalized sama dengan baseline. Raw OCR dan raw LaTeX semua 32 region juga identik. Multiset ID/payload segment dan seluruh referensi OCR final tetap sama. Normalisasi tidak memasukkan teks model baru atau mengubah nilai jawaban.
- Source fingerprint cocok dengan build yang diuji; 22 source PoC asli tetap sama. Materi lama tidak dimodifikasi.

Ini hasil satu halaman. Diagram geometri dan dua deteksi formula lama yang belum mendapat rentang sumber masih unresolved. Tidak ada klaim akurasi seluruh halaman, audio/gesture VoiceOver, atau stabilitas semua jenis dokumen.

## Cara kerja

### Satuan

`LengthUnitNormalizer` hanya menerima rentang angka+satuan panjang yang lengkap. Angka dan pemisah harus cocok persis. Semua huruf satuan harus sudah ada pada hasil pengenalan gambar, dengan tepat satu struktur pangkat 2/3, tanpa token tambahan atau konflik terhadap pangkat sumber.

Contoh `616 c m²` boleh diturunkan menjadi satuan `616 cm²` ketika sumber mengidentifikasi seluruh satuan `cm`. Pangkat tetap berasal dari struktur hasil UniMERNet. OCR `cmг`, `cmr`, atau apostrof tidak pernah menciptakan pangkat. Hasil datar tanpa `msup` tetap ditahan.

MathML turunan mengelompokkan satuan dan menambahkan intent/class satuan untuk MathCAT yang sudah dibundel. **MathCAT tetap menghasilkan seluruh speech.** Tidak ada penggantian string `cmr → cm²` atau kamus speech buatan aplikasi. Ejaan `senti-meter kuadrat` berasal dari aturan MathCAT Indonesia saat ini.

Artefak per formula mempertahankan hasil asli dan turunan secara terpisah:

- `mathml.xml`, `unimernet.raw.json`, `mathcat.raw.json`: keluaran jalur asli.
- `unit-normalization.json`: input, keputusan, operasi grouping/intent dan validasi sebelum/sesudah.
- `mathml.unit-normalized.xml`, `mathcat.unit-normalized.json`: MathML dan MathCAT turunan yang dipakai bacaan apabila lolos.
- `unit-consistency.json`: validasi final terhadap rentang sumber.

Tidak ada checkpoint, tokenizer, preprocessing detector/recognizer, parameter generation, binary atau aturan MathCAT yang diganti.

### Soal dan pilihan

`QuestionReadingNormalizer` membentuk struktur turunan dari nomor soal serta penanda pilihan yang eksplisit. Normalisasi dibatasi pada satu halaman dan satu soal. Set pilihan yang tidak lengkap/berulang, body yang tidak jelas, atau anchor soal dengan kolom ambigu mempertahankan urutannya.

Label dan nilai dalam satu pilihan dibaca sebagai satu chunk. Fragmen sumber pada baris yang sama disusun menggunakan kotak Vision, sementara rentang UTF-16 dalam satu observasi tetap berurutan. Label pilihan yang sempat diusulkan sebagai formula diberi peran `source_choice_marker`; bacaan label mengambil karakter sumber dalam konteks pilihan yang sudah dipastikan. Status/formula/crop asli tetap tersedia. Homoglyph OCR seperti Cyrillic `С` hanya dipetakan ke `C` pada bacaan label pilihan; source text tetap Cyrillic.

Seluruh source ref dan segment harus dipertahankan tepat sekali. `sourceBlockIDs`, `questionID`, `questionNumber`, `choiceLabel`, dan `readingNormalization` merekam struktur serta asalnya pada final extraction. Tidak ada soal yang diselesaikan atau jawaban yang diubah.

## JSON dan SwiftData

`final_ready.json` menggunakan schema **metra-ready-chunks-v4**. Adapter tetap menerima v3. Konten tetap berada dalam satu `chunks[]`; `questions[]` dan `topicIndex` hanya mereferensikan chunk tersebut:

```json
{
  "questions": [{
    "id": "p0001.question.33.p0001.layout.0004",
    "number": "33",
    "pageID": "p0001",
    "stemChunkIDs": ["p0001.layout.0004.c0001"],
    "choices": [
      {"label": "A", "chunkID": "p0001.layout.0039.c0001"},
      {"label": "B", "chunkID": "p0001.layout.0025.c0001"},
      {"label": "C", "chunkID": "p0001.layout.0034.c0001"},
      {"label": "D", "chunkID": "p0001.layout.0018.c0001"}
    ]
  }]
}
```

Contoh di atas dipersingkat untuk menunjukkan bentuk referensi; daftar stem lengkap mengikuti JSON aktual. Data pilihan tidak diduplikasi. SwiftData memakai schema yang sudah ada: canonical chunks disimpan menurut urutan baru dan `readyJSONPath` menunjuk JSON lengkap. Belum ditambahkan entitas question/choice terpisah. Reader menerima satu Text/accessibility label per pilihan karena pilihan kini satu chunk; audio dan navigasi VoiceOver aktual belum diuji.

Impor ulang gambar sebagai materi baru untuk mendapatkan normalisasi ini. Materi lama tetap memakai hasil tersimpannya.

## Bukti

- [Ringkasan terstruktur dan seluruh pilihan/spoken](reading-normalization-results.json).
- Final JSON lokal: `verification/reading-normalization-v1/ac8419aa-3997-443f-8483-1942f70758d3/run/final_ready.json`.
- Baseline, guard checks, log build/install/launch/transfer, fingerprint source dan snapshot berada di folder percobaan yang sama; hasil besar diabaikan Git.
- Pilot memakai replay Debug yang sudah ada, `--metra-mfd-replay <UUID>`. Pemeriksaan cached hanya aktif bila request memuat hash kedua baseline; impor normal menjalankan pipeline normalisasi tanpa fixture.

## Ukuran instalasi

Normalisasi ini tidak mengganti adapter Qwen. Bobot/folder Qwen **1.798.024.119 byte** masih dibundel. Bundle Debug build 16 yang diukur berjumlah **2.869.097.519 byte** sebelum thinning/compression instalasi. Angka tersebut bukan pengukuran footprint akhir iOS atau waktu transfer. Pilot Foundation Models build 15 masih eksperimen terpisah; lihat [hasilnya](FOUNDATION-MODELS.md).
