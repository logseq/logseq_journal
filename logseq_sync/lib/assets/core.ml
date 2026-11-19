module Dsl = Sync_dsl.Core
module Intent = Logseq_db_types.Asset_upload_intent
module Asset = Logseq_db_types.Asset_descriptor
module Codec = Logseq_sync_native_crypto.Asset_codec
module Crypto = Logseq_sync_crypto.Core
module Native = Logseq_sync_native_crypto.Platform_crypto

let ( let* ) = Result.bind

type network =
  { get :
      identity:Dsl.identity
      -> asset:Dsl.asset
      -> version:Asset.version
      -> maximum_wire_bytes:int
      -> (string option, Dsl.error) result
  ; put :
      identity:Dsl.identity
      -> asset:Logseq_db_types.Graph_types.Uuid.t
      -> version:Asset.version
      -> wire:string
      -> (unit, Dsl.error) result
  }

type key =
  check_current:(unit -> (unit, Dsl.error) result) -> (string option, Dsl.error) result

let native_key ~identity ~crypto ~check_current =
  Crypto.asset_key crypto ~check_current ~identity
;;

module Resources = Ephemeron.K1.Make (struct
    type t = Dsl.resource

    let equal left right = left == right
    let hash resource = Hashtbl.hash resource.Dsl.token
  end)

type held =
  { handle : Cache.handle
  ; reference : Dsl.resource_reference
  ; mutable released : bool
  }

type t =
  { identity : Dsl.identity
  ; limits : Dsl.limits
  ; crypto : Crypto.t
  ; key : key
  ; network : network
  ; cache : Cache.t
  ; lock : Eio.Mutex.t
  ; resources : held Resources.t
  ; mutable live_resources : int
  ; mutable reserved_resources : int
  ; mutable active_transfers : int
  ; mutable next_resource : int64
  ; mutable fenced : bool
  }

let identity t = t.identity
let limits t = t.limits
let cache t = t.cache
let crypto t = t.crypto

let cache_error = function
  | Cache.Invalid message -> Dsl.Invalid_input message
  | Io message -> Dsl.Storage_failure message
  | Full -> Dsl.Capacity_exceeded "Asset storage"
  | Stale -> Dsl.Stale_context
  | Checksum_mismatch -> Dsl.Protocol_failure "Asset checksum mismatch"
;;

let storage result = Result.map_error cache_error result

let create ~root ~identity ~limits ~crypto ~key ~network =
  let* scope =
    Namespace.of_identity identity
    |> Result.map_error (fun message -> Dsl.Invalid_input message)
  in
  let* cache =
    storage
      (Cache.create
         ~root
         ~scope
         ~budget_bytes:limits.Dsl.asset_cache_budget_bytes
         ~maximum_file_bytes:limits.asset_maximum_file_bytes)
  in
  Ok
    { identity
    ; limits
    ; crypto
    ; key
    ; network
    ; cache
    ; lock = Eio.Mutex.create ()
    ; resources = Resources.create 16
    ; live_resources = 0
    ; reserved_resources = 0
    ; active_transfers = 0
    ; next_resource = 0L
    ; fenced = false
    }
;;

let locked t callback = Eio.Mutex.use_rw ~protect:true t.lock callback

let same_owner t identity =
  if identity = t.identity then Ok () else Error (Dsl.Identity_mismatch "Asset owner")
;;

let check t check_current =
  let* () = check_current () in
  if t.fenced then Error Dsl.Stale_context else Ok ()
;;

let protected t =
  if Crypto.status t.crypto = Dsl.Key_locked then Error Dsl.Locked else Ok ()
;;

let resource_of_reference = function
  | Dsl.File_reference file -> file.file
  | Lease_reference lease -> lease.lease
  | Snapshot_reference snapshot -> snapshot.resource
  | Connection_reference _ -> invalid_arg "Not an asset reference"
;;

let held t resource =
  match Resources.find_opt t.resources resource with
  | Some held -> Ok held
  | None -> Error (Dsl.Identity_mismatch "Unregistered asset resource")
;;

let validate_resource t reference =
  match reference with
  | Dsl.File_reference file ->
    let* owned = held t file.file in
    (match owned.reference with
     | Dsl.File_reference original when original == file -> Ok ()
     | _ -> Error (Dsl.Identity_mismatch "Asset file metadata"))
  | Lease_reference lease ->
    let* owned = held t lease.lease in
    (match owned.reference with
     | Dsl.Lease_reference original when original == lease -> Ok ()
     | _ -> Error (Dsl.Identity_mismatch "Asset lease metadata"))
  | Snapshot_reference _ | Connection_reference _ ->
    Error (Dsl.Identity_mismatch "Asset resource kind")
