type reason =
  | Storage_failure
  | Lifecycle_outcome_unknown

type tombstone = { reason : reason }

type mutation_kind =
  | Capture
  | Create_child
  | Update_content
  | Set_task_state

type pending_command =
  { mutation_id : string
  ; affected_block_ids : string list
  ; kind : mutation_kind
  ; expected_revision : int option
  ; content : string
  }

type pending_status =
  | Accepted
  | Outcome_unknown

type pending =
  { runtime_epoch : Bonsai_flutter_spec.Id.Runtime.epoch
  ; worker_generation : Bonsai_flutter_spec.Id.Worker.generation
  ; request_id : Bonsai_flutter_spec.Id.Worker.request_id
  ; command : pending_command
  ; status : pending_status
  }

module Pending_error = struct
  type t =
    | Full
    | Block_busy
    | Invalid of string

  let to_string = function
    | Full -> "accepted mutation registry is full"
    | Block_busy -> "an accepted mutation already touches this block"
    | Invalid message -> "invalid accepted mutation: " ^ message
  ;;

  let is_full = function
    | Full -> true
    | Block_busy | Invalid _ -> false
  ;;

  let is_block_busy = function
    | Block_busy -> true
    | Full | Invalid _ -> false
  ;;

  let is_invalid = function
    | Invalid _ -> true
    | Full | Block_busy -> false
  ;;
end

let mutex = Mutex.create ()
let tombstones : (string, tombstone) Hashtbl.t = Hashtbl.create 8
let pending_mutations : (string, pending) Hashtbl.t = Hashtbl.create 8

let with_lock callback =
  Mutex.lock mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock mutex) callback
;;

let quarantine ~canonical_path reason =
  with_lock (fun () ->
    if not (Hashtbl.mem tombstones canonical_path)
    then Hashtbl.add tombstones canonical_path { reason })
;;

let find_tombstone ~canonical_path =
  with_lock (fun () -> Hashtbl.find_opt tombstones canonical_path)
;;

let reason tombstone = tombstone.reason

let validate_command command =
  if not (Journal_validation.is_uuid command.mutation_id)
  then Error (Pending_error.Invalid "mutation ID must be a UUID")
  else if command.affected_block_ids = []
  then Error (Pending_error.Invalid "at least one affected block is required")
  else if not (List.for_all Journal_validation.is_uuid command.affected_block_ids)
  then Error (Pending_error.Invalid "affected block IDs must be UUIDs")
  else if
    List.length (List.sort_uniq String.compare command.affected_block_ids)
    <> List.length command.affected_block_ids
  then Error (Pending_error.Invalid "affected block IDs must be unique")
  else if String.length command.content > 65_536
  then Error (Pending_error.Invalid "content exceeds 65,536 UTF-8 bytes")
  else if not (Journal_validation.is_valid_utf_8 command.content)
  then Error (Pending_error.Invalid "content is not valid UTF-8")
  else (
    match command.expected_revision with
    | Some revision when revision < 1 ->
      Error (Pending_error.Invalid "expected revision must be positive")
    | None | Some _ -> Ok ())
;;

let touches_block pending block_id =
  List.exists (String.equal block_id) pending.command.affected_block_ids
;;

let any_block_busy command =
  Hashtbl.to_seq_values pending_mutations
  |> Seq.exists (fun pending ->
    List.exists (touches_block pending) command.affected_block_ids)
;;

let request_id_in_use request_id =
  Hashtbl.to_seq_values pending_mutations
  |> Seq.exists (fun pending ->
    Bonsai_flutter_spec.Id.Worker.Request_id.equal pending.request_id request_id)
;;

let admission_error command =
  match Hashtbl.find_opt pending_mutations command.mutation_id with
  | Some _ -> Some (Pending_error.Invalid "mutation ID was reused")
  | None when Hashtbl.length pending_mutations >= 8 -> Some Pending_error.Full
  | None when any_block_busy command -> Some Pending_error.Block_busy
  | None -> None
;;

let check_admission command =
  match validate_command command with
  | Error _ as error -> error
  | Ok () ->
    with_lock (fun () ->
      match admission_error command with
      | None -> Ok ()
      | Some error -> Error error)
;;

let record_accepted ~runtime_epoch ~worker_generation ~request_id command =
  match validate_command command with
  | Error _ as error -> error
  | Ok () ->
    with_lock (fun () ->
      match Hashtbl.find_opt pending_mutations command.mutation_id with
      | Some pending
        when pending.command = command
             && Bonsai_flutter_spec.Id.Worker.Request_id.equal
                  pending.request_id
                  request_id -> Ok ()
      | Some _ -> Error (Pending_error.Invalid "mutation ID was reused")
      | None ->
        (match admission_error command with
         | Some error -> Error error
         | None when request_id_in_use request_id ->
           Error (Pending_error.Invalid "Worker request ID is already pending")
         | None ->
           Hashtbl.add
             pending_mutations
             command.mutation_id
             { runtime_epoch; worker_generation; request_id; command; status = Accepted };
           Ok ()))
;;

let find_pending ~mutation_id =
  with_lock (fun () -> Hashtbl.find_opt pending_mutations mutation_id)
;;

let find_pending_by_request_id request_id =
  with_lock (fun () ->
    Hashtbl.to_seq_values pending_mutations
    |> Seq.find (fun pending ->
      Bonsai_flutter_spec.Id.Worker.Request_id.equal pending.request_id request_id))
;;

let pending_commands () =
  with_lock (fun () ->
    Hashtbl.to_seq_values pending_mutations
    |> List.of_seq
    |> List.sort (fun left right ->
      String.compare left.command.mutation_id right.command.mutation_id))
;;

let record_reconciliation_accepted
      ~runtime_epoch
      ~worker_generation
      ~request_id
      ~mutation_id
  =
  with_lock (fun () ->
    match Hashtbl.find_opt pending_mutations mutation_id with
    | None -> Error (Pending_error.Invalid "reconciled mutation is not pending")
    | Some pending ->
      let request_id_conflict =
        Hashtbl.to_seq_values pending_mutations
        |> Seq.exists (fun candidate ->
          (not (String.equal candidate.command.mutation_id mutation_id))
          && Bonsai_flutter_spec.Id.Worker.Request_id.equal
               candidate.request_id
               request_id)
      in
      if request_id_conflict
      then Error (Pending_error.Invalid "Worker request ID is already pending")
      else (
        Hashtbl.replace
          pending_mutations
          mutation_id
          { pending with runtime_epoch; worker_generation; request_id };
        Ok ()))
;;

let mark_outcome_unknown ~mutation_id =
  with_lock (fun () ->
    match Hashtbl.find_opt pending_mutations mutation_id with
    | None -> ()
    | Some pending ->
      Hashtbl.replace
        pending_mutations
        mutation_id
        { pending with status = Outcome_unknown })
;;

let clear_known_outcome ~mutation_id =
  with_lock (fun () -> Hashtbl.remove pending_mutations mutation_id)
;;
