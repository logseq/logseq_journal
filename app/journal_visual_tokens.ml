module Ui = Journal_view

type status_colors =
  { background : Ui.Style.Color.t
  ; foreground : Ui.Style.Color.t
  }

module Color_exceptions = struct
  type presentation =
    | Light
    | Dark

  type status_palette =
    { no_status : status_colors
    ; todo : status_colors
    }

  let rgb red green blue = Ui.Style.Color.rgb ~red ~green ~blue
  let transparent = Ui.Style.Color.argb ~alpha:0 ~red:0 ~green:0 ~blue:0

  let light_status =
    { no_status = { background = transparent; foreground = rgb 0 38 47 }
    ; todo = { background = rgb 88 92 126; foreground = rgb 255 255 255 }
    }
  ;;

  let dark_status =
    { no_status = { background = transparent; foreground = rgb 167 184 188 }
    ; todo = { background = rgb 192 196 235; foreground = rgb 42 46 80 }
    }
  ;;

  let light_increased_status =
    { no_status = { background = transparent; foreground = rgb 0 0 0 }
    ; todo = { background = rgb 58 60 91; foreground = rgb 255 255 255 }
    }
  ;;

  let dark_increased_status =
    { no_status = { background = transparent; foreground = rgb 255 255 255 }
    ; todo = { background = rgb 224 225 255; foreground = rgb 42 46 80 }
    }
  ;;

  let status_palette ~presentation ~high_contrast =
    match presentation, high_contrast with
    | Light, false -> light_status
    | Dark, false -> dark_status
    | Light, true -> light_increased_status
    | Dark, true -> dark_increased_status
  ;;

  let status_colors ~presentation ~high_contrast =
    let palette = status_palette ~presentation ~high_contrast in
    function
    | Journal_model.No_status | Invalid_status _ -> palette.no_status
    | Status _ | Default_status -> palette.todo
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

let status_colors t status =
  Color_exceptions.status_colors
    ~presentation:t.presentation
    ~high_contrast:t.high_contrast
    status
;;
