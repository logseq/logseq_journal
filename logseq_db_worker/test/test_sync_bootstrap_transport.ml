module T = Logseq_db_worker_test_support.Test_support
module B = Logseq_db_worker.Sync_bootstrap

let binary_of_hex source =
  let result = Bytes.create (String.length source / 2) in
  for index = 0 to Bytes.length result - 1 do
    Bytes.set
      result
      index
      (Char.chr (int_of_string ("0x" ^ String.sub source (index * 2) 2)))
  done;
  Bytes.unsafe_to_string result
;;

let raw = binary_of_hex "4c4a53312d746573742d6672616d65642d73747265616d"

let one =
  binary_of_hex
    "1f8b0800000000000003f3f10a36d42d492d2ed14d2b4acc4d4dd12d2e294a4dcc0500c951905b17000000"
;;

let two =
  binary_of_hex
    "1f8b080000000000000393efe6600003e6cf1fb9ccaee87aeaea5df4d5f63ae3eb7b51574fd3cbf70c2bc3c9c009d1e2401500ecda0dfd2b000000"
;;

let three =
  binary_of_hex
    "1f8b080000000000000393efe6600003e6c9ef9f2530303f3b2fbff3ccba1755af5ec57eb9facdeaf1ebeac070ffcba7bff3681f3e7980f3e22307518637b778ff6a03750000d6e740383b000000"
;;

let write path value =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel value)
;;

let read path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))
;;

let with_directory f =
  let root = Filename.temp_file "sync-bootstrap-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () ->
      Sys.readdir root |> Array.iter (fun name -> Sys.remove (Filename.concat root name));
      Unix.rmdir root)
    (fun () -> f root)
;;

let test_accepts_zero_one_and_two_gzip_layers () =
  with_directory (fun root ->
    List.iteri
      (fun index encoded ->
         let source = Filename.concat root (Printf.sprintf "source-%d" index) in
         let destination = Filename.concat root (Printf.sprintf "output-%d" index) in
         let temporaries =
           [ Filename.concat root (Printf.sprintf "decoded-%d-1" index)
           ; Filename.concat root (Printf.sprintf "decoded-%d-2" index)
           ]
         in
         write source encoded;
         (match
            B.peel_gzip_layers
              ~maximum_bytes:1024
              ~source
              ~destination
              ~temporary_paths:temporaries
          with
          | Error message -> T.fail "valid gzip layers failed: %s" message
          | Ok () -> ());
         let decoded = read destination in
         T.require
           (String.equal decoded raw)
           "decoded snapshot changed at layer %d (expected %d bytes, found %d)"
           index
           (String.length raw)
           (String.length decoded);
         T.require
           (List.for_all (fun path -> not (Sys.file_exists path)) temporaries)
           "successful decode left temporary files")
      [ raw; one; two ])
;;

let test_rejects_third_layer_without_residue () =
  with_directory (fun root ->
    let source = Filename.concat root "source" in
    let destination = Filename.concat root "output" in
    let temporaries =
      [ Filename.concat root "decoded-1"; Filename.concat root "decoded-2" ]
    in
    write source three;
    T.require
      (Result.is_error
         (B.peel_gzip_layers
            ~maximum_bytes:1024
            ~source
            ~destination
            ~temporary_paths:temporaries))
      "third gzip layer was accepted";
    T.require (not (Sys.file_exists destination)) "failed decode activated an artifact";
    T.require
      (List.for_all (fun path -> not (Sys.file_exists path)) temporaries)
      "failed decode left temporary files")
;;

let test_rejects_decompression_bomb_at_caller_bound () =
  with_directory (fun root ->
    let source = Filename.concat root "source" in
    let destination = Filename.concat root "output" in
    let temporaries =
      [ Filename.concat root "decoded-1"; Filename.concat root "decoded-2" ]
    in
    write source one;
    T.require
      (Result.is_error
         (B.peel_gzip_layers
            ~maximum_bytes:8
            ~source
            ~destination
            ~temporary_paths:temporaries))
      "gzip output exceeded its caller bound";
    T.require (not (Sys.file_exists destination)) "oversized decode left an output";
    T.require
      (List.for_all (fun path -> not (Sys.file_exists path)) temporaries)
      "oversized decode left temporary files")
;;

