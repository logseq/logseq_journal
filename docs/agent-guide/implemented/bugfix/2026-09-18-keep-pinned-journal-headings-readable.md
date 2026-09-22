# Keep Pinned Journal Headings Readable

## Problem

On the current signed iPhone app, scrolling pins the date heading over body text
without an opaque content background. Batch 54 production screenshots show the
September 6 and September 4 headings superimposed on existing row text. The same
problem appears in batch 53's isolated final-root screenshots. This affects
reading content and is not the deferred separator/cosmetic work.

## Decision

Give the native Journal Section heading the system background style. Keep native
List section pinning, measurement, semantic text, visibility and navigation.
Do not introduce scroll tracking, custom geometry or a replacement header bar.
The system background follows light/dark appearance.

JournalList's native Section composition owns this defect. Journal_timeline_state
owns loaded slots and visible ranges; Application owns mounted content and route
events. Their public state does not own raster compositing or native pinned-header
layers. Exercise the existing public visibility/presentation checks, but do not
invent a bad reducer result or add a duplicate reducer regression for this native
visual defect. The actual production scroll capture is the narrowest reproduction.
Use the existing native observation workflow for this small reversible styling
change, retaining before/after screenshots rather than adding implementation-shape
or pixel-coordinate tests.

## Alternatives considered

### Replace sections or disable native pinning

Rejected: unnecessary structural change for a native content-layering defect.

### Add a custom backdrop to the entire application toolbar

Rejected: broader than the reproduced date-heading issue and would replace native
scroll-edge presentation without evidence.

## Acceptance criteria

- Retain actual production iPhone scroll screenshots reproducing overlaid text.
- Existing public timeline visibility and application presentation checks remain
  passing; they do not constitute native compositing coverage.
- Current signed production screenshots after scrolling show readable pinned
  headings with body text hidden behind their content background.
- Existing detail-return UI retention and Capture/keyboard behavior remain intact.
- Build the shared native views for iPhone and macOS; record exact source/binary
  identities and remaining visual limits. No Dune, protected spec or SDK edits.

## Risks

- Background must fill the heading's native width without hard-coded dimensions.
- The change does not fix separators or claim that all toolbar/feedback layouts
  and supported iPhone configurations are accepted.

## Consequences

Pinned date content uses a full-width semantic background, following the system
appearance without new geometry or scroll state. Native section pinning remains.
The visual repair is bounded to date readability; the recorded intermittent
row-open failure and broader device acceptance remain separate open observations.

## Questions

- None. This is within the existing core readability requirement.

## Execution evidence

The public timeline visibility suite and Application presentation/scroll-identity
suite pass before the production change. Neither has a native raster-composition
boundary and neither reproduces the observed layering. The initial concurrent
Dune invocation encountered a transient empty build-lock file; the sequential
retry passes without deleting locks or changing code.

Production iPhone scroll screenshots reproduce the unreadable date headings.
An intrinsic-width background improves the title but leaves body text alongside
it; this intermediate visual result is not accepted. The final native heading
expands to its available width before applying the system background. Production
screenshots at three scroll stops show readable dates with no body text drawn
through the heading content area. Existing scroll/pagination ownership is unchanged.

The first final-build middle-row test fails because the tapped row does not open
detail. An unchanged-code/fixture rerun completes both detail/Back cycles and
retains the original row frames. Keep the initial failure and do not claim that
its cause is fixed or established as a consequence of this styling change.
The broader acceptance ledger retains that navigation observation.

Exact build results, source hashes, visual observations and remaining limits are
recorded in the batch 54 report under the native standardization test reports.

Final iPhone/macOS builds, native viewport checks and final production Capture
keyboard/rotation/Close acceptance pass. After the read-only navigation runs,
the isolated graph's SQLite integrity is `ok` and its exact outbox is unchanged.
The bounded heading repair is implemented; the broader proposal remains open.
