(* The copy command against a real domain, which is the only place its whole
   claim can be read off the wire: that a copy within one domain moves no bytes,
   however large the files are. *)

open Live

let src = local "src"
let out = local "out"
let session = Filename.concat src "session"
let fetched = Filename.concat out "session"

let rsync fmt =
  Printf.ksprintf (fun args -> Tsync (Printf.sprintf "rsync --domain %s %s" (q domain) args)) fmt

let ls rel =
  Tsync (Printf.sprintf "ls --domain %s %s" (q domain) (q (rel_in_domain rel)))

let is_symlink p () = (Unix.lstat p).Unix.st_kind = Unix.S_LNK

let same_tree a b () =
  Sys.command (Printf.sprintf "diff -r %s %s > /dev/null 2>&1" (q a) (q b)) = 0

let groups =
  [
    {
      title = "a tree to copy";
      cases =
        [
          {
            name = "build it";
            command =
              Shell
                (Printf.sprintf
                   "mkdir -p %s %s && printf 'hello world\\n' > %s && head -c \
                    200000 /dev/urandom > %s && head -c 50000 /dev/urandom > \
                    %s && ln -sf notes.txt %s"
                   (q (Filename.concat session "Audio Files"))
                   (q (Filename.concat src "empty"))
                   (q (Filename.concat session "notes.txt"))
                   (q (Filename.concat session "Audio Files/kick.wav"))
                   (q (Filename.concat session "Audio Files/snare.wav"))
                   (q (Filename.concat session "link.txt")));
            expect = [];
          };
        ];
    };
    {
      title = "local -> tsync";
      cases =
        [
          {
            name = "a first run";
            command = rsync "-v %s %s" (q src) (q (in_domain "a"));
            expect = [ Copied 4; Dirs 3; Failed 0 ];
          };
          {
            name = "a second";
            command = rsync "%s %s" (q src) (q (in_domain "a"));
            expect = [ Copied 0; Skipped 4 ];
          };
        ];
    };
    {
      title = "tsync -> tsync, the copy that moves nothing";
      cases =
        [
          {
            name = "a first run";
            command = rsync "-v %s %s" (q (in_domain "a")) (q (in_domain "b"));
            expect =
              [ Copied 4; Dirs 3; Failed 0; Moved_nothing; Says "publish " ];
          };
          {
            name = "a second";
            command = rsync "%s %s" (q (in_domain "a")) (q (in_domain "b"));
            expect = [ Copied 0; Skipped 4 ];
          };
        ];
    };
    {
      title = "tsync -> local";
      cases =
        [
          {
            name = "a first run";
            command = rsync "%s %s" (q (in_domain "a")) (q out);
            expect =
              [
                Copied 4;
                Failed 0;
                Holds ("brings the tree back byte for byte", same_tree session fetched);
                Holds
                  ( "keeps a symlink a symlink",
                    is_symlink (Filename.concat fetched "link.txt") );
              ];
          };
          {
            name = "a second";
            command = rsync "%s %s" (q (in_domain "a")) (q out);
            expect = [ Copied 0; Skipped 4 ];
          };
          {
            name = "hashing what is already there";
            command = rsync "--checksum %s %s" (q (in_domain "a")) (q out);
            expect = [ Copied 0 ];
          };
          {
            name = "clobber one file";
            command =
              Shell
                (Printf.sprintf "printf 'clobbered\\n' > %s"
                   (q (Filename.concat fetched "notes.txt")));
            expect = [];
          };
          {
            name = "hashing after a change";
            command = rsync "-v --checksum %s %s" (q (in_domain "a")) (q out);
            expect = [ Copied 1 ];
          };
        ];
    };
    {
      title = "moving, and not doing";
      cases =
        [
          {
            name = "a dry run";
            command = rsync "--dry-run %s %s" (q (in_domain "a")) (q (in_domain "dry"));
            expect = [ Copied 4 ];
          };
          {
            name = "what the dry run left";
            command = ls "dry";
            expect = [ Silent_on "session" ];
          };
          {
            name = "a move inside one domain";
            command = rsync "-v --move %s %s" (q (in_domain "b")) (q (in_domain "c"));
            expect = [ Says "rename "; Moved_nothing; Failed 0 ];
          };
          {
            name = "where it moved to";
            command = ls "c/session";
            expect = [ Says "notes.txt" ];
          };
          {
            name = "where it moved from";
            command = ls "b/session";
            expect = [ Silent_on "notes.txt" ];
          };
        ];
    };
    {
      title = "what it refuses";
      cases =
        [
          {
            name = "neither end in a domain";
            command = rsync "%s %s" (q src) (q out);
            expect = [ Says "use rsync(1)" ];
          };
          {
            name = "a file onto a directory";
            command =
              rsync "%s %s"
                (q (Filename.concat src "session/notes.txt"))
                (q (in_domain "a/session"));
            expect = [ Silent_on "Fatal" ];
          };
        ];
    };
  ]

let () = run_groups groups
