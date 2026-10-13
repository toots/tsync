type t = {
  batch_delay : float;
  project_width : int;
  max_entry_commands : int;
  max_entry_bytes : int;
  project_lease : float;
  project_quarantine : float;
  project_settle : float;
}

let default =
  {
    batch_delay = 10.;
    project_width = 8;
    max_entry_commands = Log_entry.max_commands;
    max_entry_bytes = Log_entry.max_bytes;
    project_lease = 30.;
    project_quarantine = 300.;
    project_settle = 600.;
  }
