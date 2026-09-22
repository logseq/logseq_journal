module Ui = Bonsai_swiftui_ui
module V = Ui.View
module Composer = Ui.Native_widget.Expandable_message_composer

(* The production Journal handler depends on state. The environment switch
   provides a stable-handler control without changing the native component. *)
let component handlers graph =
  let text, set_text = Bonsai_v017.state ~equal:String.equal "" graph in
  let dependencies = Bonsai.Cont.map2 text set_text ~f:(fun text set -> text, set) in
  let rebind = Sys.getenv_opt "JOURNAL_PROBE_REBIND" <> Some "0" in
  let on_event =
    Driver.Handler.create
      handlers
      ~name:"composer-input"
      ~equal:(fun (left, left_set) (right, right_set) ->
        left_set == right_set && ((not rebind) || String.equal left right))
      dependencies
      ~f:(fun (_, set) payload ->
        match Composer.event_of_payload payload with
        | Some (Text_changed text) -> set (fun _ -> text)
        | Some (Button_pressed { text; _ }) -> set (fun _ -> "Saved: " ^ text)
        | None -> Bonsai.Effect.Ignore)
  in
  Bonsai.Cont.map2 text on_event ~f:(fun text on_event ->
    let composer =
      Composer.create_with_handler
        ~key:(Ui.Key.string "stable-composer")
        ~fab_presentation:Extended
        ~fab_label:"Capture"
        ~fab_tooltip:"Open Capture"
        ~fab_icon:(V.text "+")
        ~animation_duration_ms:0
        ~hint_text:"Type alphabet"
        ~buttons:
          [ Composer.button ~id:1 ~tooltip:"Observe save" ~child:(V.text "Save") () ]
        ~on_event
        ()
    in
    App.View.create
      ~theme:(Ui.Theme.create ())
      ~body:
        (V.Body.static
           (V.column
              ~spacing:16.
              [ V.text
                  (if rebind
                   then "Handler changes with text"
                   else "Stable handler control")
              ; V.text ("Observed: " ^ text)
              ; composer
              ])))
;;

let app = App.create ~name:"Composer input probe" component
