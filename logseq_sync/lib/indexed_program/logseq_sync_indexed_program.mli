module type EFFECTS = sig
  type error
  type (_, _, _, _) operation
end

module Make (Effects : EFFECTS) : sig
  type ('before, 'after, 'value) t

  val return : 'a -> ('s, 's, 'a) t
  val abort : Effects.error -> ('s, 'final, 'a) t

  val bind
    :  ('before, 'middle, 'a) t
    -> ('a -> ('middle, 'after, 'b) t)
    -> ('before, 'after, 'b) t

  val perform
    :  ('before, 'after, 'failed, 'a) Effects.operation
    -> success:('a -> ('after, 'final, 'b) t)
    -> failure:(Effects.error -> ('failed, 'final, 'b) t)
    -> ('before, 'final, 'b) t

  type (_, _, _) node =
    | Return : 'a -> ('s, 's, 'a) node
    | Abort : Effects.error -> ('s, 'final, 'a) node
    | Perform :
        ('before, 'after, 'failed, 'a) Effects.operation
        * ('a -> ('after, 'final, 'b) t)
        * (Effects.error -> ('failed, 'final, 'b) t)
        -> ('before, 'final, 'b) node

  val view : ('before, 'after, 'a) t -> ('before, 'after, 'a) node
end
