module T = Logseq_db_worker_test_support.Test_support
module Locator = Logseq_db_worker__Graph_locator

let with_temp_directory f =
  let base = Filename.temp_file "logseq-db-worker-locator-" "" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  Fun.protect ~finally:(fun () ->
    let command = Printf.sprintf "rm -rf -- %s" (Filename.quote base) in
    ignore (Sys.command command)) (fun () -> f base)

let touch path =
  let channel = open_out_bin path in
  close_out channel

let make_graph root graph_name =
  let graph_dir = Filename.concat root graph_name in
  Unix.mkdir graph_dir 0o700;
  touch (Filename.concat graph_dir "db.sqlite");
  graph_dir

let require_resolved expected result =
  match result with
  | Ok resolved -> T.require (String.equal resolved.Locator.graph_dir expected) "wrong graph directory"
  | Error _ -> T.fail "graph did not resolve"

let () =
  T.run
    "graph locator"
    [ T.case "desktop resolves ~/logseq/<graph-name>/db.sqlite" (fun () ->
        with_temp_directory (fun home ->
          let root = Filename.concat home "logseq" in
          Unix.mkdir root 0o700;
          let graph_dir = make_graph root "notes" |> Unix.realpath in
          require_resolved graph_dir (Locator.resolve (Desktop { home_directory = home }) ~graph_name:"notes")))
    ; T.case "iOS confines <app-data-dir>/graphs/<graph-name>/db.sqlite" (fun () ->
        with_temp_directory (fun app_data ->
          let root = Filename.concat app_data "graphs" in
          Unix.mkdir root 0o700;
          let graph_dir = make_graph root "notes" |> Unix.realpath in
          require_resolved graph_dir (Locator.resolve (Ios { application_data_directory = app_data }) ~graph_name:"notes")))
    ; T.case "Unicode graph name remains one path component" (fun () ->
        with_temp_directory (fun home ->
          let root = Filename.concat home "logseq" in
          Unix.mkdir root 0o700;
          let graph_dir = make_graph root "中文 graph" |> Unix.realpath in
          require_resolved graph_dir (Locator.resolve (Desktop { home_directory = home }) ~graph_name:"中文 graph")))
    ; T.case "empty graph name is rejected" (fun () ->
        match Locator.resolve (Desktop { home_directory = "/tmp" }) ~graph_name:"" with
        | Error (Invalid_graph_name _) -> ()
        | _ -> T.fail "empty name accepted")
    ; T.case "slash and backslash are rejected" (fun () ->
        List.iter
          (fun name ->
             match Locator.resolve (Desktop { home_directory = "/tmp" }) ~graph_name:name with
             | Error (Invalid_graph_name _) -> ()
             | _ -> T.fail "separator accepted")
          [ "a/b"; "a\\b" ])
    ; T.case "dot and dot-dot are rejected" (fun () ->
        List.iter
          (fun name ->
             match Locator.resolve (Desktop { home_directory = "/tmp" }) ~graph_name:name with
             | Error (Invalid_graph_name _) -> ()
             | _ -> T.fail "dot name accepted")
          [ "."; ".." ])
    ; T.case "NUL and invalid UTF-8 are rejected" (fun () ->
        (match Locator.resolve (Desktop { home_directory = "/tmp" }) ~graph_name:"a\000b" with
         | Error (Invalid_graph_name _) -> ()
         | _ -> T.fail "NUL accepted");
        match Locator.resolve (Desktop { home_directory = "/tmp" }) ~graph_name:"\255" with
        | Error Invalid_utf8 -> ()
        | _ -> T.fail "invalid UTF-8 accepted")
    ; T.case "symlink escape is rejected" (fun () ->
        with_temp_directory (fun home ->
          let root = Filename.concat home "logseq" in
          let outside = Filename.concat home "outside" in
          Unix.mkdir root 0o700;
          Unix.mkdir outside 0o700;
          let graph_dir = make_graph outside "notes" in
          Unix.symlink graph_dir (Filename.concat root "notes");
          match Locator.resolve (Desktop { home_directory = home }) ~graph_name:"notes" with
          | Error Symlink_escape -> ()
          | _ -> T.fail "symlink escape accepted"))
    ; T.case "basename mismatch is rejected" (fun () ->
        with_temp_directory (fun root ->
          let graph_dir = make_graph root "actual" in
          match Locator.validate_native ~graph_name:"expected" ~graph_dir with
          | Error Basename_mismatch -> ()
          | _ -> T.fail "basename mismatch accepted"))
    ; T.case "missing graph directory is rejected" (fun () ->
        match Locator.validate_native ~graph_name:"missing" ~graph_dir:"/definitely/missing" with
        | Error Graph_directory_missing -> ()
        | _ -> T.fail "missing directory accepted")
    ; T.case "missing db.sqlite is rejected" (fun () ->
        with_temp_directory (fun root ->
          let graph_dir = Filename.concat root "notes" in
          Unix.mkdir graph_dir 0o700;
          match Locator.validate_native ~graph_name:"notes" ~graph_dir with
          | Error Database_missing -> ()
          | _ -> T.fail "missing database accepted"))
    ; T.case "canonical resolution is stable" (fun () ->
        with_temp_directory (fun home ->
          let root = Filename.concat home "logseq" in
          Unix.mkdir root 0o700;
          ignore (make_graph root "notes");
          let first = Locator.resolve (Desktop { home_directory = home }) ~graph_name:"notes" in
          let second = Locator.resolve (Desktop { home_directory = home }) ~graph_name:"notes" in
          T.require (first = second) "canonical result changed"))
    ]
