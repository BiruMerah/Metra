# MathCAT native iOS bridge

Library, header, bridge Rust, Cargo.lock dan lisensi di folder ini disalin dari PoC build 29. Build Metra memakai binary `lib/ios-arm64/libmetra_mathcat.a` yang sudah tersedia; tidak memerlukan direktori `target` atau Rust pada iPhone. Instruksi build source di bawah merujuk workspace PoC asal (`../Approach-Latest-Metra` dari root repo Metra), bukan tool yang dibundel di repo ini.

MathCAT **0.7.5** dari arsip rilis crates.io, tanpa perubahan aturan pembacaan. Source di `../../tools/mathcat-build/source/mathcat-0.7.5`, lisensi MIT di `LICENSE-MathCAT`. `Cargo.lock`, checksum arsip/library dalam `verification/mathcat-native-sha256.txt`, dan `rust-version.txt` mencatat build aktual. Rust 1.99.1, target `aarch64-apple-ios`, deployment iOS 17. Library release statis dibundel; tidak memerlukan Rust/Python/Node pada iPhone. Target simulator belum dipaketkan.

```sh
tools/mathcat-build/build-ios.sh
```

Toolchain disimpan dalam `.cargo`/`.rustup` milik folder persiapan baru. Profil shell dan instalasi eksperimen lama tidak diubah. Link app memakai `lib/ios-arm64/libmetra_mathcat.a`, header C di `include/`.

`metra_mathcat_convert` mengeksekusi seluruh transaksi pada **satu thread OS tetap** yang dimiliki Swift `MathCATAdapter`: set rules directory → set semua preferences → set MathML → get spoken → get effective preferences. Tidak ada await di antara panggilan Rust. MathCAT menggunakan state thread-local, sehingga antrean actor saja tidak digunakan sebagai jaminan thread affinity.

Preferences: Language=id, SpeechStyle=SimpleSpeak, Verbosity=Medium, TTS=None, DecimalSeparator/DecimalSeparators=koma, BlockSeparators=titik/NBSP/NNBSP. Bahasa/style diverifikasi setelah eksekusi; rules `Languages/id/SimpleSpeak_Rules.yaml` wajib ada. Raw MathML, canonical MathML, spoken, effective profile dan version disimpan per formula. Tidak ada converter speech aturan sendiri, audio atau TTS. Hasil SimpleSpeak bukan otomatis Handbook compliance atau penilaian guru.

Seluruh Rules bawaan 0.7.5 dibundel sebagai folder `MathCATRules` (struktur direktori dipertahankan). C ABI mengembalikan JSON UTF-8 milik Rust; Swift membebaskannya sekali lewat `metra_mathcat_free`. Rust panic ditangkap pada batas FFI. Worker serial mencegah state formula tertukar.

Sumber: [MathCAT](https://github.com/daisy/MathCAT), [API pemanggil](https://daisy.github.io/MathCAT/callers.html), [paket rilis 0.7.5](https://crates.io/crates/mathcat/0.7.5).
