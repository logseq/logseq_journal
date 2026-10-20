# Non-Transit assets in encrypted graphs

The user authorized reading non-Transit attachments in encrypted DB graphs
through the existing plaintext asset path. This standalone change ports that
behavior onto main without the separate asset-diagnostic carrier, shape scanner,
format hints, response-header evidence or typed failure-channel changes.

The public asset codec owns response-byte classification; pure reducer events
contain no response bytes and cannot reproduce this boundary. A bounded lexical
check reserves JSON containers, strings, number starts and complete/incomplete
literal candidates for the existing bounded envelope validator. Leading
whitespace or BOM cannot disguise such a candidate. Clear non-Transit bytes use
the unchanged common plaintext maximum-length and SHA-256 checks, then the
unchanged safe cache publication. JSON-looking raw files remain conservative.

Malformed/truncated candidates, invalid envelope types/IV/ciphertext, parser
errors, AES authentication failures, crypto exceptions and decrypted-checksum
failures never become raw-file signals. A matching raw-response checksum does
not bypass these failures. No catch-all fallback is added. The sole new log is
the fixed text `journal asset decode path=raw-fallback`, which identifies path
selection before validation and contains no content, identity, hash or secret.

Public codec regressions cover binary/text/empty raw success, raw limits and
checksum failures, unchanged valid encryption, malformed/truncated envelopes,
wrong-key/auth/crypto-exception/decrypted-checksum failures using matching raw
checksums, whitespace/BOM boundaries and hostile nesting. They are first run
against main before implementation, then against the standalone final source.
Existing Runner/cache regressions continue to cover unchanged publication.

Build57 (0d05d1a951f5ccf3ea2c1053401e9629c67be712) was installed and launched on
the iPhone, but includes additional diagnostic work. That is not device
acceptance of this standalone PR head, nor proof of successful re-download of
the originally failed asset. Actual 56051-byte incident content remains unknown.
No device operation or Apple build is needed for this PR split. No graph flag,
key ownership, upload, HTTP, retry, cache policy, spec, Dune or dependency changes.
Temporary validation and review evidence stays outside the repository.

`spec-dev-tool` is unavailable on this Mac; no automated document-schema
validation is claimed.
