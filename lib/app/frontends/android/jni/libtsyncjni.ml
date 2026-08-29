(* Nothing but the linkage: the entry points register themselves as
   [Tsync_android_jni] is initialised. *)

let () = Tsync_android_jni.Android_jni.install_log_sink ()
