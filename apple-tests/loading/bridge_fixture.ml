let signal = ref 0

let () =
  Callback.register "lui_ocaml_init" (fun _platform _host _payload -> "initial-patch");
  Callback.register "journal_ocaml_loading_signal" (fun () -> !signal);
  Callback.register "journal_ocaml_pump" (fun () ->
    signal := 1;
    "ready-patch");
  Callback.register "lui_ocaml_dispose" (fun () -> "")
