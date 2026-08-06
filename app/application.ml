module Ui = Bonsai_flutter_ui

type block =
  { id : int
  ; title : string
  ; completed : bool
  }

type state =
  { next_id : int
  ; blocks : block list
  }

let equal = ( = )

let initial =
  { next_id = 3
  ; blocks =
      [ { id = 1; title = "Ship OCaml-first tooling"; completed = false }
      ; { id = 2; title = "Sketch the journal feed"; completed = false }
      ]
  }
;;

let component handlers graph =
  let state, set_state = Bonsai_v017.state ~equal initial graph in
  let quick_capture =
    Driver.Handler.create
      handlers
      ~name:"quick-capture"
      ~equal:( == )
      set_state
      ~f:(fun set_state _ ->
        set_state (fun state ->
          let block =
            { id = state.next_id; title = "New journal block"; completed = false }
          in
          { next_id = state.next_id + 1; blocks = state.blocks @ [ block ] }))
  in
  let scroll =
    Driver.Handler.create
      handlers
      ~name:"journal-scroll"
      ~equal:Unit.equal
      (Bonsai.Cont.return ())
      ~f:(fun () _ -> Bonsai.Effect.Ignore)
  in
  let blocks = Bonsai.Cont.map state ~f:(fun state -> state.blocks) in
  let rows =
    Bonsai.Cont.assoc_list
      (module Core.Int)
      blocks
      ~get_key:(fun block -> block.id)
      ~f:(fun block_id block _graph ->
        let dependencies = Bonsai.Cont.both set_state block_id in
        let equal_dependencies (left_set_state, left_id) (right_set_state, right_id) =
          left_set_state == right_set_state && Int.equal left_id right_id
        in
        let toggle =
          Driver.Handler.create
            handlers
            ~name:"toggle-block"
            ~equal:equal_dependencies
            dependencies
            ~f:(fun (set_state, block_id) _ ->
              set_state (fun state ->
                { state with
                  blocks =
                    List.map
                      (fun block ->
                         if block.id = block_id
                         then { block with completed = not block.completed }
                         else block)
                      state.blocks
                }))
        in
        Bonsai.Cont.map2 block toggle ~f:(fun block toggle ->
          let title = if block.completed then "✓ " ^ block.title else block.title in
          Ui.Material.text_button
            ~key:(Ui.Key.int block.id)
            ~on_press:toggle
            ~child:(Ui.Widget.text title)
            ()
          |> Ui.Widget.with_test_id
               (Ui.Test_id.string (Printf.sprintf "toggle-%d" block.id))
          |> Ui.Material.card ~elevation:1.))
      graph
  in
  Bonsai.Cont.map2
    rows
    (Bonsai.Cont.both quick_capture scroll)
    ~f:(fun rows (quick_capture, scroll) ->
      let rows =
        match rows with
        | `Ok rows -> rows
        | `Duplicate_key id ->
          invalid_arg (Printf.sprintf "Journal contains duplicate block ID %d" id)
      in
      let feed =
        Ui.Widget.column (Ui.Widget.text "Thursday, August 6" :: rows)
        |> fun content -> Ui.Widget.scroll_view ~on_scroll:scroll content ()
      in
      Ui.Material.scaffold
        ~app_bar:(Ui.Material.app_bar ~title:(Ui.Widget.text "Today") ())
        ~body:
          (Ui.Widget.column
             [ Ui.Material.elevated_button
                 ~on_press:quick_capture
                 ~child:(Ui.Widget.text "Quick capture")
                 ()
               |> Ui.Widget.with_test_id (Ui.Test_id.string "quick-capture")
             ; feed
             ])
        ())
;;

let app = App.create ~name:"Logseq Journal" component
