type state =
  | Queued
  | Submitted
  | Accepted of int
  | Blocked of string

type entry =
  { mutation_id : Graph_types.Uuid.t
  ; mutation_payload : string
  ; mutation_fingerprint : string
  ; encoded_tx : string
  ; outliner_op : string
  ; state : state
  }

let maximum_file_bytes = 8 * 1024 * 1024
let maximum_entries = 4096

let exact_fields expected fields =
  let actual = List.map fst fields |> List.sort String.compare in
  List.sort String.compare expected = actual
;;

let state_to_json = function
  | Queued -> `Assoc [ "type", `String "queued" ]
  | Submitted -> `Assoc [ "type", `String "submitted" ]
  | Accepted t -> `Assoc [ "type", `String "accepted"; "serverT", `Int t ]
  | Blocked message -> `Assoc [ "type", `String "blocked"; "message", `String message ]
;;

let state_of_json = function
  | `Assoc ([ ("type", `String "queued") ] as fields) when exact_fields [ "type" ] fields
    -> Ok Queued
  | `Assoc ([ ("type", `String "submitted") ] as fields)
    when exact_fields [ "type" ] fields -> Ok Submitted
  | `Assoc fields when exact_fields [ "serverT"; "type" ] fields ->
    (match List.assoc_opt "type" fields, List.assoc_opt "serverT" fields with
     | Some (`String "accepted"), Some (`Int value) when value >= 0 -> Ok (Accepted value)
     | _ -> Error "invalid accepted pending state")
  | `Assoc fields when exact_fields [ "message"; "type" ] fields ->
    (match List.assoc_opt "type" fields, List.assoc_opt "message" fields with
     | Some (`String "blocked"), Some (`String message)
       when String.length message > 0 && String.length message <= 4096 ->
       Ok (Blocked message)
     | _ -> Error "invalid blocked pending state")
  | _ -> Error "invalid pending state"
;;

let entry_to_json entry =
  `Assoc
    [ "mutationId", `String (Graph_types.Uuid.to_string entry.mutation_id)
    ; "mutationPayload", `String entry.mutation_payload
    ; "mutationFingerprint", `String entry.mutation_fingerprint
    ; "outlinerOp", `String entry.outliner_op
    ; "state", state_to_json entry.state
    ; "encodedTx", `String entry.encoded_tx
    ]
;;

let entry_of_json = function
  | `Assoc fields
    when exact_fields
           [ "encodedTx"
           ; "mutationFingerprint"
           ; "mutationId"
           ; "mutationPayload"
           ; "outlinerOp"
           ; "state"
           ]
           fields ->
    (match
       ( List.assoc_opt "mutationId" fields
       , List.assoc_opt "mutationPayload" fields
       , List.assoc_opt "mutationFingerprint" fields
       , List.assoc_opt "outlinerOp" fields
       , List.assoc_opt "state" fields
       , List.assoc_opt "encodedTx" fields )
     with
     | ( Some (`String mutation_id)
       , Some (`String mutation_payload)
       , Some (`String mutation_fingerprint)
       , Some (`String outliner_op)
       , Some state
       , Some (`String encoded_tx) )
       when String.length outliner_op > 0
            && String.length outliner_op <= 128
            && String.length mutation_payload > 0
            && String.length mutation_payload <= Limits.maximum_request_bytes
            && String.length mutation_fingerprint > 0
            && String.length mutation_fingerprint <= 256
            && String.length encoded_tx > 0
            && String.length encoded_tx <= Limits.maximum_request_bytes ->
       Result.bind (Graph_types.Uuid.of_string mutation_id) (fun mutation_id ->
         Result.map
           (fun state ->
              { mutation_id
              ; mutation_payload
              ; mutation_fingerprint
              ; encoded_tx
              ; outliner_op
              ; state
              })
           (state_of_json state))
     | _ -> Error "invalid pending entry")
  | _ -> Error "invalid pending entry"
;;

let encode_record entries =
  Yojson.Safe.to_string
    (`Assoc [ "entries", `List (List.map entry_to_json entries); "version", `Int 3 ])
;;

let validate entries =
  if List.length entries > maximum_entries
  then Error "too many pending intents"
  else (
    let encoded = encode_record entries in
    if String.length encoded > maximum_file_bytes
    then Error "pending intent data exceeds its durable bound"
    else Ok entries)
;;

let append_entry entries entry =
  if
    List.exists
      (fun current -> Graph_types.Uuid.equal current.mutation_id entry.mutation_id)
      entries
  then Error "pending mutation ID already exists"
  else validate (entries @ [ entry ])
;;

let encode entries =
  Result.map
    (List.map (fun entry -> Yojson.Safe.to_string (entry_to_json entry)))
    (validate entries)
;;

let decode records =
  if List.length records > maximum_entries
  then Error "too many pending intents"
  else (
    let rec loop entries = function
      | [] -> validate (List.rev entries)
      | source :: rest ->
        (try
           match entry_of_json (Yojson.Safe.from_string source) with
           | Error _ as error -> error
           | Ok entry -> loop (entry :: entries) rest
         with
         | Yojson.Json_error _ -> Error "pending intent data is corrupt")
    in
    loop [] records)
;;
