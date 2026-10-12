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
  | Terminal_stale of
      { through : Types.server_cursor
      ; executed_through : Types.server_cursor option
      }
  | Terminal_accepted of Types.acceptance_barrier
  | Terminal_proven_unexecuted of
      { mutation_id : Graph.Uuid.t
      ; fingerprint : string
      }

type simple_mutation_receipt_v1 =
  { fingerprint : string
  ; format_version : int
  ; mutation_id : string
  ; status : Json.local_status
  }
[@@deriving yojson]

type discarded_mutation_receipt_v1 =
  { fingerprint : string
  ; format_version : int
  ; mutation_id : string
  ; prior_reason :
      (Types.block_reason
      [@to_yojson Json.block_reason_to_yojson] [@of_yojson Json.block_reason_of_yojson])
  }
[@@deriving yojson]

type remote_won_mutation_receipt_v1 =
  { batch_id : string option
  ; conflicts : Json.delete_conflict_kind list
  ; earliest_conflict_cursor : string option
  ; fingerprint : string
  ; format_version : int
  ; mutation_id : string
  ; reason : Json.remote_won_reason
  ; rejection_through : string option
  ; t_before : string option
  }
[@@deriving yojson]

type mutation_receipt_wire =
  | Simple of simple_mutation_receipt_v1
  | Discarded of discarded_mutation_receipt_v1
  | Remote_won of remote_won_mutation_receipt_v1
[@@deriving yojson]

let receipt_key = Mutation_receipt.mutation_key

let encode_mutation (mutation_id, fingerprint, entry) =
  let json =
    match entry with
    | Commit_receipt commit ->
      Simple
        { fingerprint
        ; format_version = 2
        ; mutation_id = Graph.Uuid.to_string mutation_id
        ; status =
            (if commit.status = Types.No_change then Types.No_change else Types.Applied)
        }
    | Discarded_receipt (_, prior_reason) ->
      Discarded
        { fingerprint
        ; format_version = 2
        ; mutation_id = Graph.Uuid.to_string mutation_id
        ; prior_reason
        }
    | Remote_won_entry receipt ->
      let proof = receipt.Types.proof in
      Remote_won
        { batch_id =
            Option.map
              Types.Submission_batch_id.to_string
              (Types.remote_won_proof_batch_id proof)
        ; conflicts = Types.delete_conflict_kinds receipt.conflicts
        ; earliest_conflict_cursor =
            Option.map
              Persistence_json.server_cursor_to_string
              (Types.remote_won_proof_earliest_conflict_cursor proof)
        ; fingerprint
        ; format_version = 2
        ; mutation_id = Graph.Uuid.to_string mutation_id
        ; reason = receipt.reason
        ; rejection_through =
            Option.map
              Persistence_json.server_cursor_to_string
              (Types.remote_won_proof_rejection_through proof)
        ; t_before =
            Option.map
              Persistence_json.server_cursor_to_string
              (Types.remote_won_proof_t_before proof)
        }
  in
  Some
    (receipt_key mutation_id, Yojson.Safe.to_string (mutation_receipt_wire_to_yojson json))
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

let decode_simple
      ~startup_generation
      ~projection_revision
      ~key
      (receipt : simple_mutation_receipt_v1)
  =
  if receipt.format_version <> 2
  then Error "unsupported mutation receipt JSON format"
  else if String.length receipt.fingerprint <> 64
  then Error "invalid canonical mutation receipt"
  else
    let* mutation_id = Graph.Uuid.of_string receipt.mutation_id in
    if not (String.equal key (receipt_key mutation_id))
    then Error "mutation receipt key does not match its UUID"
    else
      let* status =
        match receipt.status with
        | Types.Applied -> Ok Types.Applied
        | Types.No_change -> Ok Types.No_change
        | _ -> Error "invalid canonical mutation receipt"
      in
      Ok
        ( mutation_id
        , receipt.fingerprint
        , commit_entry ~startup_generation ~projection_revision mutation_id status )
;;

let decode_discarded
      ~startup_generation
      ~projection_revision
      ~key
      (receipt : discarded_mutation_receipt_v1)
  =
  if receipt.format_version <> 2
  then Error "unsupported mutation receipt JSON format"
  else if String.length receipt.fingerprint <> 64
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

