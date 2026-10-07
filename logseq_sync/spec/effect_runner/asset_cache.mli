(** Cache resources have no public execution interface. Business requests enter
    [Core.step]; the resulting effect is submitted to [Effect_runner.submit]. *)
type t

type handle
type error
type staged
