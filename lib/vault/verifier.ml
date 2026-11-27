type t = { name : string; verify : reason:string -> (unit, string) result }

let current = Atomic.make None
let register v = Atomic.set current (Some v)
let registered () = Atomic.get current
