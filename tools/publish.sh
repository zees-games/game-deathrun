#!/bin/bash
# Publishes this game's pack (id mg-deathrun). courses is a link to mg-deathrun-maps, its own pack; screenshots and ci are
# not runtime content. Host addons come from the server (--host-addons).
#   tools/publish.sh [--version V | --bump patch] [--site URL --token-file F --dry-run ...]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$HERE/../dot-cloud/tools/publish_pack.sh" publish --source "$HERE" --id game-deathrun \
    --host-addons "$HERE/../dot-server-deploy/addons.lock" --exclude-dir courses --exclude-dir screenshots --exclude-dir ci \
    --lock "$HERE/content.lock.json" "$@"
