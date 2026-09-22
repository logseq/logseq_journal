module Ui = Bonsai_swiftui_ui
module V = Ui.View

let component _handlers graph =
  let observed, set_observed = Bonsai_v017.state ~equal:String.equal "No action" graph in
  let expanded, set_expanded = Bonsai_v017.state ~equal:Bool.equal true graph in
  let state =
    Bonsai.Cont.map2 observed set_observed ~f:(fun observed set_observed ->
      observed, set_observed)
  in
  let expansion =
    Bonsai.Cont.map2 expanded set_expanded ~f:(fun expanded set_expanded ->
      expanded, set_expanded)
  in
  Bonsai.Cont.map2
    state
    expansion
    ~f:(fun (observed, set_observed) (expanded, set_expanded) ->
      let action name =
        Ui.Event.Handler.create (fun _ ->
          Bonsai.Effect.Expert.handle (set_observed (fun _ -> name)))
      in
      let row id label =
        V.Native_list.row
          ~key:(Ui.Key.string id)
          ~separator:Hidden
          ~context_menu:
            (V.Context_menu.create
               ~actions:
                 [ V.Context_menu.action
                     ~key:(Ui.Key.string "delete")
                     ~role:Destructive
                     ~title:"Delete"
                     ~on_press:(action ("delete:" ^ id))
                     ()
                 ]
               ())
          (V.text label)
      in
      let outline =
        V.Native_list.vertical
          ~key:(Ui.Key.string "outline")
          ~style:Plain
          [ V.Native_list.section
              ~key:(Ui.Key.string "rows")
              ~separator:Hidden
              [ V.Native_list.disclosure_row
                  ~key:(Ui.Key.string "parent")
                  ~expanded
                  ~on_expanded_changed:
                    (Ui.Event.Handler.create (function
                       | Ui.Event.Payload.Bool value ->
                         Bonsai.Effect.Expert.handle (set_expanded (fun _ -> value))
                       | _ -> ()))
                  ~label:(V.text "Parent row")
                  [ row "child" "Child row"; row "branch" "Unloaded branch row" ]
              ; row "sibling" "Sibling row"
              ]
          ]
      in
      App.View.create
        ~theme:(Ui.Theme.create ())
        ~body:
          (V.Body.Vertical.create
             [ V.Body.Vertical.fixed (V.text ("Observed: " ^ observed))
             ; V.Body.Vertical.fill outline
             ]))
;;

let app = App.create ~name:"Outline action probe" component