;;

let reserve t =
  if t.live_resources + t.reserved_resources >= t.limits.maximum_resources
  then Error (Dsl.Capacity_exceeded "Asset resources")
  else Ok ()
;;

let with_transfer t ~resource callback =
  let* () =
    locked t (fun () ->
      if t.active_transfers >= t.limits.maximum_active_assets
      then Error (Dsl.Capacity_exceeded "Asset transfers")
      else
        let* () = if resource then reserve t else Ok () in
        t.active_transfers <- t.active_transfers + 1;
        if resource then t.reserved_resources <- t.reserved_resources + 1;
        Ok ())
  in
  Fun.protect
    ~finally:(fun () ->
      locked t (fun () ->
        t.active_transfers <- t.active_transfers - 1;
        if resource then t.reserved_resources <- t.reserved_resources - 1))
    callback
;;

let fresh t =
  if t.next_resource = Int64.max_int
  then Error (Dsl.Capacity_exceeded "Asset resource generation")
  else (
    t.next_resource <- Int64.succ t.next_resource;
    Dsl.resource
      ~owner:t.identity
      ~token:("asset-owner:" ^ Int64.to_string t.next_resource))
;;

let register t handle reference =
  let resource = resource_of_reference reference in
  Resources.add t.resources resource { handle; reference; released = false };
  t.live_resources <- t.live_resources + 1
;;

let acquire_file ?(reserved = false) t asset acquire =
  let* () = if reserved then Ok () else reserve t in
  let* resource = fresh t in
  let* file = Dsl.asset_file resource asset in
  let* handle = acquire () in
  match handle with
  | None -> Ok None
  | Some handle ->
    register t handle (Dsl.File_reference file);
    Ok (Some file)
;;

let release t identity reference =
  let* () = same_owner t identity in
  locked t (fun () ->
    let* () = validate_resource t reference in
    let* owned = held t (resource_of_reference reference) in
    if owned.released
    then Ok ()
    else
      let* () = storage (Cache.release_checked t.cache owned.handle) in
      owned.released <- true;
      t.live_resources <- t.live_resources - 1;
      Ok ())
;;

let release_file t ~identity (file : Dsl.asset_file) =
  release t identity (Dsl.File_reference file)
;;

let release_lease t ~identity (lease : Dsl.asset_lease) =
  release t identity (Dsl.Lease_reference lease)
;;

let file_path t (file : Dsl.asset_file) =
  locked t (fun () ->
    let* () = validate_resource t (Dsl.File_reference file) in
    let* owned = held t file.file in
    if owned.released
    then Error Dsl.Stale_context
    else (
      match Cache.path t.cache owned.handle with
      | Some path -> Ok path
      | None -> Error (Dsl.Storage_failure "Asset file disappeared")))
;;

let retain t (file : Dsl.asset_file) =
  locked t (fun () ->
    let* () = validate_resource t (Dsl.File_reference file) in
    let* owned = held t file.file in
    if owned.released
    then Error Dsl.Stale_context
    else
      let* () = reserve t in
      let* resource = fresh t in
      let* lease = Dsl.asset_lease resource file in
      match Cache.retain t.cache owned.handle with
      | None -> Error Dsl.Stale_context
      | Some handle ->
        register t handle (Dsl.Lease_reference lease);
        Ok lease)
;;

let read_source t path =
  try
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () ->
         let size = in_channel_length channel in
         if size > t.limits.asset_maximum_file_bytes
         then Error (Dsl.Capacity_exceeded "Asset file bytes")
         else (
           let bytes = really_input_string channel size in
           match input_char channel with
           | _ -> Error (Dsl.Storage_failure "Asset file grew")
           | exception End_of_file -> Ok bytes))
  with
  | End_of_file -> Error (Dsl.Storage_failure "Asset file shrank")
  | Sys_error message -> Error (Dsl.Storage_failure message)
;;

let codec_crypto =
  { Codec.encrypt = Native.crypto.encrypt_aes_gcm
  ; decrypt = Native.crypto.decrypt_aes_gcm
  }
;;

let verified t version bytes =
  Codec.decode
    ~maximum_plaintext_bytes:t.limits.asset_maximum_file_bytes
    ~crypto:codec_crypto
    ~key:None
    ~expected:version
    bytes
  |> Result.map_error (fun _ -> Dsl.Protocol_failure "Invalid local asset bytes")
