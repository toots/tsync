type response = { status : int; body : string }
type post = url:string -> headers:(string * string) list -> string -> response

let registered : (string * post) option Atomic.t = Atomic.make None
let register ~name post = Atomic.set registered (Some (name, post))
let implementation () = Atomic.get registered
