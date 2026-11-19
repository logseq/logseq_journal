module Dsl = Sync_dsl.Core
module Protocol = Logseq_sync_protocol.Sync_protocol
module O = Logseq_overlay_db.Types
module Cursor = O.Server_cursor

let ( let* ) = Result.bind
let invalid message = Error (Dsl.Protocol_failure message)

let checksum value =
  O.Checksum.of_string ("checksum:v1:" ^ value)
  |> Result.map_error (fun _ -> Dsl.Protocol_failure "Invalid checksum")
;;

let optional_checksum = function
  | None -> Ok None
  | Some value -> Result.map Option.some (checksum value)
;;

let operation_name = function
  | O.Save_block_operation -> "save-block"
  | Append_journal_operation -> "append-journal"
  | Insert_blocks_operation -> "insert-blocks"
  | Delete_blocks_operation -> "delete-blocks"
  | Create_journal_page_operation -> "create-journal-page"
  | Set_task_status_operation -> "set-task-status"
  | Clear_task_status_operation -> "clear-task-status"
  | Publish_asset_operation -> "publish-asset"
  | Set_asset_reference_operation -> "set-asset-reference"
;;

let submission batch =
  Protocol.Client.Tx_batch
    { client_revision =
        Some (O.Submission_batch_id.to_string (O.submission_batch_id batch))
    ; t_before = O.submission_batch_t_before batch
    ; txs =
        List.map
          (fun wire ->
             Protocol.Client.
               { tx = O.submission_wire_protected_transaction wire
               ; tx_id = Some (O.submission_wire_mutation_id wire)
               ; outliner_op = Some (operation_name (O.submission_wire_operation wire))
               })
          (O.submission_batch_wires batch)
    }
;;

let head = function
  | Protocol.Server.Hello { t; checksum } ->
    let* expected_checksum = optional_checksum checksum in
    Ok Dsl.{ through = t; snapshot_available = true; expected_checksum }
  | _ -> invalid "Expected hello response"
;;

let pull ~limits ~since = function
  | Protocol.Server.Pull_ok { t; checksum = value; txs } ->
    if Cursor.compare t since < 0 || List.length txs > limits.Dsl.maximum_items
    then invalid "Invalid pull bounds"
    else (
      let rec validate previous bytes accumulated = function
        | [] -> Ok (List.rev accumulated)
        | (entry : Protocol.Server.pull_transaction) :: rest ->
          let length = String.length entry.tx in
          if
            (match previous with
             | Some cursor -> Cursor.compare entry.t cursor <= 0
             | None -> false)
            || Cursor.compare entry.t t > 0
            || length > limits.maximum_message_bytes
            || bytes > limits.maximum_bytes - length
          then invalid "Invalid authoritative transaction sequence"
          else
            let* encoded =
              O.encoded_transaction_of_string
                ~maximum_bytes:limits.maximum_message_bytes
                entry.tx
              |> Result.map_error (fun _ ->
                Dsl.Protocol_failure "Invalid authoritative transaction")
            in
            let accumulated =
              if Cursor.compare entry.t since > 0
              then
                O.authoritative_transaction ~cursor:entry.t ~transaction:encoded
                :: accumulated
              else accumulated
            in
            validate (Some entry.t) (bytes + length) accumulated rest
      in
      let* transactions = validate None 0 [] txs in
      let* checksum = optional_checksum value in
      match transactions with
      | [] -> Ok (Dsl.No_progress { since; through = t; expected_checksum = checksum })
      | _ ->
        let* batch =
          O.authoritative_batch
            ~maximum_count:limits.maximum_items
            ~maximum_bytes:limits.maximum_bytes
            ~transactions
            ~through:t
            ~checksum
          |> Result.map_error (fun _ ->
            Dsl.Protocol_failure "Invalid authoritative batch")
        in
        Ok (Dsl.Pulled batch))
  | _ -> invalid "Expected pull response"
;;

let barrier ~baseline through value =
  if Cursor.compare through baseline <= 0
  then invalid "Acceptance cursor did not advance"
  else (
    match value with
    | None -> invalid "Acceptance omitted checksum"
    | Some value ->
      let* checksum = checksum value in
      Ok O.{ through; checksum })
;;

let rejection batch (rejection : Protocol.rejection) =
  let baseline = O.submission_batch_t_before batch in
  let members = List.map O.submission_wire_mutation_id (O.submission_batch_wires batch) in
  let equal = O.Graph.Uuid.equal in
  let rec prefix members = function
    | [] -> Ok members
    | item :: rest ->
      (match members with
       | member :: members when equal member item -> prefix members rest
       | _ -> invalid "Accepted IDs are not an ordered submission prefix")
  in
  let* remaining = prefix members rejection.success_tx_ids in
  let* failed_member, unexecuted_suffix =
    match rejection.failed_tx_id, remaining with
    | Some failed, expected :: rest when equal failed expected -> Ok (Some failed, rest)
    | None, expected :: rest when rejection.success_tx_ids = [] -> Ok (Some expected, rest)
    | _ -> invalid "Rejected member does not match frozen submission"
  in
  match rejection.reason with
  | Protocol.Stale ->
    (match rejection.t with
     | Some through
       when Cursor.compare through baseline > 0 && rejection.success_tx_ids = [] ->
       Ok (O.Stale { through })
     | _ -> invalid "Invalid stale rejection cursor or partition")
  | Empty_tx_data
  | Invalid_tx
  | Invalid_t_before
  | Db_transact_failed
  | Snapshot_upload_in_progress ->
    let* acceptance_barrier =
      match rejection.success_tx_ids with
      | [] -> Ok None
      | _ ->
        (match rejection.t with
         | None -> invalid "Partial rejection omitted acceptance cursor"
         | Some through ->
           Result.map Option.some (barrier ~baseline through rejection.checksum))
    in
    let reason =
      match rejection.reason with
      | Protocol.Empty_tx_data | Invalid_tx | Invalid_t_before -> O.Invalid_request
      | Db_transact_failed when rejection.missing_block_uuids <> [] ->
        O.Missing_dependencies
      | Db_transact_failed | Snapshot_upload_in_progress | Stale -> O.Operational_failure
    in
    Ok
      (O.Definitive
         { reason
         ; partition =
             { accepted_prefix = rejection.success_tx_ids
             ; failed_member
             ; unexecuted_suffix
             ; acceptance_barrier
             ; missing_uuids = rejection.missing_block_uuids
             ; diagnostics = []
             }
         })
;;

let push ~batch = function
  | Protocol.Server.Tx_batch_ok { t; checksum } ->
    Result.map
      (fun value -> Dsl.Accepted value)
      (barrier ~baseline:(O.submission_batch_t_before batch) t checksum)
  | Protocol.Server.Tx_reject value ->
    Result.map (fun value -> Dsl.Rejected value) (rejection batch value)
  | _ -> invalid "Expected submission response"
;;
