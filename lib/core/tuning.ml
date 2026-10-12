type t = {
  batch_delay : float;
  project_width : int;
  max_entry_commands : int;
  project_lease : float;
  project_quarantine : float;
  project_settle : float;
}

let default =
  {
    batch_delay = 10.;
    project_width = 8;
    max_entry_commands = Log_entry.max_commands;
    project_lease = 30.;
    project_quarantine = 300.;
    project_settle = 600.;
  }
