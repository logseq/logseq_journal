---
name: logseq-journal-ios-sim-testing
description: Compatibility redirect to the maintained Journal Simulator identity preflight and acceptance workflow.
---

# Journal Simulator testing — unified workflow

Read and follow [testing-ios-simulator](../testing-ios-simulator/SKILL.md) and
[journal-build](../journal-build/SKILL.md). Use
`python3 tool/capture_acceptance.py --help` from the repository root for acceptance
capture and [the evidence contract](../../../docs/acceptance-capture.md).

This legacy entry point no longer carries separate build/install/graph-selection
or database inspection recipes. Explicit device identity, graph UUID, installed
binary/source identity, shared-owner coordination and privacy checks all belong
to the unified workflow. Enable the Simulator-only runtime observer explicitly on the coordinated matching
App; `runtime-identity-unavailable` blocks acceptance if it is absent or unready.
Synthetic tests/CI do not prove real App capture integration. Never use similar graph
names, persisted selection, handwritten actual identity or direct DB/secret reads
as a substitute. Simulator host restamping does not establish phone/ABI acceptance.
