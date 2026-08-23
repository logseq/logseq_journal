type error =
  | Sync_paused of string
  | Protocol_error of string
  | Transit_error of
      { server_t : int
      ; message : string
      }
  | Stage_error of string
  | Persistence_error of string

type applied =
  { metadata : Sync_meta.t
  ; basis_before : int64
  ; basis_after : int64
  ; changed_uuids : Graph_types.Uuid.t list
  }

type duplicate =
  { metadata : Sync_meta.t
  ; basis : int64
  }

type paused =
  { metadata : Sync_meta.t
  ; basis : int64
  }

type outcome =
  | Applied of applied
  | Duplicate of duplicate
  | Paused of paused

let error_message = function
  | Sync_paused message -> "sync is paused: " ^ message
  | Protocol_error message -> message
  | Transit_error { server_t; message } ->
    Printf.sprintf "invalid Transit transaction at server t %d: %s" server_t message
  | Stage_error message -> "unable to stage pulled transactions: " ^ message
  | Persistence_error message -> "unable to persist pulled transactions: " ^ message
;;

let basis db = (Datascript.serializable db).serializable_max_tx |> Int64.of_int

let storage_error = function
  | Storage_session.Closed -> "storage session is closed"
  | Fatal message | Stage_failed message | Persistence_failed message -> message
  | Already_consumed -> "staged transaction was already consumed"
;;

let uuid_at db entity =
  match
    Datascript.datoms db Datascript.Eavt ~e:entity ~a:"block/uuid" ()
    |> Seq.find_map (fun datom ->
      match datom.Datascript.v with
      | Datascript.Uuid value -> Some value
      | _ -> None)
  with
  | None -> None
  | Some value ->
    (match Graph_types.Uuid.of_string value with
     | Ok value -> Some value
     | Error _ -> None)
;;

let changed_uuids ~db_before ~db_after datoms =
  let add_uuid values = function
    | None -> values
    | Some uuid ->
      if List.exists (Graph_types.Uuid.equal uuid) values then values else uuid :: values
  in
  datoms
  |> List.fold_left
       (fun values datom ->
          let values = add_uuid values (uuid_at db_before datom.Datascript.e) in
          let values = add_uuid values (uuid_at db_after datom.e) in
          if String.equal datom.a "block/uuid"
          then (
            match datom.v with
            | Datascript.Uuid value ->
              (match Graph_types.Uuid.of_string value with
               | Ok value -> add_uuid values (Some value)
               | Error _ -> values)
            | _ -> values)
          else values)
       []
  |> List.rev
;;

let decode_transactions decrypt_protected db txs =
  let rec loop decoded = function
    | [] -> Ok (List.rev decoded)
    | (tx : Sync_protocol.pull_tx) :: rest ->
      (match Sync_tx.decode ?decrypt_protected ~db tx.tx with
       | Ok operations -> loop (operations :: decoded) rest
       | Error message -> Error (Transit_error { server_t = tx.t; message }))
  in
  loop [] txs
;;

let pause before_commit session metadata ~basis ~remote_t ~local_checksum ~remote_checksum
  =
  let message =
    Printf.sprintf
      "Entity checksum mismatch at server t %d (local %s, remote %s)."
      remote_t
      local_checksum
      remote_checksum
  in
  match Sync_meta.pause metadata ~message with
  | Error message -> Error (Protocol_error message)
  | Ok metadata ->
    (match before_commit () with
     | Error message -> Error (Protocol_error message)
     | Ok () ->
       (match Storage_session.persist_sync_metadata session metadata with
        | Ok () -> Ok (Paused { metadata; basis })
        | Error error -> Error (Persistence_error (storage_error error))))
;;

let apply_advancing_pull
      decrypt_protected
      before_commit
      session
      metadata
      ~t
      ~checksum
      ~txs
  =
  let db_before = Storage_session.current_db session in
  let basis_before = basis db_before in
  match decode_transactions decrypt_protected db_before txs with
  | Error _ as error -> error
  | Ok transactions ->
    (match
       Storage_session.stage_transact_batch
         ~tx_meta:[ "rtc-tx?", Datascript.Bool true ]
         session
         transactions
     with
     | Error error -> Error (Stage_error (storage_error error))
     | Ok staged ->
       let db_after = Storage_session.staged_db_after staged in
       let local_checksum =
         Sync_checksum.recompute ~e2ee:(Sync_checksum.graph_e2ee db_after) db_after
       in
       if
         match checksum with
         | Some remote -> not (String.equal local_checksum remote)
         | None -> false
       then
         pause
           before_commit
           session
           metadata
           ~basis:basis_before
           ~remote_t:t
           ~local_checksum
           ~remote_checksum:(Option.get checksum)
       else (
         let checksum = Option.value checksum ~default:local_checksum in
         match Sync_meta.advance metadata ~applied_server_t:t ~checksum with
         | Error message -> Error (Protocol_error message)
         | Ok metadata ->
           let tx_data = Storage_session.staged_tx_data staged in
           let basis_after = basis db_after in
           let changed_uuids = changed_uuids ~db_before ~db_after tx_data in
           (match before_commit () with
            | Error message -> Error (Protocol_error message)
            | Ok () ->
              (match
                 Storage_session.commit_staged_with_sync_metadata session staged metadata
               with
               | Error error -> Error (Persistence_error (storage_error error))
               | Ok () ->
                 Ok (Applied { metadata; basis_before; basis_after; changed_uuids })))))
;;

let apply_pull
      ?(before_commit = fun () -> Ok ())
      ?decrypt_protected
      ~session
      ~metadata
      message
  =
  match metadata.Sync_meta.status with
  | Paused ->
    Error
      (Sync_paused (Option.value metadata.last_error ~default:"persistent sync error"))
  | Active ->
    (match message with
     | Sync_protocol.Pull_ok { t; checksum; txs } ->
       (match
          Sync_protocol.validate_pull_continuity
            ~applied_t:metadata.applied_server_t
            message
        with
        | Error message -> Error (Protocol_error message)
        | Ok () ->
          let db = Storage_session.current_db session in
          let current_basis = basis db in
          if t <> metadata.applied_server_t
          then
            apply_advancing_pull
              decrypt_protected
              before_commit
              session
              metadata
              ~t
              ~checksum
              ~txs
          else if
            match checksum with
            | Some remote -> String.equal metadata.checksum remote
            | None -> true
          then Ok (Duplicate { metadata; basis = current_basis })
          else
            pause
              before_commit
              session
              metadata
              ~basis:current_basis
              ~remote_t:t
              ~local_checksum:metadata.checksum
              ~remote_checksum:(Option.get checksum))
     | _ -> Error (Protocol_error "sync replay requires a pull/ok message"))
;;
