# MathCAT native iOS bridge

Header, bridge Rust, Cargo.lock dan lisensi berasal dari PoC build 29. Bridge dan library Metra kini memakai ClearSpeak Indonesia. Build aplikasi memakai binary `lib/ios-arm64/libmetra_mathcat.a` yang sudah tersedia; tidak memerlukan direktori `target` atau Rust pada iPhone.

MathCAT **0.7.5** dari arsip rilis crates.io, tanpa perubahan rules bawaan. Lisensi MIT ada di `LICENSE-MathCAT`; `Cargo.lock` dan `rust-version.txt` mencatat dependency/toolchain. Hash library aktif ada di `Resources/model-manifest.json` dari root repo. Target `aarch64-apple-ios`, deployment library iOS 17. Target simulator belum dipaketkan.

Untuk membangun ulang, siapkan Rust beserta target `aarch64-apple-ios`, Xcode, Python 3, dan source MathCAT 0.7.5 yang tidak diubah. Jalankan dari root repo:

```sh
bash Tools/build-mathcat-ios.sh /path/to/mathcat-0.7.5
```

Argumen source opsional pada workspace ini; default menunjuk source di `../Approach-Latest-Metra/tools/mathcat-build/source/mathcat-0.7.5`. Script membangun bridge repo ini melalui staging `.build/mathcat-native`, memakai lockfile, lalu mengganti library yang dibundel. Source/hasil PoC lama tidak dimodifikasi. Toolchain khusus dapat dipilih lewat `PATH`, `CARGO_HOME`, dan `RUSTUP_HOME`. Link app memakai `lib/ios-arm64/libmetra_mathcat.a`, header C di `include/`.

`metra_mathcat_convert` mengeksekusi seluruh transaksi pada **satu thread OS tetap** yang dimiliki Swift `MathCATAdapter`: set rules directory → set semua preferences → set MathML → get spoken → get effective preferences. Tidak ada await di antara panggilan Rust. MathCAT menggunakan state thread-local, sehingga antrean actor saja tidak digunakan sebagai jaminan thread affinity.

Preferences: Language=id, SpeechStyle=ClearSpeak, Verbosity=Medium, TTS=None, DecimalSeparator/DecimalSeparators=koma, BlockSeparators=titik/NBSP/NNBSP. Bahasa/style diverifikasi setelah eksekusi; rules `Languages/id/ClearSpeak_Rules.yaml` wajib ada. Raw MathML, canonical MathML, spoken, effective profile dan version disimpan per formula. Tidak ada converter speech aturan sendiri, audio atau TTS. Hasil ClearSpeak bukan otomatis Handbook compliance atau penilaian guru.

Seluruh Rules bawaan 0.7.5 dibundel sebagai folder `MathCATRules` (struktur direktori dipertahankan). C ABI mengembalikan JSON UTF-8 milik Rust; Swift membebaskannya sekali lewat `metra_mathcat_free`. Rust panic ditangkap pada batas FFI. Worker serial mencegah state formula tertukar.

Sumber: [MathCAT](https://github.com/daisy/MathCAT), [API pemanggil](https://daisy.github.io/MathCAT/callers.html), [paket rilis 0.7.5](https://crates.io/crates/mathcat/0.7.5).
