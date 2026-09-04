let validate_tree tree =
  if Tree.has_unique_uuids tree
  then Ok ()
  else Error "insert tree contains duplicate block UUIDs"
;;
