# Journal rich items draft PR

## Problem

The locally reviewed rich Journal rows and Ready-delivery fix currently sit on a combined base that also contains PR 35, which targets a different branch and is absent from main. Publishing that history would mix an unrelated loading transition into the feature PR.

## Proposal

Preserve the complete current local history in a backup branch. Move only the three rich-row, validation, and Ready-fix commits onto freshly fetched official main, retaining the requested branch name. Resolve conflicts without introducing PR 35. Remove machine-specific fallback tooling from the public patch, write portable review evidence, and include only explicitly synthetic screenshots. Verify affected tests and builds, push without force, create a draft PR targeting main, and monitor checks through a terminal result or an explicit external blocker.

## Alternatives considered

### Stack onto PR 35

Not needed if the isolated row implementation builds against main. It would complicate review and couple unrelated UI work.

### Publish the combined merge history

Would expose unrelated Swift loading changes in the main-targeted PR.

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
