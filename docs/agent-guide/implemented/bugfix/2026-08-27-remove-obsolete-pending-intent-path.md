# Remove Obsolete Pending Intent Path

## Problem

Managed mirrors created by an obsolete build can retain
`pending-intents-v1.json`. The current pending store rejects that file before it
looks for `pending-intents-v2.json`, so otherwise valid encrypted mirrors cannot
start. The macOS app remains on `The graph storage is corrupt or incomplete.` and
Retry repeats the same failure.

The old pending representation is outside the current data contract. Preserving or
migrating it would add backward compatibility that the project explicitly rejects.

## Decision

Delete `pending-intents-v1.json` during current pending-store startup without reading
or converting its contents, then open only `pending-intents-v2.json`. Treat failure
to remove the obsolete path as a storage error. Keep current v2 validation strict:
malformed or unsafe v2 data must still fail closed.

The user explicitly permits cleanup of old data. This decision applies only to the
obsolete pending-intent artifact and does not weaken graph, sync checkpoint, or
ownership validation.

## Alternatives considered

### Migrate v1 entries to v2

Rejected because it preserves an obsolete format and requires compatibility logic.

### Ignore the obsolete file without deleting it

Rejected because the unsupported artifact would remain indefinitely and continue to
confuse diagnostics and future maintenance.

### Reset the entire local mirror

Rejected as the default because deleting one obsolete pending artifact is sufficient;
discarding the current SQLite mirror would force an unnecessary snapshot download.

## Acceptance criteria

- Opening a mirror with only `pending-intents-v1.json` deletes the obsolete file and
  returns an empty current pending store.
- A valid `pending-intents-v2.json` remains authoritative and is loaded normally even
  when an obsolete file is also present.
- A malformed current v2 file still fails with `corruptStorage` and releases graph
  ownership.
- The real macOS app cold-starts the selected encrypted graph and presents Timeline.
- The compiled macOS E2E test passes.

## Validation

The focused pending-store and Engine regressions pass. The compiled macOS E2E
fixture deletes an injected obsolete file, opens its encrypted mirror, and presents
Timeline before network recovery. The signed macOS RunnerTests pass, as do the full
OCaml build and test suites, Flutter analyze and tests, and the Release macOS build.

The Release app was also launched against the retained real encrypted mirror. It
presented the existing Timeline, removed the real `pending-intents-v1.json`, and
released every graph handle and ownership lock during normal termination.

## Consequences

- Any unsynchronized intent stored only in v1 is intentionally discarded.
- Cleanup failure prevents startup until the local cache can be reset safely.

## Questions

- None. The user explicitly permits deleting old data and rejects old-format
  compatibility.
