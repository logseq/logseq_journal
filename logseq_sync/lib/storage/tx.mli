val decode
  :  ?decrypt_protected:
       (attribute:string -> string -> (Transit_core.Json.value, string) result)
  -> db:Datascript.db
  -> string
  -> (Datascript.tx_op list, string) result
