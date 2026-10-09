# Share links and export

## Share links

```bash
tsync share photos/2024/report.pdf     # a file
tsync share photos/2024 --expires 30d  # a folder, downloadable as a zip
tsync share                            # the whole domain
```

The link is printed, and its expiry on the line after. A link is public: whoever has it can download until it expires, 7 days by default. `--expires` takes a number and `d`, `h`, `m` or `s`. A folder link opens a page to browse it, preview files, and download any of them or everything as a zip. A link to a picture, a sound, a video or a PDF opens a page that shows or plays it, with a download button; a link to any other file downloads it. Only a browser gets that page: `curl`, an image tag or a chat application previewing the link gets the file itself, and so does anyone adding `/download` to the link.

```bash
tsync share --revoke <link or token>   # stop a link now
tsync share --clear-cache              # delete downloads the share server prepared
```

Clearing the cache leaves links working.

A file can only be shared once it has been uploaded to the store that serves links.

Something has to answer those links. Two options:

**A tsync server.** Set `"shares": true` on its `http-proxy` frontend ([run tsync as a server](server.md)). It streams files and zips folders as they are requested. Clients of that server get their links from it with nothing to configure, and so does the server itself. Nothing runs in the cloud.

**A function next to the bucket,** for a bucket with no machine in front of it. Give the backend its address:

```json
{ "type": "s3", "name": "cloud", "role": "main", "bucket": "…",
  "accessKeyId": "…", "secretAccessKey": "…",
  "shareUrl": "https://share.example.org" }
```

The function, and everything it needs, comes from the [Terraform config](../terraform/README.md), for S3 and for GCS, and `tsync config --edit` fills `shareUrl` from it. With several backends, the first that can serve links does.

`tsync share` answers "Sharing is not available" when neither is set up.

## Get files out

```bash
tsync export /mnt/disk/everything            # the whole domain
tsync export video/take3.mov /mnt/disk       # one file
tsync export media:video/take3.mov /mnt/disk # the same, naming the domain
tsync export photos/2024 docs /mnt/disk      # several files and folders
```

The paths are inside the domain and the directory comes last. What you get is ordinary files and folders, symlinks included, with nothing of tsync in them. That is also the way out of tsync.

Export reads the stores directly. It needs no mount, does not touch the local cache, and so handles files far larger than the cache.

- **It resumes.** Run the same command again after an interruption and it fetches only what is missing. A complete file is not downloaded twice.
- **Each file is given its full size first,** so a disk that is too small says so before the download, not at the end.
- **Every chunk is checked** against its name as it arrives.
- **Unpublished changes are not in it.** A file this machine edited and has not uploaded yet is exported as the store has it, named in a warning, and the command exits 1. Let uploads finish first.

`-j N` sets how many files are read at once; lower it on a slow link. `--source NAME` reads from one backend only, for instance to check that a backup holds everything.
