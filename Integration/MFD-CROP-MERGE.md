# Gabungan crop DocLayout, Vision, dan Pix2Text-MFD

Integrasi aktif pada **Metra Debug build 14**, branch `feat/poc-integration`. Build/sign/install berhasil; pilot dijalankan pada iPhone 17 (`iPhone18,3`), iOS 27.0.1. Impor galeri/kamera berikutnya memakai jalur yang sama dengan pilot ini. Tidak ada perubahan model UniMERNet, MathJax, MathCAT, atau checkpoint Qwen. PoC asli dan seluruh eksperimen lama dipertahankan.

## Jalur utama

PP-DocLayout tetap membentuk region halaman. Vision membaca teks dan membuat proposal ROI seperti sebelumnya. **Pix2Text-MFD** menjadi sumber kandidat crop tambahan. Ketiganya digabung sebelum **UniMERNet → MathJax → MathCAT**. Detector MFD berada di bawah heavy-inference gate yang sama dan di-unload sebelum pengenalan rumus; tidak ada inference Mac/backend/cloud.

Model tambahan: `breezedeus/pix2text-mfd`, revision `fc3797af79391c32ed0d56f8b5f437b5a49271be`, berkas `mfd-v20240618.onnx`, **44.573.224 byte**, SHA-256 `51a8854743b17ae654729af8db82a630c1ccfa06debf4856c8b28055f87d02c1`. Ini versi repo yang dibahas, bukan pergantian diam-diam ke MFD 1.5. ONNX FP32 opset 17 mempunyai dua kelas `embedding`/`isolated`, input dinamis NCHW dan output `[1,6,N]`. Model/size/hash/tensor names diperiksa saat runtime.

Adapter Swift memakai ONNX Runtime 1.24.2 CPU, dua thread, target lebar 768 dengan rasio aspek dipertahankan, canvas kelipatan 32, batas sisi input 1536, letterbox 114, RGB bilinear half-pixel, NCHW /255, threshold 0.25 dan NMS kelas sama 0.7. Pada sampel ini input `[1,3,1120,768]`. Paritas numerik resize terhadap OpenCV/Ultralytics belum diukur. Parameter dan perbedaan tercatat di `Resources/Pix2Text-MFD.config.json` dan snapshot setiap run. Deklarasi lisensi HF dan embedded ONNX juga disimpan sebagai provenance; penilaian distribusi belum dilakukan.

### Keputusan crop

- Raw output, crop, dan overlay kedua detector selalu disimpan terpisah. Confidence MFD tidak dibandingkan langsung dengan confidence DocLayout/Vision.
- ROI DocLayout yang bertumpang tindih tetap memakai jalur lama. MFD yang bertumpang tindih disimpan sebagai bukti, tanpa pengenalan kedua.
- Satu rentang Vision yang jelas dapat dipadankan dengan MFD. Union bbox mengambil crop dari gambar asli; tambahan glyph di luar rentang sumber menyebabkan fusion ditahan. Proposal dan crop Vision awal tetap tersedia, dengan `proposalSourceIDs` dan keputusan penggantiannya.
- Area kosong dapat mendapat crop MFD baru. Angka biasa, huruf tunggal/list marker, dan token satuan sederhana yang terlihat pada OCR tidak menjadi formula tambahan. Hint ini hanya memveto proposal, tidak membentuk LaTeX atau MathML.
- Overlap ambigu dan kandidat pada region visual belum diaktifkan dalam pilot ini. Resolver sumber tetap harus menemukan occurrence lengkap sebelum mengizinkan speech. Ini penggabungan kandidat lokasi, bukan jaminan ekuivalensi atau akurasi matematika.

Kebijakan: `supplemental_mfd_crop_merge_v2`. Setiap deteksi MFD mempunyai satu keputusan di `mfd-crop-merge.json`. Seluruh active regions ada di `combined-formula-regions.json`; overlay gabungan memakai merah untuk DocLayout formula, hijau untuk proposal Vision, oranye untuk MFD, dan biru untuk kelas lain.

## Hasil perangkat pada gambar pengguna

Sumber lampiran 1127 × 1600, SHA-256 `a9a40fccc471789ffaeffe64e0eac36bcf12bbce2a8d11fc4e8fab700307edcb`. Hash ini diperiksa di perangkat pada semua pilot.

| Percobaan | Hasil |
| --- | --- |
| Build 12, MFD saja | 14 kandidat, inference 244,1 ms, total komponen 714,4 ms. Tidak menemukan delapan ekspresi cm²/m² secara utuh; kandidat huruf pilihan juga muncul. |
| Build 13, integrasi awal | 7 crop MFD aktif. Ditemukan kesalahan nyata: angka 88 menjadi orphan superscript dan mencapai speech. Validator satuan juga menolak elemen spasi MathML kosong. Run gagal kualitas ini dipertahankan. |
| **Build 14, integrasi diperbaiki** | **2 crop MFD aktif**, keduanya ready dan muncul masing-masing sekali pada source slices bacaan. MFD inference 196,7 ms, total komponen 671,2 ms; merge 26,4 ms. |

