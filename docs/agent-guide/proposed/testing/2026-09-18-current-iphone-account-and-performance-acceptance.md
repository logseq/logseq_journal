# Current iPhone Account and Performance Acceptance

## Problem

The current native iPhone build has passed navigation and Capture regressions, but live authentication, E2EE wrong-password recovery, and current-build performance require direct evidence.

## Proposal

Install the unchanged production implementation under an independent acceptance bundle identifier and product name. Its application container and default Keychain access group isolate account credentials, graph storage, and drafts from the existing production installation. The user enters credentials only on the device. Do not collect credential screenshots, accessibility dumps, or password logs. Record only user-confirmed outcomes after submission. Perform current-build fixture performance checks separately from the live account session.

## Alternatives considered

### Sign out the existing installation

Rejected because sign-out can clear existing draft and session state.

### Use the encrypted fixture host for account acceptance

Rejected because its authentication is deliberately blocked and its memory key store cannot establish live password recovery.

## Acceptance criteria

- Verify signed application identifiers and separate default Keychain access groups before installation.
- Record the actual live login and verification steps encountered, without claiming unencountered challenge variants.
- Record incorrect E2EE password feedback followed by successful retry, including keyboard stability.
- Record current-build performance measurements with verified trace coverage, or state the specific remaining evidence gap.
- Preserve the existing production installation and user data.

## Risks

- The provider may not request a verification code for this account; only encountered paths can be accepted.
- Live credentials and graph data must remain on the device.
- Fixture bootstrap work can distort launch timings and must be distinguished from production startup.

## Questions

None. The user has authorized iPhone acceptance and is available for credential entry.