;;

let with_staged t (intent : Intent.t) callback =
  let* handle =
    locked t (fun () ->
      match Cache.retain_staged t.cache ~file:intent.staged_file with
      | Some handle -> Ok handle
      | None -> Error (Dsl.Storage_failure "Original import staging is missing"))
  in
  let result =
    try
      match Cache.path t.cache handle with
      | None -> Error (Dsl.Storage_failure "Original import staging is missing")
      | Some path -> callback path
    with
    | exception_ ->
      let cleanup = locked t (fun () -> storage (Cache.release_checked t.cache handle)) in
      (match cleanup with
       | Ok () -> raise exception_
       | Error error ->
         Error
           (Dsl.Cleanup_failure
              { primary = Some (Dsl.Unexpected_failure (Printexc.to_string exception_))
              ; failures = Rrbvec.singleton error
              }))
  in
  let cleanup = locked t (fun () -> storage (Cache.release_checked t.cache handle)) in
  match cleanup, result with
  | Ok (), result -> result
  | Error error, result ->
    Error
      (Dsl.Cleanup_failure
         { primary =
             (match result with
              | Error error -> Some error
              | Ok _ -> None)
         ; failures = Rrbvec.singleton error
         })
;;

let publish_preview t ~check_current intent =
  let* () = check t check_current in
  let* () = protected t in
  with_staged t intent (fun path ->
    let* bytes = read_source t path in
    let* verified = verified t intent.version bytes in
    let* () = check t check_current in
    locked t (fun () ->
      let* handle =
        storage
          (Cache.publish
             t.cache
             ~asset:intent.asset
             ~current:(fun () -> Result.is_ok (check t check_current))
             ~verified)
      in
      storage (Cache.release_checked t.cache handle)))
;;

let stage t ~check_current (input : Logseq_db_types.Asset_import.t) =
  let* () = check t check_current in
  let* () = protected t in
  locked t (fun () ->
    let* () = check t check_current in
    storage
      (Cache.stage
         t.cache
         ~operation:input.operation
         ~file_type:input.file_type
         ~source_file:input.source_file
         ~pending_budget_bytes:t.limits.asset_pending_budget_bytes))
;;

let put_staged t ~check_current ~(network : Execute.Core.worker_network) intent =
  let* () = check t check_current in
  let* () = protected t in
  with_transfer t ~resource:false (fun () ->
    with_staged t intent (fun path ->
      let* bytes = read_source t path in
      let* _ = verified t intent.version bytes in
      let* key = t.key ~check_current:(fun () -> check t check_current) in
      let* wire =
        Codec.encode
          ~maximum_plaintext_bytes:t.limits.asset_maximum_file_bytes
          ~crypto:codec_crypto
          ~key
          bytes
        |> Result.map_error (fun message -> Dsl.Crypto_failure message)
      in
      network.with_admission (fun () ->
        let* () = check t check_current in
        t.network.put
          ~identity:t.identity
          ~asset:intent.asset
          ~version:intent.version
          ~wire)))
;;

let lookup t ~original asset =
  let* original = original asset in
  let staged =
    match original with
    | Some intent
      when asset.Asset.current_checksum = Some intent.Intent.version.checksum
           && intent.phase <> Intent.Cancelled ->
      acquire_file t asset (fun () ->
        Ok (Cache.retain_staged t.cache ~file:intent.staged_file))
    | Some _ | None -> Ok None
  in
  let* staged = staged in
  match staged with
  | Some _ -> Ok staged
  | None ->
    let rec find = function
      | [] -> Ok None
      | version :: rest ->
        let* file =
          acquire_file t asset (fun () ->
            storage (Cache.lookup t.cache ~asset:asset.uuid ~version))
        in
        (match file with
         | Some _ -> Ok file
         | None -> find rest)
    in
    find (Selection.lookup_versions asset)
;;

