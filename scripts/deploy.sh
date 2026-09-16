#!/bin/sh
# Deploy repository additions to an explicitly named, writable target device.
set -eu

usage() {
    printf '%s\n' "Usage: $0 user@host [storage-root] [ssh-port]" >&2
    exit 2
}

[ "$#" -ge 1 ] && [ "$#" -le 3 ] || usage

target=$1
storage_root=${2:-/mnt/ext1}
ssh_port=${3:-2222}

case "$storage_root" in
    /*) ;;
    *)
        printf '%s\n' "Storage root must be an absolute path: $storage_root" >&2
        exit 2
        ;;
esac

case "$ssh_port" in
    *[!0-9]*|'')
        printf '%s\n' "SSH port must be numeric: $ssh_port" >&2
        exit 2
        ;;
esac

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

for directory in patches fonts; do
    [ -d "$repo_root/$directory" ] || {
        printf '%s\n' "Missing $directory/ in repository" >&2
        exit 1
    }
done

printf 'Deploying patches and fonts to %s:%s over port %s\n' "$target" "$storage_root" "$ssh_port"

ssh -p "$ssh_port" "$target" "test -d '$storage_root/applications/koreader' && mkdir -p '$storage_root/applications/koreader/patches' '$storage_root/system/fonts'"

printf '%s\n' 'Copying patches/...'
tar -C "$repo_root/patches" --exclude=.gitkeep -cf - . |
    ssh -p "$ssh_port" "$target" "tar -C '$storage_root/applications/koreader/patches' -xf -"

printf '%s\n' 'Copying fonts/...'
tar -C "$repo_root/fonts" --exclude=.gitkeep -cf - . |
    ssh -p "$ssh_port" "$target" "tar -C '$storage_root/system/fonts' -xf -"

printf '%s\n' 'Deployment complete. Restart KOReader on the target to load changes.'
