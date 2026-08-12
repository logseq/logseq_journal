module Error : sig
  type t

  val to_string : t -> string
end

(** Resolve the fixed database leaf after proving that the supplied root is
    canonical. Create the private parent when absent, then prove that it
    remains contained and that neither existing path components nor the leaf
    are symbolic links. *)
val resolve : support_root:string -> relative_path:string -> (string, Error.t) result