Pada build 14, keputusan untuk 14 kandidat terdiri dari 2 overlap DocLayout, 5 overlap Vision, 5 literal sumber biasa yang ditahan, 1 fusion dengan rentang Vision, dan 1 crop area kosong.

- **47° pada paragraf soal 36:** crop tambahan MFD → UniMERNet → MathCAT menghasilkan **“47 derajat”**, ready, satu occurrence pada bacaan.
- **154 cm²:** kotak MFD hanya menguatkan area angka 154. Crop lengkap angka+satuan berasal dari rentang Vision yang sudah ada, dipadankan dengan MFD. Hasil **“154 c m kuadrat”**, ready, satu occurrence. Ini bukan bukti MFD sendiri mendeteksi cm².
- **88:** kandidat MFD ditahan sebelum UniMERNet. Final chunk tetap **“Keliling sebuah lingkaran adalah 88 cm.”**, source dan spoken identik.
- Dari 8 rentang satuan berpangkat, **6 ready dan 2 ditahan**. `324 cm²` dan `616 cm²` menghasilkan struktur `c` di luar `m²`; validator tidak menafsirkan ulang hasil tersebut. Enam hasil yang lolos mencakup jalur Vision lama dan perbaikan validator, bukan enam tambahan deteksi MFD.

32 ROI aktif bersama pada build 13/14 mempunyai raw LaTeX identik. Raw prediksi MFD juga identik. Perubahan readiness pada satuan berasal dari validator yang sekarang mengabaikan `mspace` kosong sebagai layout (`image_length_unit_consistency_v2`), tanpa menghapus angka/operator atau mengubah MathML/speech. Resolver `whole_occurrence_utf16_v4` dapat memakai token derajat canonical MathCAT untuk pola derajat numerik apabila semua token lainnya identik, sehingga occurrence 47° dapat disejajarkan tanpa mengubah sumber.

Run terakhir `e54cb8be-a426-472f-9b74-26155e2d9d0b` tersimpan sebagai **“Materi — uji crop gabungan”**. Ada 32 kandidat formula aktif; runtime selesai tidak berarti semua formula benar. Diagram geometri, beberapa hasil OCR/recognition lama, dan dua satuan di atas masih bermasalah. Tidak ada klaim Handbook compatibility, audit akurasi penuh, atau peningkatan akurasi umum.

## Reproduksi dan bukti

Bobot besar diabaikan Git. Pada clone/Mac lain, persiapkan model dari berkas lokal atau unduh revision yang dipin secara eksplisit:

```sh
python3 Tools/prepare-mfd-assets.py --source /path/to/mfd-v20240618.onnx
# atau
python3 Tools/prepare-mfd-assets.py --download
python3 Tools/prepare-poc-assets.py --source ../Approach-Latest-Metra
```

Script persiapan hanya salin/download/hash, tanpa inference. Build kemudian menyertakan MFD langsung dalam bundle; pengguna iPhone tidak perlu mengimpor model tambahan.

Debug opt-in `--metra-mfd-only <UUID>` menjalankan detector saja. `--metra-mfd-replay <UUID>` memakai extraction service normal dan menyimpan materi baru. Input `input.png` dan `request.json` dengan `sourceSHA256` berada di sandbox `Documents/verification/mfd-only-v1/<UUID>/` atau `mfd-integration-v1/<UUID>/`. Flag tidak aktif pada launch biasa/Release.

- [Hasil terstruktur dan pemeriksaan source slices](mfd-crop-results.json).
- [Overlay gabungan terakhir](verification/pix2text-mfd-v1/271c7caa-1b5e-46c4-9f30-7534a3a9a8fd/replay-build14/21151a45-efed-4841-9135-03f79691a83a/run/pages/p0001/combined-layout-overlay.png).
- [Final extraction terakhir](verification/pix2text-mfd-v1/271c7caa-1b5e-46c4-9f30-7534a3a9a8fd/replay-build14/21151a45-efed-4841-9135-03f79691a83a/run/final-extraction.json).
- [Canonical chunks terakhir](verification/pix2text-mfd-v1/271c7caa-1b5e-46c4-9f30-7534a3a9a8fd/replay-build14/21151a45-efed-4841-9135-03f79691a83a/run/final_ready.json).

Seluruh attempt, error launch perangkat terkunci, run build 13, raw model/crop, config, metrics, log build/install/transfer dan source fingerprint disimpan di folder `verification/pix2text-mfd-v1/271c7caa-1b5e-46c4-9f30-7534a3a9a8fd/` yang diabaikan Git. Tidak ada test suite ditambahkan; satu pilot detector dan dua pilot integrasi nyata dijalankan atas permintaan pengguna. Kamera, batch, cancellation, VoiceOver gestures/audio, dan baseline end-to-end tanpa MFD pada piksel identik belum diuji.

Referensi implementasi: [model MFD yang dipin](https://huggingface.co/breezedeus/pix2text-mfd/tree/fc3797af79391c32ed0d56f8b5f437b5a49271be), [pemisahan detector/crop/recognizer Pix2Text](https://github.com/breezedeus/Pix2Text/blob/main/pix2text/text_formula_ocr.py), [wrapper detector CnSTD](https://github.com/breezedeus/CnSTD/blob/master/cnstd/yolo_detector.py).
