# Konflik formula bersarang dan ID internal

## Kasus sumber

Run iPhone build 6 `5bfd9b18-7078-48fe-8fd7-6d18d82eb217` memuat tiga deteksi PP-DocLayout yang bersarang: `p0001.formula.0006` untuk sudut AOB, `0008` untuk sudut COD, serta `0007` yang mencakup keduanya. UniMERNet dan MathCAT menghasilkan LaTeX/spoken untuk ketiganya. OCR mempertahankan `LAOB = 45°` dan `ZCOD = 120°`. Merge sebelumnya menahan ketiga hasil karena konflik rentang; `0008` menjadi occurrence tanpa source range dan preview memakai ID internal.

## Perubahan

- Resolver `whole_occurrence_utf16_v3` tetap mencari satu rentang utuh dengan dukungan posisi. Untuk ekspresi sudut yang sudah dikenali gambar, `L`/`Z` pada posisi operator sudut dapat menjadi anchor OCR jika seluruh token lain cocok, ada equality/degree, serta hasil gambar tidak ditahan pemeriksaan konsistensi. Ini pencocokan sumber, bukan koreksi OCR atau pembuatan simbol dari huruf saja.
- MathJax dan MathCAT pada sampel ini menghasilkan representasi leaf `∘` dan `°` yang berbeda. Resolver memakai canonical MathML MathCAT hanya pada pola sudut ketika semua token lain identik. Raw OCR, raw LaTeX, MathML, canonical MathML dan spoken tidak ditulis ulang.
- Deteksi gabungan hanya menjadi alias jika parent–child tercatat eksplisit, bbox anak tercakup minimal 95%, setiap rentang anak lengkap dan disjoint pada satu baris OCR, isi MathML parent terurai persis menjadi anak dengan separator kosong/`dan`/koma/titik koma, dan tidak ada klaim rentang dari formula lain di luar keluarga itu. Parent dan semua anak harus sudah memiliki speech yang tidak ditahan. Nesting bertingkat/bersaing tidak diselesaikan otomatis.
- Alias dipertahankan pada `FinalFormula` dengan status `duplicate_detection` dan `coveredByFormulaIDs`. Setiap raw detection tetap mempunyai ID, LaTeX, artifact dan pemilik segmen. Alias tidak mempunyai rentang OCR/spoken kedua. Builder memvalidasi bahwa seluruh referensinya menuju anak ready yang nyata.
- Chunk builder `sentence_atomic_math_headings_v3` mengecualikan alias dari bacaan canonical, dengan coverage eksplisit melalui anak. Setiap rentang OCR tetap harus muncul tepat sekali. Konflik yang tidak memenuhi syarat tetap ditahan.
- Tampilan preview lama mengganti payload yang persis merupakan unresolved formula ID dengan “Rumus belum dapat dibaca.” Huruf sumber seperti m/n dan tanda kurung di dalam sumber tetap dipertahankan. Metadata unresolved/status tidak dihapus atau dipromosikan menjadi ready.

Schema utama JSON tetap kompatibel dengan penambahan field opsional; schema SwiftData tidak berubah. Perubahan engine diterapkan pada ekstraksi berikutnya. Materi tersimpan lama mendapatkan perbaikan tampilan ID, tetapi tidak otomatis diganti hasil merge-nya. Run dan materi lama dipertahankan untuk pembanding.

## Verifikasi perangkat

Debug menyediakan `--metra-formula-audit <run UUID>` untuk membentuk hasil turunan dari artefak iPhone yang tersimpan, tanpa inference baru dan tanpa menimpa sumber. Mode `--metra-formula-replay <run UUID>` melakukan pemeriksaan yang sama terlebih dahulu, kemudian hanya jika lolos memproses ulang byte gambar asli melalui pipeline iPhone dan menyimpan materi baru. Flag tidak aktif pada pembukaan normal atau Release.

Setiap attempt berada pada `Documents/verification/formula-merge-v1/<UUID>` dengan laporan, JSON turunan, snapshot bacaan dan progress. Kasus metadata negatif menghilangkan hubungan parent–child, menghilangkan MathML gambar, atau membuat parent/child berbeda nilai; ini safety fixtures, bukan bukti model pada foto baru. Tidak ada inference di Mac.

Build 7 lolos build/install tetapi gagal pemeriksaan merge di iPhone: perbedaan `∘`/`°` belum tertangani. ID internal, literal m/n, sumber bersarang dan kasus konflik negatif sudah lolos. Inference ulang tidak dijalankan pada percobaan gagal ini. Source, hash dan laporan kegagalan tetap disimpan di `verification/formula-overlap-v1`.

Build 8 menambahkan pemilihan canonical MathML yang dibatasi kesamaan seluruh token lainnya. Launch audit ditolak iOS karena iPhone terkunci. Build 9 memperketat alias agar hanya berlaku pada deteksi PP-DocLayout dengan pencocokan MathML utuh, kemudian berhasil build/sign/install. Pengguna memilih menjalankan sendiri; tidak ada launch atau inference otomatis berikutnya.

Artefak run build 9 pengguna `50f16b6d-aadf-4ffe-af6c-80623ccfdaff` kemudian diperiksa: formula `0006` (AOB) dan `0008` (COD) berstatus ready dengan speech sudut masing-masing. Formula gabungan `0007` berstatus `duplicate_detection`, merujuk kedua anak, tanpa spoken/rentang sumber kedua. Source slice pada canonical chunks berjumlah satu untuk setiap anak dan nol untuk alias. Preview kalimat memuat kedua sudut sekali; keseluruhan chunk masih needs_review karena formula huruf lain. Ini observasi satu halaman, bukan bukti repeatability atau pemeriksaan seluruh akurasi sumber. Cuplikan bukti ada di `verification/unit-powers-v1/observed-user-build9-angle-output.json`. Pemeriksaan ID pada build 7 tetap berlaku untuk kode tampilan yang sama.

Untuk mencoba pada build terbaru: tambahkan lagi gambar yang sama dari galeri, lalu proses sebagai materi baru. Bacaan lama tidak otomatis diremerge. Periksa apakah kedua sudut pada soal 31 menjadi spoken masing-masing sekali dan tidak ada ID internal yang terbaca. Bila rumus tanpa teks sumber tetap gagal, pembaca menampilkan “Rumus belum dapat dibaca.” Hasil lama tetap tersedia untuk pembanding. Perbaikan satuan build 10 memiliki [status terpisah](UNIT-POWERS.md) dan belum dijalankan oleh agent.

Status lengkap tersedia pada `formula-overlap-results.json`. Bukti hanya berlaku untuk sampel yang diperiksa; tidak membuktikan seluruh simbol sudut, semua overlap, recall formula, atau akurasi sumber. Geometri/diagram, checkpoint, preprocessing dan parameter generation tidak ditingkatkan pada perbaikan ini.
