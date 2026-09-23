# KOReader customisations

This repository contains personal KOReader additions for my Pocketbook.

## Layout

- `patches/`: KOReader Lua patches, deployed to `applications/koreader/patches/`.
- `fonts/`: PocketBook system fonts, deployed to `system/fonts/`.
- `scripts/deploy.sh`: copies the tracked additions to a new device over SSH.

The `.gitkeep` files only preserve empty directories in Git and are excluded
from deployment.

## CWA sync rules

- Suspend, close, and network disconnect queue progress before network work.
  Once online, all queued books for the server/account are processed.
- Queue reconciliation trusts timestamps. A newer local snapshot uploads
  automatically unless the server is farther ahead; ties and missing timestamps
  favor the server. Closed destructive conflicts stay queued.
- On an open book, every server pull with a saved position offers `Use server
  (xx.xx%)` or `Keep local (xx.xx%)`, showing both positions. Keeping local
  uploads that choice to the server.
- Startup and resume always attempt to check progress, including by turning on
  Wi-Fi when needed.
- An external disconnect revokes reconnect permission; a later attempt may
  reconnect if the radio is still on.

## Deploy to a new device

The destination needs SSH access and KOReader installed on a PocketBook. This
example uses the conventional PocketBook storage root, `/mnt/ext1`:

```sh
scripts/deploy.sh reader@192.168.1.52
```

The default SSH port is `2222`. Pass a different storage root and, optionally,
an SSH port when the device uses another mount point or port:

```sh
scripts/deploy.sh reader@192.168.1.52 /mnt/ext1 22
```

The script writes only to the supplied target. It does not delete target files
and does not use the existing reader as a default.
