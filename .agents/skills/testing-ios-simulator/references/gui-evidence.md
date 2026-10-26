# GUI evidence and delivery

## Choose the surface

Use the current production UI for claims about layout, controls, navigation and visible state. Seed synthetic content through an existing public fixture boundary in a disposable host/container. Keep private graphs, credentials, generated SQLite data, screenshots and manifests outside Git.

Existing helpers may reduce setup when they cover the requested surface:

| Helper (from repository root) | Evidence and limits |
| --- | --- |
| `python3 .agents/skills/journal-build/scripts/build_authentication_probe.py` | Disposable Simulator host of production authentication views with probe actions; proves that view's visible states, not live authentication or the whole application. |
| `python3 tool/test_swiftui_warm_start.py --help` | Inspect fixture options first. The host uses synthetic encrypted graph data, memory-only secrets and blocked network authentication; supply a current native object matching the chosen target. |
| `tool/test_swiftui_editor.py`, `tool/test_swiftui_outline.py` | Scoped native probes; inspect their inputs and host behavior before choosing them. A stub without the real object cannot establish runtime acceptance. |

Probe helpers use distinct bundle IDs and external temporary hosts. Read their source/options before execution: some build immediately and do not implement `--help`. They may resolve dependencies or need a prepared toolchain; inspect those prerequisites before a run. Do not restamp a host object manually to fit a Simulator probe.

Keep the production view tree, reducers and user actions intact for the behavior under test. Label a static mock or altered presentation as a mock/diagnostic result. A screenshot of a hand-drawn approximation is not application evidence. Compare the relevant states (for example initial, error and recovery) and record the action that reached each state; inspect the actual image for clipping, unreadable text and missing controls.

## Check delivery early

Before spending time on a matrix of screenshots, capture one representative frame and open it. Check the requested channel's present capabilities with that small artifact. Keep local generation, remote upload and remote readback as separate outcomes:

- Local: record file path, dimensions and SHA-256; confirm the image opens and contains the intended UI.
- Upload: when authorized, use the channel's supported upload flow and retain the returned artifact identity. A local path or an upload request alone does not prove the file arrived.
- Readback: reopen/read the returned artifact and verify its content. Report unavailable readback honestly; do not claim verified delivery.

Tool availability can change. If a Library upload preparation step or another required tool is unavailable or denied, record the exact action, target, reason and status. Continue permitted local work and provide the local artifact when useful. Do not switch endpoints, credentials, tools or paths to bypass a restricted flow, and do not turn a temporary outage into a permanent repository rule.

## Handoff

Record the intended operation/target, final HEAD SHA plus local diff identity, manifest and app hash, SDK/Simulator/UDID, fixture provenance, actions, observed results and image/log hashes. State separately whether a full App, scoped probe, Simulator or real device was exercised. Include delivery stage, remaining blockers and the existing authorization boundary; do not store account identifiers, secrets, private graph data or task-specific machine paths in repository guidance.
