module Ui = Journal_view
module V = Ui.View

let keyed children =
  List.mapi
    (fun index child ->
       let key =
         match V.For_testing.key child, V.For_testing.test_id child with
         | Some key, _ -> key
         | None, Some id -> id
         | None, None -> string_of_int index
       in
       V.Keyed.create ~key child)
    children
;;

let form children =
  V.Form.vertical ~key:(Ui.Key.string "form") (keyed children)
  |> V.Body.Vertical.fill
  |> fun content -> V.Body.Vertical.create [ content ]
;;


let unavailable ~title ~symbol ~message ~actions =
  V.content_unavailable
    ~label:(V.label ~title:(V.text title) ~icon:(V.symbol ~name:symbol ()) ())
    ~description:(V.text message |> V.text_selection ~enabled:true)
    ~actions
    ()
;;

let section ?key title children =
  V.Section.create
    ~key:(Option.value key ~default:(Ui.Key.string title))
    ~header_text:title
    (keyed children)
;;

let labeled label content =
  V.labeled_content
    ~key:(Ui.Key.string label)
    ~label:(V.text label)
    ~value:(V.text_selection ~enabled:true content)
    ()
;;

let dismiss_toolbar ~test_id ~on_close body =
  let close =
    V.button
      ~style:Plain
      ~on_press:on_close
      ~child:(V.label ~title:(V.text "Close") ~icon:(V.symbol ~name:"xmark" ()) ())
      ()
    |> V.with_test_id (Ui.Test_id.string test_id)
  in
  V.Body.toolbar
    ~items:
      [ V.Toolbar.item ~key:(Ui.Key.string test_id) ~placement:Cancellation_action close ]
    body
;;
