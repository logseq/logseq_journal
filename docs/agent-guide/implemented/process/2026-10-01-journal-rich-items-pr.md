# Journal rich items draft PR

## Problem

The locally reviewed rich Journal rows and Ready-delivery fix currently sit on a combined base that also contains PR 35, which targets a different branch and is absent from main. Publishing that history would mix an unrelated loading transition into the feature PR.

## Decision

Preserve the complete current local history in a backup branch. Move only the three rich-row, validation, and Ready-fix commits onto freshly fetched official main, retaining the requested branch name. Resolve conflicts without introducing PR 35. Remove machine-specific fallback tooling from the public patch, write portable review evidence, and include only explicitly synthetic screenshots. Verify affected tests and builds, push without force, create a draft PR targeting main, and monitor checks through a terminal result or an explicit external blocker.

## Alternatives considered

### Stack onto PR 35

Not needed if the isolated row implementation builds against main. It would complicate review and couple unrelated UI work.

### Publish the combined merge history

Would expose unrelated Swift loading changes in the main-targeted PR.

## Consequences

The independent draft PR is published directly against main. Original combined-base commits remain on a local backup branch; public images contain only synthetic examples. Draft mode intentionally leaves the WIP app gate in progress. There are no configured Actions workflows or build/test CI runs to wait for.

## Acceptance criteria

- Original local commits remain reachable from a backup branch.
- The PR diff contains the rich-row feature and asset-notification fix only; no PR 35 Swift/loading changes.
- No user graph screenshots, private notes, credentials, or machine-specific relinking script are published.
- Affected checks run after synchronization; existing failures and limitations remain explicit.
- GitHub head matches the published local commit, draft PR targets main, and checks are monitored.

## Risks

- Rebased commits receive new IDs; the original IDs remain available locally.
- No repository workflow may be configured. Report absent checks honestly rather than asserting CI passed.

## Questions

All required publication choices are answered: the user explicitly asked to create the PR, and the delegated scope specifies a draft PR, no merge, no physical-device installation, no force push, and current upstream verification before edit rounds.

## Evidence

Draft PR: https://github.com/logseq/logseq_journal/pull/36. The first published head a6d73585b05695ffcf0b6758e580d1737de8ef1e matched GitHub exactly. The main-targeted diff excludes PR 35 and publishes only two explicitly synthetic screenshots. Full workspace build and native iOS Simulator compilation/linking pass after rebase; full runtest was rerun and reports only the pre-existing V.progress assertion mismatch. The eight service checks and protocol checks pass. The existing invalid bottom-lui-capsules decision remains unchanged.

GitHub reports zero Actions workflows, zero workflow runs, and zero commit statuses. Its only check is WIP, whose output says draft mode override and explains that the pull request is in draft mode and will not be merged. This is a deliberate draft gate, not a running build. The user's requested draft state is preserved; no merge or physical-device installation occurs.
