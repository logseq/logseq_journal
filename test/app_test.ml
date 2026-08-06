module ID = Bonsai_flutter_spec.Id
module Test = Bonsai_flutter_test

let require_visible handle text =
  match Test.Handle.find handle (Test.Query.visible_text text) with
  | Some _ -> ()
  | None ->
    failwith
      (Printf.sprintf "expected visible text: %s\n%s" text (Test.Handle.show handle))
;;

let () =
  let time_source = Bonsai.Time_source.create ~start:Core.Time_ns.epoch in
  let handle =
    Test.Handle.create
      ~runtime_epoch:(ID.Runtime.Epoch.of_int64 901L)
      ~time_source
      Application.component
  in
  require_visible handle "Today";
  require_visible handle "Thursday, August 6";
  require_visible handle "Ship OCaml-first tooling";
  require_visible handle "Sketch the journal feed";
  Test.Handle.present handle;
  Test.Handle.click handle (Test.Query.test_id "quick-capture");
  require_visible handle "New journal block";
  Test.Handle.present handle;
  Test.Handle.click handle (Test.Query.test_id "toggle-1");
  require_visible handle "✓ Ship OCaml-first tooling";
  Test.Handle.present handle;
  Test.Handle.click handle (Test.Query.test_id "toggle-1");
  require_visible handle "Ship OCaml-first tooling";
  Test.Handle.shutdown handle
;;
