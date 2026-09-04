module Graph = Logseq_db_types.Graph_types
module Json = Persistence_json

let ( let* ) = Result.bind

let list_map_result decode values =
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
      let* decoded = decode value in
      loop (decoded :: reversed) rest
  in
  loop [] values
;;

type entry =
  | Commit_receipt of Types.local_commit
  | Discarded_receipt of Types.blocked_discard_commit * Types.block_reason
  | Remote_won_entry of Types.remote_won_receipt

type terminal_batch_receipt =
  { terminal_batch_id : Types.submission_batch_id
  ; terminal_outcome : terminal_batch_outcome
  }

and terminal_batch_outcome =
  | Terminal_accepted of Types.acceptance_barrier
  | Terminal_proven_unexecuted of
      { mutation_id : Graph.Uuid.t
      ; fingerprint : string
      }

type simple_mutation_receipt_v1 =
  { fingerprint : string
  ; format_version : int [@key "formatVersion"]
  ; mutation_id : string [@key "mutationId"]
  ; outcome : string
  }
[@@deriving yojson]

type discarded_mutation_receipt_v1 =
  { fingerprint : string
  ; format_version : int [@key "formatVersion"]
  ; mutation_id : string [@key "mutationId"]
  ; outcome : string
  ; prior_reason :
      (Types.block_reason
      [@to_yojson Json.block_reason_to_yojson] [@of_yojson Json.block_reason_of_yojson])
        [@key "priorReason"]
  }
[@@deriving yojson]

type remote_won_mutation_receipt_v1 =
  { batch_id : string option [@key "batchId"]
  ; conflicts : string list
  ; earliest_conflict_cursor : string option [@key "earliestConflictCursor"]
  ; fingerprint : string
  ; format_version : int [@key "formatVersion"]
  ; mutation_id : string [@key "mutationId"]
  ; operation : string
  ; outcome : string
  ; reason : string
  ; rejection_through : string option [@key "rejectionThrough"]
  ; t_before : string option [@key "tBefore"]
  }
[@@deriving yojson { strict = false }]

let receipt_key = Mutation_receipt.mutation_key

let encode_mutation (mutation_id, fingerprint, entry) =
  let json =
    match entry with
    | Commit_receipt commit ->
      simple_mutation_receipt_v1_to_yojson
        { fingerprint
        ; format_version = 1
        ; mutation_id = Graph.Uuid.to_string mutation_id
        ; outcome = (if commit.status = Types.No_change then "noChange" else "applied")
        }
    | Discarded_receipt (_, prior_reason) ->
      discarded_mutation_receipt_v1_to_yojson
        { fingerprint
        ; format_version = 1
        ; mutation_id = Graph.Uuid.to_string mutation_id
        ; outcome = "discarded"
        ; prior_reason
        }
    | Remote_won_entry receipt ->
      let proof = receipt.Types.proof in
      remote_won_mutation_receipt_v1_to_yojson
        { batch_id =
            Option.map
              Types.Submission_batch_id.to_string
              (Types.remote_won_proof_batch_id proof)
        ; conflicts =
            Types.delete_conflict_kinds receipt.conflicts |> List.map Delete_conflict.code
        ; earliest_conflict_cursor =
            Option.map
              Types.Server_cursor.to_string
              (Types.remote_won_proof_earliest_conflict_cursor proof)
        ; fingerprint
        ; format_version = 1
        ; mutation_id = Graph.Uuid.to_string mutation_id
        ; operation = "deleteBlocks"
        ; outcome = "remoteWon"
        ; reason =
            (match receipt.reason with
             | Before_submission -> "beforeSubmission"
             | Proven_unexecuted -> "provenUnexecuted")
        ; rejection_through =
            Option.map
              Types.Server_cursor.to_string
              (Types.remote_won_proof_rejection_through proof)
        ; t_before =
            Option.map
              Types.Server_cursor.to_string
              (Types.remote_won_proof_t_before proof)
        }
  in
  Some (receipt_key mutation_id, Yojson.Safe.to_string json)
;;

let optional_token parse = function
  | None -> Ok None
  | Some value -> Result.map Option.some (parse value)
;;