let run
      (type value)
      t
      ~check_current
      ~admit_network
      ~original
      ~(upload : Dsl.asset -> (unit, Dsl.error) result)
      ~identity
      (operation : value Dsl.assets)
  : (value, Dsl.error) result
  =
  let* () = same_owner t identity in
  let precheck : type value. value Dsl.assets -> (unit, Dsl.error) result = function
    | Dsl.Release_file _ | Release_lease _ -> Ok ()
    | Prune_cache | Reconcile_staging | Lookup _ | Retain _ | Upload _ | Download _ -> check t check_current
  in
  let* () = precheck operation in
  let perform : type value. value Dsl.assets -> (value, Dsl.error) result = function
    | Dsl.Release_file file -> release_file t ~identity file
    | Release_lease lease -> release_lease t ~identity lease
    | Dsl.Prune_cache -> locked t (fun () -> storage (Cache.prune t.cache))
    | Reconcile_staging -> Error (Dsl.Invalid_input "Staging reconciliation requires worker owner")
    | Lookup asset ->
      let* () = protected t in
      locked t (fun () -> lookup t ~original asset)
    | Retain file ->
      let* () = protected t in
      retain t file
    | Upload asset ->
      let* () = protected t in
      upload asset
    | Download asset ->
      let* () = protected t in
      (match Selection.download_version asset with
       | None ->
         Ok
           (match asset.source with
            | Asset.External _ -> Dsl.Missing_local
            | Managed _ -> Waiting_remote)
       | Some version ->
         with_transfer t ~resource:true (fun () ->
           let* key = t.key ~check_current:(fun () -> check t check_current) in
           let maximum_wire_bytes =
             match key with
             | None -> t.limits.asset_maximum_file_bytes
             | Some _ -> (4 * ((t.limits.asset_maximum_file_bytes + 18) / 3)) + 128
           in
           let* () = admit_network () in
           let* wire = t.network.get ~identity ~asset ~version ~maximum_wire_bytes in
           let* () = check t check_current in
           match wire with
           | None -> Ok Dsl.Waiting_remote
           | Some wire ->
             if Option.is_some key && not (Codec.envelope_shape wire)
             then
               Error
                 (Dsl.Protocol_failure
                    "Encrypted asset requires an authenticated envelope")
             else
               let* verified =
                 Codec.decode
                   ~maximum_plaintext_bytes:t.limits.asset_maximum_file_bytes
                   ~crypto:codec_crypto
                   ~key
                   ~expected:version
                   wire
                 |> Result.map_error (fun _ ->
                   Dsl.Protocol_failure
                     "Asset authentication or checksum verification failed")
               in
               locked t (fun () ->
                 let* () = check t check_current in
                 let* file =
                   acquire_file ~reserved:true t asset (fun () ->
                     storage
                       (Cache.publish
                          t.cache
                          ~asset:asset.uuid
                          ~current:(fun () -> Result.is_ok (check t check_current))
                          ~verified)
                     |> Result.map Option.some)
                 in
                 match file with
                 | Some file -> Ok (Dsl.Available file)
                 | None ->
                   Error (Dsl.Storage_failure "Asset publication returned no file"))))
  in
  perform operation
;;

let dispatch t ~original ~upload ~scope ~identity operation =
  let* result =
    run
      t
      ~check_current:(fun () -> Execute.Core.check_current scope)
      ~admit_network:(fun () -> Execute.Core.admit_network scope)
      ~original
      ~upload
      ~identity
      operation
  in
  let references
    : type value. value Dsl.assets -> value -> Dsl.resource_reference Rrbvec.t
    =
    fun operation result ->
    match operation with
    | Dsl.Lookup _ ->
      (match result with
       | Some file -> Rrbvec.singleton (Dsl.File_reference file)
       | None -> Rrbvec.empty)
    | Download _ ->
      (match result with
       | Available file -> Rrbvec.singleton (Dsl.File_reference file)
       | Waiting_remote | Missing_local -> Rrbvec.empty)
    | Retain _ -> Rrbvec.singleton (Dsl.Lease_reference result)
    | Prune_cache | Reconcile_staging | Upload _ | Release_file _ | Release_lease _ -> Rrbvec.empty
  in
  let refs = references operation result in
  match Execute.Core.handoff scope refs with
  | Ok () -> Ok result
  | Error error ->
    let failures =
      Rrbvec.fold_left
        (fun failures reference ->
           let released =
             match reference with
             | Dsl.File_reference file -> release_file t ~identity file
             | Lease_reference lease -> release_lease t ~identity lease
             | Snapshot_reference _ | Connection_reference _ -> Ok ()
           in
           match released with
           | Ok () -> failures
           | Error error -> Rrbvec.push_back failures error)
        Rrbvec.empty
        refs
    in
    if Rrbvec.length failures = 0
    then Error error
    else Error (Dsl.Cleanup_failure { primary = Some error; failures })
;;

let fence t = t.fenced <- true

let close t =
  fence t;
  locked t (fun () ->
    if t.live_resources <> 0 || t.active_transfers <> 0
    then Error (Dsl.Capacity_exceeded "Asset consumer resources remain")
    else storage (Cache.close_checked t.cache))
;;
