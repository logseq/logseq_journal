val validate_results
  :  maximum_value_bytes:int
  -> expected:(Types.Crypto_item_id.t * string) list
  -> actual:(Types.Crypto_item_id.t * string) list
  -> (unit, Types.crypto_result_error) result
