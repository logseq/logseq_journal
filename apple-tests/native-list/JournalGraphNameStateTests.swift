import Foundation

@main struct JournalGraphNameStateTests {
  static func main() {
    var state = JournalGraphNameFeedback()
    state.show(source: "account:A:1", target: "account:B:2", name: "Work — 工作笔记")
    let preview = state.presentation!
    precondition(preview.name == "Work — 工作笔记" && preview.phase == .preview)
    state.focusChanged("account:B:2")
    precondition(state.presentation == nil, "An uncommitted external focus is not a successful swipe")
    state.show(source: "A", target: "B", name: "Work")
    state.commit(source: "A", target: "C")
    precondition(state.presentation?.phase == .preview, "Wrong target cannot confirm a request")
    state.commit(source: "A", target: "B")
    precondition(state.presentation?.phase == .waiting)
    state.focusChanged("A")
    precondition(state.presentation?.phase == .waiting, "Save may defer focus without a timeout")
    let waitingID = state.presentation!.id
    state.focusChanged("B")
    let confirmed = state.presentation!
    precondition(confirmed.phase == .confirmed && confirmed.id != waitingID)
    state.show(source: "B", target: "C", name: "Reading")
    state.dismiss(confirmed.id)
    precondition(state.presentation?.name == "Reading", "An earlier fade must not hide the next swipe")
    state.cancel()
    state.focusChanged("C")
    precondition(state.presentation == nil, "Cancellation rejects a late focus")
    state.show(source: "A", target: "B", name: "Work")
    state.commit(source: "A", target: "B")
    state.focusChanged("C")
    precondition(state.presentation == nil, "External selection clears a pending target")
    state.show(source: "A:1", target: "B:1", name: "Work")
    state.retain(["A:1", "B:2"])
    precondition(state.presentation == nil, "Retired graph generations cannot retain a name")
    for name: String? in [nil, "", " \n "] {
      state.show(source: "A", target: "B", name: name)
      precondition(state.presentation == nil, "Missing names must never reveal graph IDs")
    }
    state.show(source: "A", target: "B", name: "Work")
    state.updateName(target: "C", name: "Other")
    precondition(state.presentation?.name == "Work")
    state.updateName(target: "B", name: "Renamed work")
    precondition(state.presentation?.name == "Renamed work")
    state.commit(source: "A", target: "B")
    state.focusChanged("B")
    state.dismiss(state.presentation!.id)
    precondition(state.presentation == nil)
    state.show(source: "A", target: "B", name: "Work")
    state.retain([])
    precondition(state.presentation == nil, "Account exit clears a visible name")
    print("PASS graph-name feedback lifecycle")
  }
}
