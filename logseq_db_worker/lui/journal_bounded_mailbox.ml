let validate_capacity name capacity =
  if capacity <= 0 then invalid_arg (name ^ ": capacity must be positive")
;;

let validate_max_items name max_items =
  if max_items < 0 then invalid_arg (name ^ ": max_items must be nonnegative")
;;

module Fifo = struct
  type 'a t =
    { capacity : int
    ; mutex : Mutex.t
    ; condition : Condition.t
    ; queue : 'a Queue.t
    ; mutable closed : bool
    }

  let create ~capacity =
    validate_capacity "Bounded_mailbox.Fifo.create" capacity;
    { capacity
    ; mutex = Mutex.create ()
    ; condition = Condition.create ()
    ; queue = Queue.create ()
    ; closed = false
    }
  ;;

  let with_lock t f =
    Mutex.lock t.mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f
  ;;

  let try_push t value =
    with_lock t (fun () ->
      if t.closed
      then `Closed
      else if Queue.length t.queue >= t.capacity
      then `Full
      else (
        Queue.add value t.queue;
        Condition.signal t.condition;
        `Ok))
  ;;

  let pop t =
    with_lock t (fun () ->
      if Queue.is_empty t.queue then None else Some (Queue.take t.queue))
  ;;

  let length t = with_lock t (fun () -> Queue.length t.queue)

  let wait_pop t =
    with_lock t (fun () ->
      while Queue.is_empty t.queue && not t.closed do
        Condition.wait t.condition t.mutex
      done;
      if Queue.is_empty t.queue then None else Some (Queue.take t.queue))
  ;;

  let drain t ~max_items =
    validate_max_items "Bounded_mailbox.Fifo.drain" max_items;
    with_lock t (fun () ->
      let rec loop remaining reversed =
        if remaining = 0 || Queue.is_empty t.queue
        then List.rev reversed
        else loop (remaining - 1) (Queue.take t.queue :: reversed)
      in
      loop max_items [])
  ;;

  let close t =
    with_lock t (fun () ->
      if not t.closed
      then (
        t.closed <- true;
        Condition.broadcast t.condition))
  ;;
end

module Reserved = struct
  type 'a t =
    { capacity : int
    ; mutex : Mutex.t
    ; queue : 'a Queue.t
    ; mutable reserved : int
    }

  let create ~capacity =
    validate_capacity "Bounded_mailbox.Reserved.create" capacity;
    { capacity; mutex = Mutex.create (); queue = Queue.create (); reserved = 0 }
  ;;

  let with_lock t f =
    Mutex.lock t.mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f
  ;;

  let reserve t =
    with_lock t (fun () ->
      if t.reserved + Queue.length t.queue >= t.capacity
      then false
      else (
        t.reserved <- t.reserved + 1;
        true))
  ;;

  let cancel t =
    with_lock t (fun () ->
      if t.reserved = 0
      then invalid_arg "Bounded_mailbox.Reserved.cancel: no reservation"
      else t.reserved <- t.reserved - 1)
  ;;

  let publish t value =
    with_lock t (fun () ->
      if t.reserved = 0
      then invalid_arg "Bounded_mailbox.Reserved.publish: no reservation"
      else (
        t.reserved <- t.reserved - 1;
        Queue.add value t.queue))
  ;;

  let pop t =
    with_lock t (fun () ->
      if Queue.is_empty t.queue then None else Some (Queue.take t.queue))
  ;;

  let drain t ~max_items =
    validate_max_items "Bounded_mailbox.Reserved.drain" max_items;
    with_lock t (fun () ->
      let rec loop remaining reversed =
        if remaining = 0 || Queue.is_empty t.queue
        then List.rev reversed
        else loop (remaining - 1) (Queue.take t.queue :: reversed)
      in
      loop max_items [])
  ;;
end

module Coalesced = struct
  type 'a t =
    { capacity : int
    ; mutex : Mutex.t
    ; slots : (int, 'a) Hashtbl.t
    }

  let create ~capacity =
    validate_capacity "Bounded_mailbox.Coalesced.create" capacity;
    { capacity; mutex = Mutex.create (); slots = Hashtbl.create capacity }
  ;;

  let with_lock t f =
    Mutex.lock t.mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f
  ;;

  let push t ~topic value =
    with_lock t (fun () ->
      if Hashtbl.mem t.slots topic
      then (
        Hashtbl.replace t.slots topic value;
        `Replaced)
      else if Hashtbl.length t.slots >= t.capacity
      then `Full
      else (
        Hashtbl.add t.slots topic value;
        `Added))
  ;;

  let drain t ~max_items =
    validate_max_items "Bounded_mailbox.Coalesced.drain" max_items;
    with_lock t (fun () ->
      let topics = Hashtbl.to_seq_keys t.slots |> List.of_seq |> List.sort Int.compare in
      let rec take remaining reversed = function
        | _ when remaining = 0 -> List.rev reversed
        | [] -> List.rev reversed
        | topic :: rest ->
          let value = Hashtbl.find t.slots topic in
          Hashtbl.remove t.slots topic;
          take (remaining - 1) ((topic, value) :: reversed) rest
      in
      take max_items [] topics)
  ;;
end
