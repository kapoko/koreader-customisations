# KOReader customisations

This repository contains personal KOReader additions. It does not manage the
current reader and never connects to it unless explicitly supplied as a deployment
target.

## Layout

- `patches/`: KOReader Lua patches, deployed to `applications/koreader/patches/`.
- `fonts/`: PocketBook system fonts, deployed to `system/fonts/`.
- `scripts/deploy.sh`: copies the tracked additions to a new device over SSH.

The `.gitkeep` files only preserve empty directories in Git and are excluded
from deployment.

## Add customizations

Put each patch in `patches/` and font files (or per-font directories) in
`fonts/`. Then review and commit them normally:

```sh
git status
git add patches fonts
git commit -m "Add KOReader customizations"
```

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
