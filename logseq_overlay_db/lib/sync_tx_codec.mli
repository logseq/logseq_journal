val protected_values : string -> (string list, string) result
val protected_plaintexts : Datascript.tx_op list -> (string list, string) result
val synchronized_operations : Datascript.tx_op list -> Datascript.tx_op list
val encode : db:Datascript.db -> Datascript.tx_op list -> (string, string) result

val encode_protected
  :  db:Datascript.db
  -> Datascript.tx_op list
  -> encrypted_values:string list
  -> (string, string) result

val decode
  :  db:Datascript.db
  -> decrypted_values:string list
  -> string
  -> (Datascript.tx_op list, string) result

(** Read the already assigned UUID/order pairs from an insertion transaction. *)
val inserted_orders : string -> ((string * string) list, string) result
