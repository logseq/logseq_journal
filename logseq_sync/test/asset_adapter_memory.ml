module D = Sync_dsl.Core
module Codec = Logseq_sync_native_crypto.Asset_codec
module Native = Logseq_sync_native_crypto.Platform_crypto
module Owner = Logseq_sync_assets.Core
module Intent = Logseq_db_types.Asset_upload_intent

let get = Result.get_ok
let ok = get

let identity =
  get
    (D.identity
       ~origin:"https://asset-test.invalid"
       ~account:"fixture"
       ~graph:"11111111-1111-4111-8111-111111111111"
       ~account_generation:0L
       ~graph_generation:0L)
;;

let limits =
  ok
    (D.limits
       ~maximum_items:8
       ~maximum_bytes:1024
       ~maximum_pending:8
       ~maximum_resources:8
       ~steps_per_turn:8
       ~maximum_tasks:8
       ~maximum_messages:8
       ~maximum_message_bytes:1024
       ~maximum_demands:8
       ~maximum_active_assets:2
       ~foreground_reserve:1
       ~foreground_demand_reserve:1
       ~foreground_descriptor_reserve_bytes:128
       ~asset_cache_budget_bytes:16777216L
       ~asset_maximum_file_bytes:(8 * 1024 * 1024)
       ~asset_pending_budget_bytes:16777216L
       ~snapshot_maximum_artifact_bytes:4096L
       ~snapshot_staging_budget_bytes:4096L
       ~snapshot_scratch_budget_bytes:4096L)
;;

let () =
  Eio_main.run (fun _ ->
    let support = Sys.argv.(1) in
    let key = String.init 32 Char.chr in
    let crypto = Native.crypto in
    List.iter
      (fun size ->
         let bytes = String.init size (fun index -> Char.chr (index mod 256)) in
         let iv, ciphertext = get (crypto.encrypt_aes_gcm ~key ~plaintext:bytes) in
         if get (crypto.decrypt_aes_gcm ~key ~iv ~ciphertext) <> bytes
         then failwith "Production adapter roundtrip changed bytes")
      [ 0; 1; 256; 4097; 131057 ];
    let crypto_owner =
      Logseq_sync_crypto.Core.create
        ~identity
        ~limits
        ~encrypted:true
        ~backend:{ crypto; unlock = (fun ~identity:_ ~wrapped_graph_key:_ -> Ok key) }
    in
    ignore
      (get
         (Logseq_sync_crypto.Core.run
            crypto_owner
            ~check_current:(fun () -> Ok ())
            ~identity
            (D.Unlock (get (D.unlock_input ~wrapped_graph_key:"synthetic")))));
    let auth_calls = ref 0 in
    let network : Owner.network =
      { get =
          (fun ~identity:_ ~asset:_ ~version:_ ~maximum_wire_bytes:_ ->
            Error (D.Invalid_input "Unexpected GET"))
      ; put =
          (fun ~identity:_ ~asset:_ ~version:_ ~wire:_ ->
            incr auth_calls;
            Error (D.Authentication_failure "synthetic authorization failure"))
      }
    in
    let owner =
      get
        (Owner.create
           ~root:support
           ~identity
           ~limits
           ~crypto:crypto_owner
           ~key:(Owner.native_key ~identity ~crypto:crypto_owner)
           ~network)
    in
    Fun.protect
      ~finally:(fun () ->
        ignore (get (Owner.close owner));
        Logseq_sync_crypto.Core.retire crypto_owner)
      (fun () ->
         let size = 8 * 1024 * 1024 in
         let bytes = String.init size (fun index -> Char.chr (index mod 256)) in
         let source_file = Filename.concat support "source.bin" in
         Out_channel.with_open_bin source_file (fun output -> output_string output bytes);
         let uuid =
           get
             (Logseq_db_types.Graph_types.Uuid.of_string
                "11111111-1111-4111-8111-111111111111")
         in
         let input : Logseq_db_types.Asset_import.t =
           { operation = uuid
           ; asset = uuid
           ; replace_reference = None
           ; target = uuid
           ; local_mutation = uuid
           ; metadata_mutation = uuid
           ; source_file
           ; title = "fixture"
           ; file_type = "bin"
           }
         in
         let staged = get (Owner.stage owner ~check_current:(fun () -> Ok ()) input) in
         let version =
           get
             (Logseq_db_types.Asset_descriptor.version
                ~checksum:(Codec.checksum bytes)
                ~file_type:"bin")
         in
         let intent =
           get
             (Intent.prepare
                ~operation_id:uuid
                ~origin:"https://asset-test.invalid"
                ~account:"fixture"
                ~graph:uuid
                ~asset:uuid
                ~version
                ~title:"fixture"
                ~size:staged.size
                ~staged_file:staged.file
                ~replace_reference:None
                ~target:uuid
                ~local_mutation:uuid
                ~metadata_mutation:
                  (get
                     (Logseq_db_types.Graph_types.Uuid.of_string
                        "11111111-1111-4111-8111-111111111112")))
         in
         Gc.full_major ();
         let before = Gc.allocated_bytes () in
         let network : Execute.Core.worker_network =
           { with_admission = (fun run -> run ()) }
         in
         let result =
           Owner.put_staged owner ~check_current:(fun () -> Ok ()) ~network intent
         in
         let allocated = Gc.allocated_bytes () -. before in
         if
           result <> Error (D.Authentication_failure "synthetic authorization failure")
           || !auth_calls <> 1
         then failwith "Production adapter did not encode the maximum-size asset";
         Printf.printf "Production upload OCaml allocation bytes: %.0f\n%!" allocated;
         if allocated > 128. *. 1024. *. 1024.
         then failwith "Asset adapter allocation exceeds 128 MiB";
         get
           (Logseq_sync_assets.Cache.release_staged (Owner.cache owner) ~file:staged.file)))
;;
