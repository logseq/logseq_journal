include Outliner.Planner_contract

let plan ~now_ms db = function
  | Logseq_db_types.Mutation.Structural (Save_block { block; title; context }) ->
    Outliner.Save_block.plan ~now_ms db ~block ~title ~context
  | Structural (Insert_blocks { roots; position; context }) ->
    Outliner.Insert_blocks.plan ~now_ms db ~roots ~position ~context
  | Structural (Move_blocks { roots; position; context }) ->
    Outliner.Move_blocks.plan ~now_ms db ~roots ~position ~context
  | Structural (Move_up_down { roots; direction; context }) ->
    Outliner.Move_blocks.plan_up_down ~now_ms db ~roots ~direction ~context
  | Structural (Indent_outdent { roots; direction; context }) ->
    Outliner.Indent_outdent.plan ~now_ms db ~roots ~direction ~context
  | Structural (Delete_blocks { roots; context }) ->
    Outliner.Delete_blocks.plan ~now_ms db ~roots ~context
  | Page mutation -> Outliner.Pages.plan ~now_ms db mutation
  | Property mutation -> Outliner.Properties.plan ~now_ms db mutation
;;
