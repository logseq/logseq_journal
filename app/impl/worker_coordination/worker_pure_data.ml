(** Pure query values shared by the coordinator and Worker. Constructor tags
    preserve the canonical JSON identity of persisted mutation payloads. *)
open Logseq_db_types.Graph_types

module Rrbvec = struct
  include Rrbvec
  let to_yojson encode values = `List(Rrbvec.to_seq values |> Seq.map encode |> List.of_seq)
  let of_yojson decode = function
    | `List values ->
      List.fold_left(fun result value->Result.bind result(fun values->
        Result.map(fun value->Rrbvec.push_back values value)(decode value)))(Ok Rrbvec.empty)values
    | _->Error "Append children must be an array"
end

let maximum_request_bytes = Logseq_db_types.Limits.maximum_request_bytes
let maximum_response_bytes = Logseq_db_types.Limits.maximum_response_bytes
let maximum_push_bytes = Logseq_db_types.Limits.maximum_push_bytes
let default_page_size = 50
let maximum_page_size = 200
let maximum_tree_nodes = 2_000
let maximum_tree_depth = 64
let maximum_title_bytes = 65_536
let maximum_roots = 1_024
let maximum_changed_uuids = Logseq_db_types.Limits.maximum_changed_uuids
let maximum_property_values = 1_024
let maximum_filter_values = 64

type precondition_scope = V2_children_scope of Uuid.t

and task_status = Uuid.t

and preconditions =
  { blocks : (block_uuid * string) list
  ; pages : (page_uuid * string) list
  ; scopes : (precondition_scope * string) list
  }

and block_tree =
  { uuid : block_uuid
  ; title : string
  ; children : block_tree list
  }

and append_node =
  { block_id : block_uuid
  ; title : string
  ; task_status : Uuid.t option
  ; children : append_node Rrbvec.t
  }

and change_window =
  { id : string
  ; predecessor : string
  ; successor : string
  ; block_uuids : block_uuid list
  ; page_uuids : page_uuid list
  ; structure_interests : structure_interest list
  }

and structure_interest =
  | V2_children_interest of Uuid.t
  | V2_page_tree_interest of page_uuid
  | V2_journal_index_interest

and capability_limits =
  { response_budget_bytes : int
  ; outbox_max_records : int
  ; outbox_max_bytes : int
  ; change_max_items : int
  ; change_max_bytes : int
  ; dispatcher_capacity : int
  ; wire_batch_max_bytes : int
  }

and page_lookup =
  | V2_present_page of
      { page : page
      ; revision : string
      }
  | V2_missing_page of
      { uuid : page_uuid
      ; revision : string
      }

and block_record =
  { block : block
  ; task_status : task_status option
  ; rendered_page_title : string
  ; tag_titles : string list
  }

and block_lookup =
  | V2_present_block of
      { value : block_record
      ; revision : string
      }
  | V2_missing_block of
      { uuid : block_uuid
      ; revision : string
      }

and journal_item =
  { page : page
  ; journal_day : int
  ; revision : string
  }

and favorite_target =
  | V2_favorite_page of
      { uuid : page_uuid
      ; title : string
      ; revision : string
      }
  | V2_favorite_block of
      { uuid : block_uuid
      ; title : string
      ; task_status : task_status option
      ; revision : string
      }

and favorite_item =
  { membership_uuid : block_uuid
  ; membership_order : string
  ; membership_revision : string
  ; target : favorite_target
  }

and child_member =
  { value : block_record
  ; revision : string
  }

and tree_member =
  { value : block_record
  ; revision : string
  ; depth : int
  ; parent : Uuid.t
  }

and revision_scope = V2_children_revision of Uuid.t

and local_status =
  | V2_applied
  | V2_no_change
  | V2_already_applied

and admission_inspection =
  { active_records : int
  ; active_bytes : int
  ; protected_wire_bytes : int
  ; retained_origin_evidence_bytes : int
  ; maximum_records : int
  ; maximum_bytes : int
  }
[@@deriving yojson]

type changefeed_signal =
  | Changes_available of { generation : string; through : string }
  | Resync_required of { generation : string; reason : string }

let valid_title title = String.length title <= maximum_title_bytes
module Append_ids=Set.Make(String)
let valid_append_node root =
  let rec visit pending index seen =
    if index=Rrbvec.length pending then true
    else if index>=maximum_tree_nodes then false
    else let node,depth=Rrbvec.nth pending index in
      let id=Uuid.to_string node.block_id in
      depth<=maximum_tree_depth && valid_title node.title
      && Rrbvec.length node.children<maximum_tree_nodes && not(Append_ids.mem id seen)
      && visit(Rrbvec.append pending(Rrbvec.map(fun child->child,depth+1)node.children))
        (index+1)(Append_ids.add id seen) in
  visit(Rrbvec.singleton(root,0))0 Append_ids.empty
;;