let test_decodes_strict_bootstrap_protocol () =
  let baseline =
    match
      B.decode_baseline
        {|{"type":"pull/ok","t":48192,"txs":[],"checksum":"ac9682b5e1f889e3"}|}
    with
    | Ok value -> value
    | Error message -> T.fail "valid baseline failed: %s" message
  in
  T.require (baseline.B.server_t = 48192) "baseline cursor changed";
  T.require
    (Result.is_error
       (B.decode_baseline
          {|{"type":"pull/ok","t":1,"txs":[],"checksum":null,"extra":true}|}))
    "baseline accepted an unknown field";
  let metadata =
    match
      B.decode_snapshot_metadata
        {|{"ok":true,"key":"snapshot-key","url":"https://objects.example/snapshot","content-encoding":"gzip"}|}
    with
    | Ok value -> value
    | Error message -> T.fail "valid snapshot metadata failed: %s" message
  in
  T.require
    (String.equal metadata.B.key "snapshot-key"
     && Uri.equal metadata.url (Uri.of_string "https://objects.example/snapshot")
     && metadata.content_encoding = Some `Gzip)
    "snapshot metadata changed";
  T.require
    (Result.is_error
       (B.decode_snapshot_metadata
          {|{"ok":true,"key":"snapshot-key","url":"http://objects.example/snapshot"}|}))
    "snapshot metadata accepted a non-HTTPS URL";
  T.require
    (B.artifact_row_count [ "X-Snapshot-Row-Count", "12" ] = Ok 12)
    "artifact row count was not decoded case-insensitively";
  T.require
    (Result.is_error (B.artifact_row_count [ "x-snapshot-row-count", "0" ]))
    "artifact accepted an empty snapshot"
;;

let test_httpun_eio_retains_large_response_during_reader_backpressure () =
  Eio_main.run (fun _environment ->
    Eio.Switch.run (fun sw ->
      let client_socket, server_socket = Eio_unix.Net.socketpair_stream ~sw () in
      let expected = String.init (128 * 1024) (fun index -> Char.chr (index mod 251)) in
      let server_error _peer ?request:_ _error _respond =
        T.fail "httpun-eio test server failed"
      in
      Eio.Fiber.fork ~sw (fun () ->
        Httpun_eio.Server.create_connection_handler
          ~request_handler:(fun _peer request ->
            Httpun.Reqd.respond_with_string
              request.Gluten.reqd
              (Httpun.Response.create `OK)
              expected)
          ~error_handler:server_error
          ~sw
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
          server_socket);
      let config =
        { Httpun.Config.default with
          read_buffer_size = 1024
        ; response_body_buffer_size = 1024
        }
      in
      let client = Httpun_eio.Client.create_connection ~config ~sw client_socket in
      let result, resolve_result = Eio.Promise.create () in
      let received = Buffer.create (String.length expected) in
      let response_handler _response body =
        let rec read () =
          Httpun.Body.Reader.schedule_read
            body
            ~on_eof:(fun () -> Eio.Promise.resolve resolve_result (Ok (Buffer.contents received)))
            ~on_read:(fun chunk ~off ~len ->
              Buffer.add_string received (Bigstringaf.substring chunk ~off ~len);
              Eio.Fiber.fork ~sw (fun () ->
                Eio.Fiber.yield ();
                read ()))
        in
        read ()
      in
      let writer =
        Httpun_eio.Client.request
          client
          (Httpun.Request.create
             ~headers:(Httpun.Headers.of_list [ "host", "localhost"; "connection", "close" ])
             `GET
             "/large")
          ~error_handler:(fun _ -> Eio.Promise.resolve resolve_result (Error "client error"))
          ~response_handler
      in
      Httpun.Body.Writer.close writer;
      match Eio.Promise.await result with
      | Error message -> T.fail "large backpressured response failed: %s" message
      | Ok actual ->
        T.require
          (String.equal actual expected)
          "large backpressured response lost or changed bytes"))
;;

let () =
  T.require (B.maximum_gzip_layers = 2) "gzip layer bound changed";
  test_decodes_strict_bootstrap_protocol ();
  test_accepts_zero_one_and_two_gzip_layers ();
  test_rejects_third_layer_without_residue ();
  test_rejects_decompression_bomb_at_caller_bound ();
  test_httpun_eio_retains_large_response_during_reader_backpressure ()
;;
