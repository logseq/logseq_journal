module Graph = Logseq_db_types.Graph_types

let digest_key namespace value =
  Digestif.SHA256.digest_string (namespace ^ value) |> Digestif.SHA256.to_hex
;;

let mutation_key mutation_id =
  digest_key "mutation-receipt:v1:" (Graph.Uuid.to_string mutation_id)
;;

let terminal_batch_key batch_id =
  digest_key "terminal-batch-receipt:v1:" (Types.Submission_batch_id.to_string batch_id)
;;
