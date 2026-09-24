type t =
  { mutex : Mutex.t
  ; mutable queue : (unit -> unit) list
  ; mutable wakeup : (unit -> unit) option
  }

let create () = { mutex = Mutex.create (); queue = []; wakeup = None }

let enqueue t thunk =
  Mutex.lock t.mutex;
  t.queue <- thunk :: t.queue;
  let wakeup = t.wakeup in
  Mutex.unlock t.mutex;
  match wakeup with
  | Some wake -> wake ()
  | None -> ()
;;

let set_wakeup t wakeup =
  Mutex.lock t.mutex;
  t.wakeup <- Some wakeup;
  let pending = t.queue <> [] in
  Mutex.unlock t.mutex;
  if pending then wakeup ()
;;

let drain t =
  let rec loop () =
    Mutex.lock t.mutex;
    match t.queue with
    | [] -> Mutex.unlock t.mutex
    | queue ->
      t.queue <- [];
      Mutex.unlock t.mutex;
      List.iter (fun thunk -> thunk ()) (List.rev queue);
      loop ()
  in
  loop ()
;;
