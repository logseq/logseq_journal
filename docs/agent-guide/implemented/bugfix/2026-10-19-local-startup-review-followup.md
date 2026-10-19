# Local startup review followup

## Problem

PR 97 at cd25b81 had four confirmed recovery defects: a revoked native retry left a continuation suspended, offline graph deletion was enabled but silently rejected, failed local account reads were treated as account absence, and authenticated catalog refresh ran before native permission was restored.

## Decision

Reject revoked-scope retries before storing a continuation. Disable offline deletion with a connection explanation. Distinguish Account_error from confirmed absent local accounts so the existing Account_failure and Startup_retry path repeats local discovery. The native binding-read banner retains its diagnostic and sign-in action but omits the unrelated online Retry. The picker root comparison includes authenticated because that field now determines its deletion explanation as well as enabled state.

A catalog refresh that changes Local_only to Online_by_user publishes the phase and temporarily clears online authentication. The existing native onlineRequested response refreshes authentication, and its Account_authenticated round-trip admits the catalog request. Clearing the old online-authentication fact also prevents repeated Refresh clicks from bypassing that handshake. Already-online refresh remains direct.

The delegated implementation request explicitly authorized these four narrow fixes. No spec interface or dune file changed.

## Alternatives considered

### Grant permission before every worker request

Dispatching native and worker requests without an acknowledgement can still race. Reuse the existing permission and authenticated identity handshake.

### Add a new local-account wire event

Existing Account_error, Account_failure and Startup_retry already represent local discovery recovery. A new interface is unnecessary.

## Consequences

The pure Sync owner reproduces the catalog race through local attachment, Timeline_presented, Account_authenticated and Graph_selected events. Its regression covers first and repeated refresh before permission and normal fetch after confirmed identity. The native ApplicationPlatform continuation and mounted Application controls own the other defects; their tests use public owner methods, the runtime delivery port, platform request failures, menu state and actual Retry events.

Each regression was observed failing for product behavior before its fix. Test evidence lives outside this repository in the task's evidence/fix97 directory. The native platform-services suite and all 80 pure-core cases pass. All 125 mounted Application tests pass for the initial four fixes. An additional public picker fixture changes only authenticated and covers explanation removal and restoration across both directions. The mounted local-account regression confirms Retry reissues local discovery without online permission; the graph-picker group covers disabled state and explanation alongside existing authenticated operations.

The catalog handshake depends on the existing native identity result. Authentication failure retains the local graph and uses existing account recovery. Host regressions do not establish iPhone ABI or remote service acceptance. Full spec-dev-tool validation reports four pre-existing historical document format errors; the new decision document validates independently.
