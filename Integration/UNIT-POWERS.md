# Satuan berpangkat — build 10

Build Debug 10 berhasil dibuild, ditandatangani, dan dipasang pada iPhone. Pengguna memilih menjalankan sendiri. Aplikasi tidak diluncurkan oleh agent; probe, fixture, dan inference satuan versi baru **belum dijalankan**. Hasil `cm²`/`m²` masih menunggu pemeriksaan pengguna.

## Temuan pada hasil lama

Run pengguna build 9 `50f16b6d-aadf-4ffe-af6c-80623ccfdaff` memuat halaman yang sama dengan screenshot. Empat pilihan `cm²` berada dalam region text; OCR menghasilkan `cm2` atau `cmг`, sehingga proposal formula tambahan lama melewatkan satuan dua huruf tersebut. Dua crop `m²` lama hanya mengambil satuan dan sebagian digit di sebelah kirinya. UniMERNet menghasilkan `; m ^ { 2 }` dan `1 m ^ { 2 }`, yang kemudian dibaca MathCAT sesuai hasil tersebut. Jadi masalah yang teramati mencakup routing, crop, serta validasi hasil gambar.

Byte sumber SHA-256: `44ae7503ee560c6582171b4c33ea006ad69a656759a2495873d2ee409b4d5f9d`. Run, crop, raw OCR/model, dan source sebelum perubahan dipertahankan di `verification/unit-powers-v1/` yang diabaikan Git.

## Perubahan

- Proposal tambahan mengenali rentang angka beserta satuan panjang `mm`, `cm`, `dm`, `m`, `dam`, `hm`, atau `km` dengan suffix pangkat eksplisit, datar, atau rusak. Contoh: `154 cm2`, `616 cmг`, `1.386 m-`. Suffix rusak hanya menjadi petunjuk lokasi crop; tidak menghasilkan pangkat atau mengubah OCR.
- Crop mengambil gabungan character box Vision untuk seluruh nilai dan satuan. Margin horizontal `max(2px, 0.05 × tinggi)` dan vertikal `max(3px, 0.25 × tinggi)` mempertahankan area pangkat. Proposal ekspresi/huruf yang berada pada rentang yang sama tidak membuat crop satuan kedua.
- UniMERNet tetap membaca gambar. MathJax dan MathCAT tetap menghasilkan MathML dan spoken. Validator khusus mengharuskan angka dan satuan cocok persis dengan sumber, satu struktur `msup` berpangkat 2/3, serta tidak ada token tambahan. Konflik pangkat eksplisit atau digit 2/3 yang teramati ditahan. Tidak ada penghapusan token buruk untuk memaksakan speech.
- `unit-consistency.json` menyimpan keputusan dan alasan. Hasil yang ditahan mempertahankan raw LaTeX, MathML, MathCAT, serta sumbernya. Referensi artefak masuk ke final extraction; kebijakan dan margin dicatat dalam config snapshot.

Satuan biasa seperti `88 cm` dan `14 m` memakai jalur sebelumnya. Proposal ini tetap melewati region yang sudah bertumpang tindih dengan deteksi formula PP-DocLayout. Akurasi character box, angka sumber, dan hasil model belum dibuktikan oleh build ini. Validator ketat juga dapat menahan hasil benar jika digit atau pemisah angka OCR salah. Pelafalan satuan dua huruf dan pemisah angka oleh MathCAT masih perlu didengar pada hasil baru.

Checkpoint, runtime, parameter generation, schema SwiftData, diagram, dan PoC asli tidak diubah.

## Pemeriksaan pengguna

1. Buka Metra build 10 dan impor gambar yang sama sebagai **materi baru**. Materi tersimpan lama tidak diproses ulang otomatis.
2. Periksa empat pilihan `cm²` dan empat pilihan `m²`: angka, satuan, pangkat, serta tidak ada tambahan titik koma atau digit.
3. Jika masih salah, gunakan folder run baru untuk membandingkan crop, `latex.raw.txt`, `mathml.xml`, `mathcat.raw.json`, dan `unit-consistency.json`. Hasil lama tetap tersedia.

Debug menyediakan probe opt-in `--metra-unit-replay <run UUID>` untuk pemeriksaan fixture lalu ekstraksi ulang di iPhone. Probe **belum dieksekusi** dan tidak aktif pada launch normal atau Release. Tidak ada inference di Mac.

Log signed build terakhir: `verification/unit-powers-v1/build-10-signed-recorded.log`. Instalasi: `verification/unit-powers-v1/install-build10.json`. Source fingerprint build: `verification/unit-powers-v1/source-sha256-build10.json`. Status terstruktur: [unit-powers-status.json](unit-powers-status.json).
