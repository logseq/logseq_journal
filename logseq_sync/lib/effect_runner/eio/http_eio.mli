type response =
  { status : int
  ; headers : (string * string) list
  ; body : string
  }

val perform
  :  sw:Eio.Switch.t
  -> authenticator:X509.Authenticator.t
  -> network:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> Http.request
  -> (response, string) result

val download
  :  sw:Eio.Switch.t
  -> authenticator:X509.Authenticator.t
  -> network:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> request:Http.request
  -> destination:string
  -> maximum_bytes:int
  -> on_progress:(Bootstrap.progress -> unit)
  -> (response, string) result