let decode_remote_won ~key (receipt : remote_won_mutation_receipt_v1) =
  if receipt.format_version <> 2
  then Error "unsupported mutation receipt JSON format"
  else if String.length receipt.fingerprint <> 64
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
      let reason = receipt.reason in
      let conflict_kinds = receipt.conflicts in
      let* conflicts = Types.delete_conflict_kind_set conflict_kinds in
      let* batch_id =
        optional_token Types.Submission_batch_id.of_string receipt.batch_id
      in
      let* t_before =
        optional_token Persistence_json.server_cursor_of_string receipt.t_before
      in
      let* rejection_through =
        optional_token Persistence_json.server_cursor_of_string receipt.rejection_through
      in
      let* earliest_conflict_cursor =
        optional_token
          Persistence_json.server_cursor_of_string
          receipt.earliest_conflict_cursor
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
    let* receipt =
      Logseq_db_types.Json_codec.decode
        mutation_receipt_wire_of_yojson
        (Yojson.Safe.from_string source)
      |> Result.map_error (fun error ->
        "unsupported or invalid mutation receipt: " ^ error)
    in
    match receipt with
    | Simple receipt ->
      decode_simple ~startup_generation ~projection_revision ~key receipt
    | Discarded receipt ->
      decode_discarded ~startup_generation ~projection_revision ~key receipt
    | Remote_won receipt -> decode_remote_won ~key receipt
  with
  | Yojson.Json_error _ -> Error "unsupported or invalid mutation receipt JSON"
;;

type accepted_terminal_batch_receipt_v1 =
  { batch_id : string
  ; format_version : int
  ; checksum : string
  ; through : string
  }
[@@deriving yojson]

type proven_unexecuted_terminal_batch_receipt_v1 =
  { batch_id : string
  ; format_version : int
  ; fingerprint : string
  ; mutation_id : string
  }
[@@deriving yojson]

type stale_terminal_batch_receipt_v1 =
  { batch_id : string
  ; format_version : int
  ; through : string
  ; executed_through : string option
  }
[@@deriving yojson]

type terminal_batch_wire =
  | Stale of stale_terminal_batch_receipt_v1
  | Accepted of accepted_terminal_batch_receipt_v1
  | Proven_unexecuted of proven_unexecuted_terminal_batch_receipt_v1
[@@deriving yojson]

let terminal_batch_key = Mutation_receipt.terminal_batch_key

let encode_terminal_batch receipt =
  let json =
    match receipt.terminal_outcome with
    | Terminal_stale { through; executed_through } ->
      Stale
        { batch_id = Types.Submission_batch_id.to_string receipt.terminal_batch_id
        ; format_version = 2
        ; through = Persistence_json.server_cursor_to_string through
        ; executed_through =
            Option.map Persistence_json.server_cursor_to_string executed_through
        }
    | Terminal_accepted barrier ->
      Accepted
        { batch_id = Types.Submission_batch_id.to_string receipt.terminal_batch_id
        ; format_version = 2
        ; checksum = Types.Checksum.to_string barrier.checksum
        ; through = Persistence_json.server_cursor_to_string barrier.through
        }
    | Terminal_proven_unexecuted { mutation_id; fingerprint } ->
      Proven_unexecuted
        { batch_id = Types.Submission_batch_id.to_string receipt.terminal_batch_id
        ; format_version = 2
        ; fingerprint
        ; mutation_id = Graph.Uuid.to_string mutation_id
        }
  in
  ( terminal_batch_key receipt.terminal_batch_id
  , Yojson.Safe.to_string (terminal_batch_wire_to_yojson json) )
;;

let decode_terminal_batch (key, source) =
  try
    let* receipt =
      Logseq_db_types.Json_codec.decode
        terminal_batch_wire_of_yojson
        (Yojson.Safe.from_string source)
      |> Result.map_error (fun error ->
        "unsupported or invalid terminal batch receipt: " ^ error)
    in
    match receipt with
    | Stale receipt ->
      let* terminal_batch_id = Types.Submission_batch_id.of_string receipt.batch_id in
      let* through = Persistence_json.server_cursor_of_string receipt.through in
      let* executed_through =
        match receipt.executed_through with
        | None -> Ok None
        | Some value ->
          Result.map Option.some (Persistence_json.server_cursor_of_string value)
      in
      if
        receipt.format_version <> 2
        || not (String.equal key (terminal_batch_key terminal_batch_id))
      then Error "invalid stale terminal batch identity or version"
      else
        Ok
          { terminal_batch_id
          ; terminal_outcome = Terminal_stale { through; executed_through }
          }
    | Accepted receipt ->
      let* terminal_batch_id = Types.Submission_batch_id.of_string receipt.batch_id in
      if
        receipt.format_version <> 2
        || not (String.equal key (terminal_batch_key terminal_batch_id))
      then Error "invalid terminal batch receipt identity or version"
      else
        let* checksum = Types.Checksum.of_string receipt.checksum in
        let* through = Persistence_json.server_cursor_of_string receipt.through in
        Ok
          { terminal_batch_id
          ; terminal_outcome = Terminal_accepted Types.{ through; checksum }
          }
    | Proven_unexecuted receipt ->
      let* terminal_batch_id = Types.Submission_batch_id.of_string receipt.batch_id in
      if
        receipt.format_version <> 2
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
  with
  | Yojson.Json_error _ -> Error "invalid terminal batch receipt JSON"
;;
