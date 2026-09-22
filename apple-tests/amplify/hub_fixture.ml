module Ui = Bonsai_swiftui_ui

let component _handlers _graph =
  Bonsai.Cont.return
    (App.View.create
       ~theme:(Ui.Theme.create ())
       ~body:(Ui.View.Body.static (Ui.View.text "Native Hub callback acceptance")))
;;

let app = App.create ~name:"Hub acceptance" component
