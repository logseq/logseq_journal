module Graph = Logseq_db_types.Graph_types

let acceptance_barriers_equal
      (left : Types.acceptance_barrier)
      (right : Types.acceptance_barrier)
  =
  Types.Server_cursor.equal left.through right.through
  && Types.Checksum.equal left.checksum right.checksum
;;

let uuid_lists_equal left right =
  List.length left = List.length right && List.for_all2 Graph.Uuid.equal left right
;;

let validate_rejection_partition ~expected (partition : Types.rejection_member_partition) =
  let actual =
    partition.accepted_prefix
    @ Option.to_list partition.failed_member
    @ partition.unexecuted_suffix
  in
  if Option.is_none partition.failed_member
  then Error "definitive rejection has no failed member"
  else if not (uuid_lists_equal expected actual)
  then Error "rejection members do not form the submitted batch partition"
  else if
    Bool.equal
      (partition.accepted_prefix = [])
      (Option.is_some partition.acceptance_barrier)
  then Error "accepted prefix and acceptance barrier are inconsistent"
  else Ok ()
;;
