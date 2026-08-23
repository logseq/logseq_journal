# Graph Switch and Sign-Out Controls Are Unreachable

## Problem

Once a graph reaches Graph_open, the App replaces the sync manager page with the
Journal runtime and exposes no action to switch graphs or sign out.

The two header glyphs are non-interactive image widgets: their semantics nodes have
no tap action and expose only private-use glyph characters as labels. Source review
confirms that Sync_manager.Select_graph is dispatched only by graph buttons while
the manager is in Awaiting_selection. There is no action that returns an open graph
to that phase, and the host contains no Amplify.Auth.signOut call.

This makes two implemented lifecycle paths unreachable from the shipped UI:

- selecting a different authorized graph and replacing the native runtime;
- explicit sign-out while retaining cached graph mirrors and the last selection.

It also prevents normal UI testing of generation cancellation, old WebSocket
shutdown, and account-bound cache behavior.

## Decision

Add one accessible account menu reachable from the Journal header. It should
provide at least:

- Switch graph, which closes the current runtime and connection before showing the
  authorized graph picker;
- Sign out, which closes sync ownership, invokes Amplify sign-out, and returns to
  the Authenticator while retaining the non-secret catalog/mirror state defined by
  the architecture;
- the existing explicit local-cache reset action when a selected graph is eligible.

Give every control a stable semantic label, hint, test ID, and minimum hit target.
Decorative header glyphs must not imply unavailable actions.

### Implementation outcome

The Journal header now exposes one semantic `Account menu` button whenever the
managed sync session is available. Its menu contains distinct `Switch graph`,
eligible `Reset local graph copy`, `Sign out`, and dismiss actions with stable
test IDs and minimum targets. The former decorative menu/more glyphs were removed.

`Return_to_graph_picker` fences generations, cancels token/bootstrap/network work,
closes the WebSocket and engine, and returns to the retained authorized catalog.
Sign-out first reaches the worker's closed `Signed_out` phase, then invokes
`Amplify.Auth.signOut`. A host/native termination handshake reuses the same graph
cleanup boundary before shutting down the runtime. macOS testing opened the menu,
switched from an open graph to the 13-entry picker, selected entries at the bottom,
and verified ownership was released before normal termination.

## Alternatives considered

### Switch graphs only after restarting the App

Rejected because restart restores the last selected graph and never reaches
Awaiting_selection when a ready mirror exists.

### Rely on Amplify's default Authenticator UI for sign-out

Rejected because the Authenticator builder displays the child directly for a signed-
in session and provides no signed-in account surface.

### Expose lifecycle operations only through tests

Rejected because graph switching and explicit sign-out are user-facing architecture
requirements, not test-only controls.

### Give graph switching a dedicated header action

Rejected to keep the Journal header compact and provide one discoverable lifecycle
surface. Switch graph and Sign out remain distinct, clearly labeled commands inside
the shared account menu.

## Acceptance criteria

- An open graph exposes one discoverable, accessible account menu containing
  distinct Switch graph and Sign out actions.
- Switching closes the old runtime and WebSocket before opening the picker, rejects
  late messages by generation, and can open another authorized graph.
- Signing out closes graph ownership and returns to the sign-in form while retaining
  the cached mirror, catalog metadata, and last selection.
- Signing back in as the same user restores the retained mirror; a different user
  cannot inherit the previous user's selected graph or E2EE key.
- Header controls expose meaningful semantic labels instead of glyph code points.

## Consequences

- Graph replacement and sign-out are reachable through one explicit account
  surface instead of hidden lifecycle-only paths.
- Switching retains catalog and mirror state while generation fences reject late
  work from the closed graph.
- Application termination now includes a bounded OCaml cleanup handshake before
  Flutter runtime shutdown.

## Risks

- Account transitions must cancel token requests and network callbacks before
  changing the authenticated user generation.
- A graph menu must not expose remote graph deletion, which remains outside the
  first release.
- The shared menu must keep Switch graph visually distinct from the more destructive
  Sign out and local-cache reset actions to prevent accidental activation.

## Questions

- None. Graph switching and sign-out share one account menu.
