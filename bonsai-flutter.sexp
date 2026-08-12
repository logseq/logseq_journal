(lang 2)

(app
 (name logseq_journal)
 (flutter_root flutter)
 (native_target app/native_embed.exe.o)
 (features sqlite)
 (host
  (mode managed_adapter)
  (adapter lib/application_host_adapter.dart)
  (entrypoint logseq_journal)
  (launch_policy replace_existing))
 (macos
  (minimum_version 26.0)
  (architectures arm64))
 (ios
  (minimum_version 15.0)
  (architectures arm64)))
