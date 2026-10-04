# Add a second machine


Install tsync there and configure a domain with **the same backends**. Each machine publishes its changes to a journal kept with the data, and the others apply them.

The service notices changes on its own: at once for a `local` disk or through a tsync server, within seconds for a bucket. To apply them right now:

```bash
tsync sync          # apply what other machines published
tsync sync --full   # rebuild this machine's view from what the store holds
```

`--full` is the repair for a view that disagrees with the store. It keeps your unpublished edits and the cache.

Give every machine its own `name` at the top of its config; the default is the hostname.

## Read-only machines

A machine that should never write sets `"readOnly": true` on the domain, next to its `name`. It still receives changes. Writes are refused, with "read-only file system" on Linux.

## When two machines change the same thing

tsync is built for one person with several machines. Edits are applied locally at once and published later, seconds later online and days later after a flight. So two machines can each hold changes the other has not seen. The rules, in order:

1. **Changes that do not clash are both applied.** A file renamed on one machine keeps the edit made on another.
2. **When two things want one name, both are kept.** The machine that had not published yet moves its own item aside, under a name that says so:

   ```
   report (conflicted copy from laptop).pdf
   plans (conflicted copy from laptop)
   ```

   `laptop` is that machine's `name`. The extension is kept, so the copy still opens.
3. **An edit outlives a delete.** A file you edited survives its deletion elsewhere, and files you added under a folder that was removed elsewhere are kept in a conflicted copy of that folder.
4. **Only when both sides were already published does one win.** Two uploaded edits of the same file: the later one is the file, the earlier one is in its [version history](history.md). This is the reason to keep `versioning` on.

Every machine reaches the same result without talking to the others.
