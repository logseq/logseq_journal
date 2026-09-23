import LUIAppleBackend

/// OCaml icon properties carry SF Symbol names slugged to `app:<slug>`
/// (dots replaced by dashes) — this table resolves each slug back to its
/// system symbol name. Keep in sync with `journal_icon_name` call sites.
let journalIconNames: [String] = [
    "arrow.clockwise",
    "arrow.up",
    "book",
    "calendar",
    "checkmark.circle",
    "checkmark.square",
    "chevron.down",
    "chevron.left",
    "chevron.right",
    "circle",
    "circle.fill",
    "clock",
    "doc",
    "doc.text",
    "exclamationmark.circle",
    "exclamationmark.triangle",
    "folder",
    "lock.doc",
    "lock.shield",
    "minus.circle",
    "person.crop.circle",
    "plus",
    "questionmark.folder",
    "square.and.pencil",
    "star",
    "trash",
]

let journalAppIcons: [String: LUIAppleIconSource] = Dictionary(
    uniqueKeysWithValues: journalIconNames.map { name in
        (name.replacingOccurrences(of: ".", with: "-"), .systemName(name))
    }
)
