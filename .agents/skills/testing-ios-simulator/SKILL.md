---
name: testing-ios-simulator
description: Validate Journal UI on iOS Simulator, capture screenshots and use isolated synthetic GUI fixtures.
---

# Journal Simulator and GUI evidence

Use [journal-build](../journal-build/SKILL.md) for builds, target inputs and signing. A `--link-only` stub proves packaging/linking only. Host-restamped runtime builds stay experimental with `cross_abi_validated=false`; Simulator success does not establish real-device ABI or runtime acceptance. Do not revive legacy bonsai-swiftui commands, raw object injection or manual restamping.

Before a long GUI run, read [GUI evidence and delivery](references/gui-evidence.md). Select the smallest real UI surface that answers the request, confirm an owned target and synthetic data, and check that one screenshot can be captured, opened and delivered through the currently supported channel. Separate this delivery check from application acceptance.

## Drive an identified target

Use an explicit Simulator UDID, app path and bundle identifier from the selected build/probe manifest. Observe current UI/accessibility state before interacting; fixed coordinates and old menu layouts are not reliable selectors.

```sh
xcrun simctl list devices booted
xcrun simctl install "$SIM_UDID" "$APP_PATH"
xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID"
xcrun simctl io "$SIM_UDID" screenshot "$EVIDENCE_DIR/screen.png"
xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data
```

Run install/launch only within the task's existing authorization. Re-resolve the container after installation. Do not erase a shared simulator, remove a mirror, clear caches, sign out or mutate a graph as troubleshooting without matching authorization. Use existing secure sign-in/unlock handling only when a live account/graph test is requested; never infer graph identity from list position or ciphertext names.

## Diagnose the observed failure

Capture the failing action, console, current source/dependency revision, SDK/device, build manifest and a fresh screenshot. For launch diagnostics, use `xcrun simctl launch --console-pty "$SIM_UDID" "$BUNDLE_ID"` with output in external evidence; set launch environment through `SIMCTL_CHILD_<NAME>`, not trailing `KEY=VALUE` arguments. Logs may contain private data: inspect and redact before delivery.

Distinguish launch/signing failure, idle waiting, busy render loops and missing view content using current logs, repeated CPU observations and, when useful, a process sample. Historical keychain, sheet, row-action or wakeup bugs are hypotheses to reproduce on the current pin, not permanent exceptions or accepted regressions. Do not render sheets inline or patch production presentation to claim GUI acceptance. A minimal probe can isolate a cause, with its changed behavior and limits reported separately.

For transient UI, retain real transition logs alongside screenshots. Logs prove events, not pixels. Keep instrumentation and generated hosts external; if a source probe is necessary, preserve existing edits and remove only the probe's own changes before final-source verification.
