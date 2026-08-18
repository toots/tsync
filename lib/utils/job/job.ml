(* What a long-running command is doing, told to the daemon so something other
   than the command's own stdout can answer for it: {!Job_report} pushes a
   summary on a timer, and {!Job_progress} is the bytes half of one. *)
module Report = Job_report
module Progress = Job_progress
