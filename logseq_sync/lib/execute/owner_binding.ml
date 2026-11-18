module Dsl = Sync_dsl.Core

type ('database, 'inspection, 'input, 'prepared) backend =
  { same_input : 'input -> 'input -> bool
  ; prepare : 'inspection -> 'input -> ('prepared, Dsl.error) result
  ; commit : 'prepared -> ('inspection, Dsl.error) result
  ; cancel : 'prepared -> unit
  ; open_committed : 'inspection -> ('database, Dsl.error) result
  }

type ('database, 'inspection, 'input, 'prepared) state =
  | Absent of 'inspection * ('database, 'inspection, 'input, 'prepared) backend
  | Committed of
      'inspection * ('database, 'inspection, 'input, 'prepared) backend * 'input
  | Active of
      'database * ('input * ('database, 'inspection, 'input, 'prepared) backend) option

type ('database, 'inspection, 'input, 'prepared) t =
  { queue : Eio.Mutex.t
  ; mutable state : ('database, 'inspection, 'input, 'prepared) state
  }

let active database = { queue = Eio.Mutex.create (); state = Active (database, None) }

let absent inspection backend =
  { queue = Eio.Mutex.create (); state = Absent (inspection, backend) }
;;

let database owner =
  match owner.state with
  | Active (database, _) -> Ok database
  | Absent _ -> Error (Dsl.Storage_failure "Mirror activation required")
  | Committed _ -> Error (Dsl.Storage_failure "Committed mirror requires open recovery")
;;

let ( let* ) = Result.bind

let with_database owner ~check_current callback =
  let* () = check_current () in
  Eio.Mutex.use_rw ~protect:false owner.queue (fun () ->
    let* () = check_current () in
    let* database = database owner in
    callback database)
;;

let activate owner ~check_current input =
  let* () = check_current () in
  Eio.Mutex.use_rw ~protect:false owner.queue (fun () ->
    let* () = check_current () in
    let open_committed backend inspection =
      Eio.Cancel.protect (fun () ->
        let* database = backend.open_committed inspection in
        owner.state <- Active (database, Some (input, backend));
        let* () = check_current () in
        Ok database)
    in
    match owner.state with
    | Active (database, Some (original, backend)) when backend.same_input original input
      -> Ok database
    | Active _ -> Error Dsl.Stale_context
    | Committed (inspection, backend, original) ->
      if backend.same_input original input
      then open_committed backend inspection
      else Error Dsl.Stale_context
    | Absent (inspection, backend) ->
      let* prepared = backend.prepare inspection input in
      Fun.protect
        ~finally:(fun () -> Eio.Cancel.protect (fun () -> backend.cancel prepared))
        (fun () ->
           let* () = check_current () in
           let* committed =
             Eio.Cancel.protect (fun () ->
               let* () = check_current () in
               let* committed = backend.commit prepared in
               owner.state <- Committed (committed, backend, input);
               Ok committed)
           in
           let* () = check_current () in
           open_committed backend committed))
;;
