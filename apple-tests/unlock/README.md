# Unlock layout preview

`JournalUnlockPreview.swift` hosts the native Form reference layout with
standard SwiftUI controls and disposable local state. It never accesses an
account, graph store or E2EE service. Enter only synthetic text. Submitting always
shows a sample error; Choose another graph resets preview state.

This is visual acceptance, not another authentication regression test. Application
ownership remains covered by `test_native_unlock_recovery` in
`test/macos_application_dispatch_test.ml`. Native secure-field focus admission has
its regression in the bonsai-ui SDK. The preview cannot establish correctness of
the OCaml bridge or physical iPhone keyboard behavior.

Build the macOS preview from the repository root:

```sh
xcrun swiftc -swift-version 6 \
  apple-tests/unlock/JournalUnlockPreview.swift -o /tmp/journal-unlock-preview
/tmp/journal-unlock-preview
```

The same two source files compile in an iOS simulator SwiftUI application. There
are no package dependencies. Pass any of these launch arguments for visual review:

- `--dark`: dark appearance.
- `--long`: a long multilingual graph name and recovery message.
- `--error`: initial failure feedback.
- `--large`: accessibility3 Dynamic Type (iOS).
- `--keyboard`: initially focus the preview's secure field.
- `--bottom`: initially show the bottom of overflowing scroll content.
- `--rtl`: right-to-left layout direction.

Inspect regular narrow and wide windows, keyboard-visible content, dark errors,
and the top and bottom of large-text content. Platform-specific font metrics and
native control implementations differ; macOS does not substitute for iOS review.

Production unlock acceptance uses the isolated full-runtime host in `../warm-start/`; this reference preview does not replace production interaction checks.
