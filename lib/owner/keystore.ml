type t = {
  name : string;
  put : domain:string -> key_id:string -> key:string -> unit;
  get : domain:string -> (string * string) option;
  delete : domain:string -> unit;
}

let current = Atomic.make None
let register t = Atomic.set current (Some t)
let registered () = Atomic.get current
