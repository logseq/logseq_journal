type t =
  { tx_ops : Datascript.tx_op list
  ; tx_meta : Datascript.tx_meta
  ; changed_uuids : Graph_types.Uuid.t list
  ; status : Protocol.mutation_status
  }

type error =
  | Unsupported_semantics of string
  | Invalid_selection of string
  | Invalid_tree of string
  | Invalid_order of string
  | Invalid_position of string
  | Conflict of string
  | Built_in_protected

let plan ~now_ms db = function
  | Protocol.Structural (Save_block { block; title; context }) ->
    (match Outliner.Save_block.plan ~now_ms db ~block ~title ~context with
     | Ok plan ->
       Ok
         { tx_ops = plan.Outliner.Save_block.tx_ops
         ; tx_meta = plan.tx_meta
         ; changed_uuids = plan.changed_uuids
         ; status = (if plan.tx_ops = [] then Protocol.No_change else Applied)
         }
     | Error Built_in_protected -> Error Built_in_protected
     | Error (Unsupported_semantics message) -> Error (Unsupported_semantics message)
     | Error (Invalid_selection message) -> Error (Invalid_selection message))
  | Structural (Insert_blocks { roots; position; context }) ->
    (match Outliner.Insert_blocks.plan ~now_ms db ~roots ~position ~context with
     | Ok plan ->
       Ok
         { tx_ops = plan.Outliner.Insert_blocks.tx_ops
         ; tx_meta = plan.tx_meta
         ; changed_uuids = plan.changed_uuids
         ; status = plan.status
         }
     | Error Built_in_protected -> Error Built_in_protected
     | Error (Unsupported_semantics message) -> Error (Unsupported_semantics message)
     | Error (Invalid_selection message) -> Error (Invalid_selection message)
     | Error (Invalid_tree message) -> Error (Invalid_tree message)
     | Error (Invalid_order message) -> Error (Invalid_order message)
     | Error (Invalid_position message) -> Error (Invalid_position message)
     | Error (Conflict message) -> Error (Conflict message))
  | Structural (Move_blocks { roots; position; context }) ->
    (match Outliner.Move_blocks.plan ~now_ms db ~roots ~position ~context with
     | Ok plan ->
       Ok
         { tx_ops = plan.Outliner.Move_blocks.tx_ops
         ; tx_meta = plan.tx_meta
         ; changed_uuids = plan.changed_uuids
         ; status = plan.status
         }
     | Error Built_in_protected -> Error Built_in_protected
     | Error (Unsupported_semantics message) -> Error (Unsupported_semantics message)
     | Error (Invalid_selection message) -> Error (Invalid_selection message)
     | Error (Invalid_tree message) -> Error (Invalid_tree message)
     | Error (Invalid_order message) -> Error (Invalid_order message)
     | Error (Invalid_position message) -> Error (Invalid_position message))
  | Structural (Move_up_down { roots; direction; context }) ->
    (match Outliner.Move_blocks.plan_up_down ~now_ms db ~roots ~direction ~context with
     | Ok plan ->
       Ok
         { tx_ops = plan.Outliner.Move_blocks.tx_ops
         ; tx_meta = plan.tx_meta
         ; changed_uuids = plan.changed_uuids
         ; status = plan.status
         }
     | Error Built_in_protected -> Error Built_in_protected
     | Error (Unsupported_semantics message) -> Error (Unsupported_semantics message)
     | Error (Invalid_selection message) -> Error (Invalid_selection message)
     | Error (Invalid_tree message) -> Error (Invalid_tree message)
     | Error (Invalid_order message) -> Error (Invalid_order message)
     | Error (Invalid_position message) -> Error (Invalid_position message))
  | Structural (Indent_outdent { roots; direction; context }) ->
    (match Outliner.Indent_outdent.plan ~now_ms db ~roots ~direction ~context with
     | Ok plan ->
       Ok
         { tx_ops = plan.Outliner.Indent_outdent.tx_ops
         ; tx_meta = plan.tx_meta
         ; changed_uuids = plan.changed_uuids
         ; status = plan.status
         }
     | Error Built_in_protected -> Error Built_in_protected
     | Error (Unsupported_semantics message) -> Error (Unsupported_semantics message)
     | Error (Invalid_selection message) -> Error (Invalid_selection message)
     | Error (Invalid_tree message) -> Error (Invalid_tree message)
     | Error (Invalid_order message) -> Error (Invalid_order message)
     | Error (Invalid_position message) -> Error (Invalid_position message))
  | Structural (Delete_blocks { roots; context }) ->
    (match Outliner.Delete_blocks.plan ~now_ms db ~roots ~context with
     | Ok plan ->
       Ok
         { tx_ops = plan.Outliner.Delete_blocks.tx_ops
         ; tx_meta = plan.tx_meta
         ; changed_uuids = plan.changed_uuids
         ; status = plan.status
         }
     | Error Built_in_protected -> Error Built_in_protected
     | Error (Unsupported_semantics message) -> Error (Unsupported_semantics message)
     | Error (Invalid_selection message) -> Error (Invalid_selection message)
     | Error (Invalid_tree message) -> Error (Invalid_tree message))
  | Page mutation ->
    (match Outliner.Pages.plan ~now_ms db mutation with
     | Ok plan ->
       Ok
         { tx_ops = plan.Outliner.Pages.tx_ops
         ; tx_meta = plan.tx_meta
         ; changed_uuids = plan.changed_uuids
         ; status = plan.status
         }
     | Error Built_in_protected -> Error Built_in_protected
     | Error (Unsupported_semantics message) -> Error (Unsupported_semantics message)
     | Error (Invalid_selection message) -> Error (Invalid_selection message)
     | Error (Invalid_order message) -> Error (Invalid_order message)
     | Error (Conflict message) -> Error (Conflict message))
  | Property mutation ->
    (match Outliner.Properties.plan ~now_ms db mutation with
     | Ok plan ->
       Ok
         { tx_ops = plan.Outliner.Properties.tx_ops
         ; tx_meta = plan.tx_meta
         ; changed_uuids = plan.changed_uuids
         ; status = plan.status
         }
     | Error Built_in_protected -> Error Built_in_protected
     | Error (Unsupported_semantics message) -> Error (Unsupported_semantics message)
     | Error (Invalid_selection message) -> Error (Invalid_selection message)
     | Error (Conflict message) -> Error (Conflict message))
;;
