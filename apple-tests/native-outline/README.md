# Native outline action ownership probe

Run `python3 tool/test_swiftui_outline.py`, then open the printed macOS app.
The host registers the actual `swift/JournalOutline.swift`; it does not duplicate
DisclosureGroup or action implementation. Four fixed native child views cover an
expanded parent, a leaf child, an unloaded child branch and a sibling root.

Invoke the exposed native Delete action and context menu on each row. The
`Observed` label must contain `"action":"delete"` with that exact row's ID:
`parent`, `child`, `branch` or `sibling`. No database is opened and no deletion
occurs. Invoke the parent disclosure action separately; it must emit `expanded`
for `parent`, never `delete`. The fixture displays events without applying them,
so it deliberately keeps the hierarchy fixed across observations.

This tests the native production action owner. Application/detail reducers
receive an already selected block ID and cannot reproduce native inherited
parent actions without injecting the wrong external result. Do not add duplicate
reducer, storage or transport tests for this targeting defect.

macOS observations do not establish UIKit swipe targeting or spoken VoiceOver
behavior. Run the real iPhone flow when a device becomes available.
