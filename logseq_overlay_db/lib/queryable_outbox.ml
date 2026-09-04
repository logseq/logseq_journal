let logically_active = function
  | Types.Queued
  | Submitted _
  | Accepted_pending_authoritative _
  | Delete_barrier_rejected_pending_authoritative _ -> true
  | Blocked -> false
;;

let has_active_dependency_shadows = function
  | Types.Submitted _
  | Accepted_pending_authoritative _
  | Delete_barrier_rejected_pending_authoritative _ -> true
  | Queued | Blocked -> false
;;