let commit_entry ~startup_generation ~projection_revision mutation_id status =
  Commit_receipt
    { Types.mutation_id
    ; status
    ; generation = startup_generation
    ; before_projection_revision = projection_revision
    ; after_projection_revision = projection_revision
    ; logical_change_summary = No_logical_change
    }
;;

let decode_simple ~startup_generation ~projection_revision ~key json =
  let* receipt = simple_mutation_receipt_v1_of_yojson json in
  if
    simple_mutation_receipt_v1_to_yojson receipt <> json
    || receipt.format_version <> 1
    || String.length receipt.fingerprint <> 64
  then Error "invalid canonical mutation receipt"
  else
    let* mutation_id = Graph.Uuid.of_string receipt.mutation_id in
    if not (String.equal key (receipt_key mutation_id))
    then Error "mutation receipt key does not match its UUID"
    else
      let* status =
        match receipt.outcome with
        | "applied" -> Ok Types.Applied
        | "noChange" -> Ok Types.No_change
        | _ -> Error "invalid canonical mutation receipt"
      in
      Ok
        ( mutation_id
        , receipt.fingerprint
        , commit_entry ~startup_generation ~projection_revision mutation_id status )
;;

let decode_discarded ~startup_generation ~projection_revision ~key json =
  let* receipt = discarded_mutation_receipt_v1_of_yojson json in
  if
    discarded_mutation_receipt_v1_to_yojson receipt <> json
    || receipt.format_version <> 1
    || (not (String.equal receipt.outcome "discarded"))
    || String.length receipt.fingerprint <> 64
  then Error "invalid canonical mutation receipt"
  else
    let* mutation_id = Graph.Uuid.of_string receipt.mutation_id in
    if not (String.equal key (receipt_key mutation_id))
    then Error "mutation receipt key does not match its UUID"
    else
      Ok
        ( mutation_id
        , receipt.fingerprint
        , Discarded_receipt
            ( { Types.mutation_id
              ; generation = startup_generation
              ; before_projection_revision = projection_revision
              ; after_projection_revision = projection_revision
              ; logical_change_summary = No_logical_change
              }
            , receipt.prior_reason ) )
;;

let decode_remote_won ~key json =
  let* receipt = remote_won_mutation_receipt_v1_of_yojson json in
  if
    receipt.format_version <> 1
    || (not (String.equal receipt.operation "deleteBlocks"))
    || (not (String.equal receipt.outcome "remoteWon"))
    || String.length receipt.fingerprint <> 64
  then Error "invalid remote-won receipt version or operation"
  else
    let* mutation_id = Graph.Uuid.of_string receipt.mutation_id in
    if not (String.equal key (receipt_key mutation_id))
    then Error "mutation receipt key does not match its UUID"
    else
      let* fingerprint =
        Types.Mutation_fingerprint.of_string
          ("mutation-fingerprint:v1:" ^ receipt.fingerprint)
      in
      let* reason =
        match receipt.reason with
        | "beforeSubmission" -> Ok Types.Before_submission
        | "provenUnexecuted" -> Ok Types.Proven_unexecuted
        | _ -> Error "invalid remote-won reason"
      in
      let* conflict_kinds = list_map_result Delete_conflict.of_code receipt.conflicts in
      let* conflicts = Types.delete_conflict_kind_set conflict_kinds in
      let* batch_id =
        optional_token Types.Submission_batch_id.of_string receipt.batch_id
      in
      let* t_before = optional_token Types.Server_cursor.of_string receipt.t_before in
      let* rejection_through =
        optional_token Types.Server_cursor.of_string receipt.rejection_through
      in
      let* earliest_conflict_cursor =
        optional_token Types.Server_cursor.of_string receipt.earliest_conflict_cursor
      in
      let* proof =
        Types.remote_won_proof
          ~reason
          ~batch_id
          ~t_before
          ~rejection_through
          ~earliest_conflict_cursor
          ~operation:Delete_blocks_operation
          ~digest:fingerprint
      in
      Ok
        ( mutation_id
        , receipt.fingerprint
        , Remote_won_entry Types.{ mutation_id; fingerprint; reason; conflicts; proof } )
;;

