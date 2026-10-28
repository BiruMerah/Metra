# MathCAT ClearSpeak Indonesia

Pembaruan 28 Oktober 2026 mengganti profil aktif dari SimpleSpeak ke **ClearSpeak**, dengan MathCAT tetap versi **0.7.5**, bahasa `id`, verbosity `Medium`, dan `TTS=None`. Library Rust arm64 iOS dibangun ulang dari bridge repo ini; pengecekan rules Swift/Rust, effective profile, metadata run, manifest model dan hash library mengikuti profil baru. Rules bawaan MathCAT tidak diubah.

Bangun ulang library melalui `bash Tools/build-mathcat-ios.sh /path/to/mathcat-0.7.5`; dependency mengikuti `Cargo.lock`. Script memakai staging di `.build/` dan tidak mengubah source atau hasil PoC asal. Detail toolchain ada di `Libraries/MathCATNative/README.md`.

## Verifikasi

- Library release `aarch64-apple-ios` berhasil dibangun, dengan arsitektur arm64.
- Aplikasi berhasil dibangun dengan Xcode 27, SDK iPhoneOS, Debug, `CODE_SIGNING_ALLOWED=NO`.
- Bridge C ABI yang sama dibangun untuk macOS dan dijalankan dengan rules yang dibundel: enam kasus pecahan sederhana/majemuk, pangkat, akar bersarang, desimal koma dan derajat menghasilkan teks serta effective profile ClearSpeak yang benar.
- Pecahan `(x+1)/2` menghasilkan `pecahan dengan pembilang; x tambah 1; dan penyebut 2`. Panggilan berulang pada thread yang sama menghasilkan teks identik.
- Folder yang hanya menyediakan rules SimpleSpeak ditolak dengan error ClearSpeak rules missing.

Keluaran dan hash ada di [clearspeak-results.json](clearspeak-results.json). Peringatan compiler Rust berasal dari source MathCAT 0.7.5; build Xcode hanya melaporkan metadata AppIntents dilewati karena framework tersebut tidak dipakai.

Pengecekan bridge dijalankan di Mac; tidak ada inference OCR/model, runtime iPhone atau uji pemahaman VoiceOver baru. Bukti perangkat SimpleSpeak sebelumnya disimpan di `previous_profile_device_evidence` pada manifest agar tidak dianggap bukti ClearSpeak.

Ekstraksi baru memakai ClearSpeak. Materi tersimpan memakai spoken hasil run asal; impor ulang untuk menghasilkan spoken dengan profil baru.
