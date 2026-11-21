module type EFFECTS = sig
  type error
  type (_, _, _, _) operation
end

module Make (Effects : EFFECTS) = struct
  type (_, _, _) t =
    | Pure : 'a -> ('s, 's, 'a) t
    | Failed : Effects.error -> ('s, 'final, 'a) t
    | Effect :
        ('before, 'after, 'failed, 'a) Effects.operation
        * ('a -> ('after, 'final, 'b) t)
        * (Effects.error -> ('failed, 'final, 'b) t)
        -> ('before, 'final, 'b) t
    | Bind :
        ('before, 'middle, 'a) t * ('a -> ('middle, 'after, 'b) t)
        -> ('before, 'after, 'b) t

  let return value = Pure value
  let abort error = Failed error
  let bind program continuation = Bind (program, continuation)
  let perform operation ~success ~failure = Effect (operation, success, failure)

  type (_, _, _) node =
    | Return : 'a -> ('s, 's, 'a) node
    | Abort : Effects.error -> ('s, 'final, 'a) node
    | Perform :
        ('before, 'after, 'failed, 'a) Effects.operation
        * ('a -> ('after, 'final, 'b) t)
        * (Effects.error -> ('failed, 'final, 'b) t)
        -> ('before, 'final, 'b) node

  type (_, _, _, _) continuations =
    | Done : ('s, 's, 'a, 'a) continuations
    | Next :
        ('a -> ('middle, 'next, 'b) t) * ('next, 'final, 'b, 'result) continuations
        -> ('middle, 'final, 'a, 'result) continuations

  let rec resume
    : type before middle after value result.
      (before, middle, value) t
      -> (middle, after, value, result) continuations
      -> (before, after, result) t
    =
    fun program continuations ->
    match continuations with
    | Done -> program
    | Next (continuation, remaining) ->
      Bind (program, fun value -> resume (continuation value) remaining)
  ;;

  let rec normalize
    : type before middle after value result.
      (before, middle, value) t
      -> (middle, after, value, result) continuations
      -> (before, after, result) node
    =
    fun program continuations ->
    match program with
    | Pure value ->
      (match continuations with
       | Done -> Return value
       | Next (continuation, remaining) -> normalize (continuation value) remaining)
    | Failed error -> Abort error
    | Effect (operation, success, failure) ->
      Perform
        ( operation
        , (fun value -> resume (success value) continuations)
        , fun error -> resume (failure error) continuations )
    | Bind (first, continuation) -> normalize first (Next (continuation, continuations))
  ;;

  let view program = normalize program Done
end
