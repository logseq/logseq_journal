(lang 2)

(app
 (name logseq_journal)
 (flutter_root flutter)
 (native_target app/native_embed.exe.o)
 (features sqlite)
 (host
  (mode custom)
  (main lib/main.dart))
 (macos
  (minimum_version 26.0)
  (architectures arm64))
 (ios
  (minimum_version 15.0)
  (architectures arm64)))
