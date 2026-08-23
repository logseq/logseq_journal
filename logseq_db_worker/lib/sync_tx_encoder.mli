val encode
  :  ?encrypt_protected:(string -> (string, string) result)
  -> Datascript.db
  -> Datascript.tx_op list
  -> (string, string) result
