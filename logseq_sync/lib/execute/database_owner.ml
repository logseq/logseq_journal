module Dsl = Sync_dsl.Core
module Overlay = Logseq_overlay_db
module Database = Overlay.Database
module Types = Overlay.Types

let ( let* ) = Result.bind

type activation_input =
  { snapshot : Dsl.snapshot
  ; path : string
  ; expected_rows : int
  ; unprotect :
      Database.unprotection_request
      -> ((Types.crypto_item_id * string) list, Dsl.error) result
  }

type preparation =
  { staged : Database.prepared_snapshot_activation
  ; check_current : unit -> (unit, Dsl.error) result
  ; unprotect :
      Database.unprotection_request
      -> ((Types.crypto_item_id * string) list, Dsl.error) result
  }

type t =
  ( Database.t
    , Database.mirror_inspection
    , activation_input * (unit -> (unit, Dsl.error) result)
    , preparation )
    Owner_binding.t

let database_owner = Owner_binding.active
let database_if_open = Owner_binding.database_if_open
let database = Owner_binding.database
let with_database = Owner_binding.with_database

let activation_result = function
  | Ok value -> Ok value
  | Error error -> Error (Dsl.Activation_failure error)
;;

let rec unprotect preparation =
  let* () = preparation.check_current () in
  let* request =
    activation_result (Database.next_snapshot_unprotection_batch preparation.staged)
  in
  match request with
  | None -> Ok ()
  | Some request ->
    let* plaintexts = preparation.unprotect request in
    let* () = preparation.check_current () in
    let* () =
      activation_result
        (Database.supply_snapshot_unprotection_batch
           preparation.staged
           ~request
           ~plaintexts)
    in
    unprotect preparation
;;

let open_error = function
  | Types.Mirror_absent -> "Mirror absent after activation"
  | Invalid_graph_name -> "Invalid graph name"
  | Ownership_conflict -> "Database ownership conflict"
  | Attachment_stale -> "Committed inspection is stale"
  | Restore_failed message -> "Restore failed: " ^ message
  | Corrupt_authoritative_store message -> "Corrupt authoritative store: " ^ message
  | Corrupt_outbox message -> "Corrupt outbox: " ^ message
  | Corrupt_mutation_receipt message -> "Corrupt mutation receipt: " ^ message
  | Open_resource_failed message -> "Database open failed: " ^ message
;;

let activation_owner ~sw ~dependencies ~inspection ~graph_name =
  let backend =
    { Owner_binding.same_input =
        (fun (left, _) (right, _) ->
          left.snapshot = right.snapshot
          && left.path = right.path
          && left.expected_rows = right.expected_rows)
    ; prepare =
        (fun inspection ((input : activation_input), check_current) ->
          let* () = check_current () in
          let* checksum =
            match Types.Checksum.of_string input.snapshot.checksum with
            | Ok checksum -> Ok checksum
            | Error message -> Error (Dsl.Invalid_input message)
          in
          let* staged =
            activation_result
              (Database.prepare_snapshot_activation
                 dependencies
                 inspection
                 ~path:input.path
                 ~applied_server_cursor:input.snapshot.through
                 ~expected_checksum:(Some checksum)
                 ~expected_rows:input.expected_rows)
          in
          let preparation = { staged; check_current; unprotect = input.unprotect } in
          let transferred = ref false in
          Fun.protect
            ~finally:(fun () ->
              if not !transferred
              then
                Eio.Cancel.protect (fun () -> Database.cancel_snapshot_activation staged))
            (fun () ->
               let* () = unprotect preparation in
               transferred := true;
               Ok preparation))
    ; commit =
        (fun preparation ->
          let* () = preparation.check_current () in
          activation_result (Database.commit_snapshot_activation preparation.staged))
    ; cancel = (fun preparation -> Database.cancel_snapshot_activation preparation.staged)
    ; open_committed =
        (fun inspection ->
          match Database.open_ ~sw dependencies inspection ~graph_name with
          | Ok database -> Ok database
          | Error error -> Error (Dsl.Storage_failure (open_error error)))
    }
  in
  Owner_binding.absent inspection backend
;;

let activate_snapshot owner ~check_current input =
  let* database = Owner_binding.activate owner ~check_current (input, check_current) in
  let* snapshot =
    match Database.current_snapshot database with
    | Ok snapshot -> Ok snapshot
    | Error _ ->
      Error (Dsl.Storage_failure "Cannot inspect activated database generation")
  in
  Fun.protect
    ~finally:(fun () -> Database.release_snapshot snapshot)
    (fun () ->
       let version = Database.snapshot_version snapshot in
       Ok (Dsl.Activated version.generation))
;;
