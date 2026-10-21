let converter = Atomic.make None
let available () = Option.is_some (Atomic.get converter)
