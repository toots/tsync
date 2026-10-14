# Add a second machine


Install tsync there and configure a domain with **the same backends**. Each machine publishes its changes to a numbered log kept with the data, and the others pick them up.

The service notices changes on its own: at once for a `local` disk or through a tsync server, within seconds for a bucket. To apply them right now:

```bash
tsync sync          # pick up what other machines published, publish what is pending here
tsync sync --full   # compare with the store's whole tree instead of the log
```

`--full` is the repair for a view that disagrees with the store. It keeps your unpublished changes and the cache. A change made here reaches the others about ten seconds after its content is uploaded; `tsync sync` sends it at once.

Give every machine its own `name` at the top of its config; the default is the hostname.

## Read-only machines

A machine that should never write sets `"readOnly": true` on the domain, next to its `name`. It still receives changes. Writes are refused, with "read-only file system" on Linux.

## When two machines change the same thing

tsync is built for one person with several machines. Edits are applied locally at once and published later, seconds later online and days later after a flight. So two machines can each hold changes the other has not seen. The rules, in order:

1. **Changes that do not clash are both applied.** A folder renamed on one machine keeps what another added to it or edited in it. A file is different: renamed on one machine and edited on another, it ends as two files, the edit under the old name and the earlier content under the new one.
2. **When two things want one name, both are kept.** What was published first keeps the name. The machine that publishes second moves its own item aside, under a name that says so:

   ```
   report (conflicted copy from laptop).pdf
   plans (conflicted copy from laptop)
   ```

   `laptop` is that machine's `name`. The extension is kept, so the copy still opens.

   Two folders created under one name are the exception: they become one folder, holding what both machines put in it. Only a file both put in it under one name gets a conflicted copy. A folder that existed before and was renamed onto the name still goes aside, as `plans` above.
3. **An edit outlives a delete.** A file you edited survives its deletion elsewhere. Files you added under a folder that was removed elsewhere bring the folder back with them, and a folder you removed comes back if another machine added to it.
4. **Two edits of one file are two files.** The one published first is the file; the other is its conflicted copy. Contents are never merged.

Every machine reaches the same result without talking to the others.

These rules are the short form. [How it works](README.md#how-it-works) lists where the outcome of every pair of clashing changes, the way changes are published and the proofs are written down.
