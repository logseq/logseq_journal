# Upgrade Journal to current DataScript and LUI

## Problem

Journal uses an old LUI revision whose host protocol differs from current upstream. Latest Journal main pins DataScript before the new recursive-rule precheck fix.

## Proposal

Honor the explicit upgrade request: upgrade DataScript to 0561660e4894faee250d551ab2a32a6b5c25a5fb and upgrade LUI to 23b7563c21aa17e0f59da6527ee0127de8c1f0b6. Align installation manifests and boundary assertions, adapt public calls, and validate native behavior using disposable fixtures. Build dependencies in a task-local overlay using the existing read-only compiler switch.

## Alternatives considered

### Keep the old LUI revision

Rejected because the user requested current upstream main and a completed adaptation.

## Acceptance criteria

- All applicable installation manifests and boundary assertions use the verified exact revisions.
- Full build and forced regression checks pass against those dependencies.
- Native navigation, Capture, sheets, menus, list updates, and media paths are checked in an isolated Simulator container; failures and limits are reported precisely.
- Independent review and a local commit are delivered.

## Risks

- Host enum, bridge lifetime, event and runtime changes can affect native behavior even when compilation succeeds.
- Historical UI issues must be distinguished from upgrade regressions.
- Dune and spec OCaml changes require separate explicit approval if found necessary.

## Authorization

The delegation explicitly requests implementation on current main, exact dependency SHAs, local commits, independent review, isolated Simulator testing, and no push, PR, merge, or phone installation. No unanswered design choice is required to begin this scope.
