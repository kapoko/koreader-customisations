# KOReader customisations

This repository contains personal KOReader additions for my Pocketbook.

## Layout

- `patches/`: KOReader Lua patches, deployed to `applications/koreader/patches/`.
- `fonts/`: PocketBook system fonts, deployed to `system/fonts/`.
- `scripts/deploy.sh`: copies the tracked additions to a new device over SSH.

The `.gitkeep` files only preserve empty directories in Git and are excluded
from deployment.

## CWA sync rules

Added behaviors:

- Suspend, document close, and network disconnect save progress before any
  network work; an unavailable connection leaves that snapshot queued.
- Queue entries are per server, account, and document. Once online, automatic
  sync processes all matching queued books sequentially; an unresolved conflict
  stays queued without blocking other books.
- Opening a document reconciles queued progress with the server before doing
  CWA's normal pull, whenever Wi-Fi is available.
- Queue reconciliation trusts timestamps. A newer local snapshot is uploaded
  automatically unless the server is farther ahead; tied or unavailable
  timestamps favor the authoritative server. When the server wins for an open
  book, the reader chooses `Use server (xx.xx%)` or `Keep local (xx.xx%)`.
  Destructive closed-document conflicts remain queued.
- Automatic server pulls with a different position always offer `Use server
  (xx.xx%)` and `Keep local (xx.xx%)`, showing both positions.
- Already-online Wi-Fi is used. When KOReader is offline but the PocketBook
  radio is enabled, automatic sync attempts to reconnect even without an
  earlier successful connection.
- When the PocketBook radio is off, automatic sync fails silently and does not
  invoke its Wi-Fi prompt. A dismissed prompt is treated the same way when it
  leaves the radio off.
- An external Wi-Fi disconnect revokes automatic reconnect permission; the
  next attempt may still reconnect if the radio is enabled.

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