let decode_mutation ~startup_generation ~projection_revision (key, source) =
  try
    let json = Yojson.Safe.from_string source in
    match json with
    | `Assoc fields ->
      (match List.assoc_opt "outcome" fields with
       | Some (`String "remoteWon") -> decode_remote_won ~key json
       | Some (`String "discarded") ->
         decode_discarded ~startup_generation ~projection_revision ~key json
       | Some (`String ("applied" | "noChange")) ->
         decode_simple ~startup_generation ~projection_revision ~key json
       | _ -> Error "invalid canonical mutation receipt")
    | _ -> Error "invalid canonical mutation receipt"
  with
  | Yojson.Json_error _ -> Error "invalid mutation receipt JSON"
;;

type accepted_terminal_batch_receipt_v1 =
  { batch_id : string [@key "batchId"]
  ; format_version : int [@key "formatVersion"]
  ; checksum : string
  ; receipt_type : string [@key "receiptType"]
  ; through : string
  }
[@@deriving yojson { strict = false }]

type proven_unexecuted_terminal_batch_receipt_v1 =
  { batch_id : string [@key "batchId"]
  ; format_version : int [@key "formatVersion"]
  ; fingerprint : string
  ; mutation_id : string [@key "mutationId"]
  ; receipt_type : string [@key "receiptType"]
  }
[@@deriving yojson { strict = false }]

let terminal_batch_key = Mutation_receipt.terminal_batch_key

let encode_terminal_batch receipt =
  let json =
    match receipt.terminal_outcome with
    | Terminal_accepted barrier ->
      accepted_terminal_batch_receipt_v1_to_yojson
        { batch_id = Types.Submission_batch_id.to_string receipt.terminal_batch_id
        ; format_version = 1
        ; checksum = Types.Checksum.to_string barrier.checksum
        ; receipt_type = "acceptedBatch"
        ; through = Types.Server_cursor.to_string barrier.through
        }
    | Terminal_proven_unexecuted { mutation_id; fingerprint } ->
      proven_unexecuted_terminal_batch_receipt_v1_to_yojson
        { batch_id = Types.Submission_batch_id.to_string receipt.terminal_batch_id
        ; format_version = 1
        ; fingerprint
        ; mutation_id = Graph.Uuid.to_string mutation_id
        ; receipt_type = "provenUnexecutedBatch"
        }
  in
  terminal_batch_key receipt.terminal_batch_id, Yojson.Safe.to_string json
;;

let decode_terminal_batch (key, source) =
  try
    let json = Yojson.Safe.from_string source in
    match json with
    | `Assoc fields ->
      (match List.assoc_opt "receiptType" fields with
       | Some (`String "acceptedBatch") ->
         let* receipt = accepted_terminal_batch_receipt_v1_of_yojson json in
         let* terminal_batch_id = Types.Submission_batch_id.of_string receipt.batch_id in
         if
           receipt.format_version <> 1
           || not (String.equal key (terminal_batch_key terminal_batch_id))
         then Error "invalid terminal batch receipt identity or version"
         else
           let* checksum = Types.Checksum.of_string receipt.checksum in
           let* through = Types.Server_cursor.of_string receipt.through in
           Ok
             { terminal_batch_id
             ; terminal_outcome = Terminal_accepted Types.{ through; checksum }
             }
       | Some (`String "provenUnexecutedBatch") ->
         let* receipt = proven_unexecuted_terminal_batch_receipt_v1_of_yojson json in
         let* terminal_batch_id = Types.Submission_batch_id.of_string receipt.batch_id in
         if
           receipt.format_version <> 1
           || not (String.equal key (terminal_batch_key terminal_batch_id))
         then Error "invalid terminal batch receipt identity or version"
         else if String.length receipt.fingerprint <> 64
         then Error "invalid terminal batch fingerprint"
         else
           let* mutation_id = Graph.Uuid.of_string receipt.mutation_id in
           Ok
             { terminal_batch_id
             ; terminal_outcome =
                 Terminal_proven_unexecuted
                   { mutation_id; fingerprint = receipt.fingerprint }
             }
       | _ -> Error "invalid terminal batch receipt type")
    | _ -> Error "invalid canonical terminal batch receipt"
  with
  | Yojson.Json_error _ -> Error "invalid terminal batch receipt JSON"
;;
