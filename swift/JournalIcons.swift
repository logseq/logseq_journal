import LUIAppleBackend

/// OCaml icon properties carry SF Symbol names slugged to `app:<slug>`
/// (dots replaced by dashes) — this table resolves each slug back to its
/// system symbol name. Keep in sync with `journal_icon_name` call sites.
let journalIconNames: [String] = [
    "arrow.clockwise",
    "arrow.triangle.2.circlepath",
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
    "ellipsis",
    "exclamationmark.circle",
    "exclamationmark.triangle",
    "folder",
    "lock.doc",
    "lock.shield",
    "minus.circle",
    "person.crop.circle",
    "plus",
    "questionmark.folder",
    "rectangle.portrait.and.arrow.right",
    "slider.horizontal.3",
    "square.and.pencil",
    "star",
    "stethoscope",
    "trash",
]

let journalAppIcons: [String: LUIAppleIconSource] = Dictionary(
    uniqueKeysWithValues: journalIconNames.map { name in
        (name.replacingOccurrences(of: ".", with: "-"), .systemName(name))
    }
)
