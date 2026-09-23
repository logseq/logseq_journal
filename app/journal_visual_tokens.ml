module Ui = Journal_view

type swipe_action_colors =
  { background : Ui.Style.Color.t
  ; foreground : Ui.Style.Color.t
  }

module Color_exceptions = struct
  type presentation =
    | Light
    | Dark

  type status_palette =
    { no_status : swipe_action_colors
    ; todo : swipe_action_colors
    ; doing : swipe_action_colors
    ; done_ : swipe_action_colors
    ; backlog : swipe_action_colors
    }

  let rgb red green blue = Ui.Style.Color.rgb ~red ~green ~blue
  let status_action_background = rgb 0 100 210
  let delete_action_background = rgb 190 35 35
  let transparent = Ui.Style.Color.argb ~alpha:0 ~red:0 ~green:0 ~blue:0

  let light_status =
    { no_status = { background = transparent; foreground = rgb 0 38 47 }
    ; todo = { background = rgb 88 92 126; foreground = rgb 255 255 255 }
    ; doing = { background = rgb 0 103 124; foreground = rgb 255 255 255 }
    ; done_ = { background = rgb 0 107 87; foreground = rgb 255 255 255 }
    ; backlog = { background = rgb 124 58 237; foreground = rgb 255 255 255 }
    }
  ;;

  let dark_status =
    { no_status = { background = transparent; foreground = rgb 167 184 188 }
    ; todo = { background = rgb 192 196 235; foreground = rgb 42 46 80 }
    ; doing = { background = rgb 134 209 233; foreground = rgb 0 54 66 }
    ; done_ = { background = rgb 131 214 189; foreground = rgb 0 56 43 }
    ; backlog = { background = rgb 191 159 255; foreground = rgb 42 12 82 }
    }
  ;;

  let light_increased_status =
    { no_status = { background = transparent; foreground = rgb 0 0 0 }
    ; todo = { background = rgb 58 60 91; foreground = rgb 255 255 255 }
    ; doing = { background = rgb 0 75 90; foreground = rgb 255 255 255 }
    ; done_ = { background = rgb 0 78 62; foreground = rgb 255 255 255 }
    ; backlog = { background = rgb 90 33 175; foreground = rgb 255 255 255 }
    }
  ;;

  let dark_increased_status =
    { no_status = { background = transparent; foreground = rgb 255 255 255 }
    ; todo = { background = rgb 224 225 255; foreground = rgb 42 46 80 }
    ; doing = { background = rgb 179 235 255; foreground = rgb 0 54 66 }
    ; done_ = { background = rgb 174 244 215; foreground = rgb 0 56 43 }
    ; backlog = { background = rgb 224 205 255; foreground = rgb 42 12 82 }
    }
  ;;

  let status_palette ~presentation ~high_contrast =
    match presentation, high_contrast with
    | Light, false -> light_status
    | Dark, false -> dark_status
    | Light, true -> light_increased_status
    | Dark, true -> dark_increased_status
  ;;

  let status_swipe_action ~presentation ~high_contrast =
    let palette = status_palette ~presentation ~high_contrast in
    function
    | Journal_model.No_status -> palette.no_status
    | Todo -> palette.todo
    | Doing | In_review | Now -> palette.doing
    | Done | Canceled -> palette.done_
    | Backlog | Waiting | Later -> palette.backlog
  ;;
end

type t =
  { presentation : Color_exceptions.presentation
  ; high_contrast : bool
  }

let resolve ~brightness ~high_contrast =
  let presentation =
    match brightness with
    | Journal_environment.Light -> Color_exceptions.Light
    | Journal_environment.Dark -> Color_exceptions.Dark
  in
  { presentation; high_contrast }
;;

let status_swipe_action t status =
  Color_exceptions.status_swipe_action
    ~presentation:t.presentation
    ~high_contrast:t.high_contrast
    status
;;

let status_action_background = Color_exceptions.status_action_background
let delete_action_background = Color_exceptions.delete_action_background
