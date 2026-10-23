#!/usr/bin/env bash
# Deploys this fork of Umami on the VPS. Run it there, as deployuser:
#
#   bash ~/apps/umami/scripts/deploy-vps.sh            # deploy master
#   bash ~/apps/umami/scripts/deploy-vps.sh <branch>   # deploy another branch
#   bash ~/apps/umami/scripts/deploy-vps.sh --rollback # back to the previous release
#
# Each deploy builds a fresh clone under ~/apps/umami-releases/, so the running
# version keeps serving during the build. Before building it dumps the database,
# because the build applies Prisma migrations to it (scripts/check-db.js). Then it
# points ~/apps/umami at the new release and recreates the PM2 process. The last
# KEEP_RELEASES releases stay on disk for --rollback; a rollback does NOT undo
# migrations — restore the dump printed by the deploy if the schema changed.
set -euo pipefail

PNPM="pnpm@12.3.4"
APP_NAME=umami
PORT=3060
REPO=git@github.com:Sneyder2328/umami.git
LIVE=$HOME/apps/umami
RELEASES=$HOME/apps/umami-releases
BACKUPS=$HOME/backups/umami
KEEP_RELEASES=2
# Next's build is the heaviest step on a box shared with production apps.
BUILD_HEAP_MB=2048

export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
if [ -s "$NVM_DIR/nvm.sh" ]; then . "$NVM_DIR/nvm.sh"; fi

health_check() {
  for _ in $(seq 1 30); do
    if curl -sf --max-time 5 -o /dev/null "http://127.0.0.1:$PORT/api/heartbeat"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

current_release() { readlink -f "$LIVE"; }

# First deploy only: ~/apps/umami is the original checkout, not a symlink. Move
# it into the releases dir and link it back, so it can be rolled back to like
# any other release. The running process is unaffected (its cwd moves with it).
adopt_legacy() {
  if [ -d "$LIVE" ] && [ ! -L "$LIVE" ]; then
    local legacy
    legacy="$RELEASES/legacy-$(date +%Y%m%d%H%M%S)"
    mv "$LIVE" "$legacy"
    ln -sfn "$legacy" "$LIVE"
  fi
}

# Points ~/apps/umami at a release and recreates the PM2 process from it. Not a
# reload: a recreate makes PM2 pick up the release's script path.
activate() {
  local release="$1"
  pm2 delete "$APP_NAME" > /dev/null 2>&1 || true
  ln -sfn "$release" "$LIVE"
  (cd "$release" && pm2 start ecosystem.config.cjs > /dev/null)
}

previous_release() {
  local current
  current="$(current_release)"
  find "$RELEASES" -mindepth 1 -maxdepth 1 -type d ! -path "$current" -printf '%T@ %p\n' \
    | sort -rn | head -1 | cut -d' ' -f2-
}

rollback() {
  local target
  target="$(previous_release)"
  [ -n "$target" ] || { echo "✗ No previous release to roll back to" >&2; exit 1; }
  echo "→ Rolling back to $(basename "$target")..."
  activate "$target"
  health_check || { echo "✗ $(basename "$target") did not answer on :$PORT" >&2; exit 1; }
  pm2 save > /dev/null
  echo "✓ Rolled back. Database migrations were NOT reverted."
}

deploy() {
  local branch="$1" stamp release dump url previous
  stamp="$(date +%Y%m%d%H%M%S)"
  mkdir -p "$RELEASES"
  (umask 077 && mkdir -p "$BACKUPS")

  echo "→ Cloning $branch..."
  git clone --quiet --depth 1 --branch "$branch" "$REPO" "$RELEASES/$stamp"
  release="$RELEASES/$stamp-$(git -C "$RELEASES/$stamp" rev-parse --short HEAD)"
  mv "$RELEASES/$stamp" "$release"
  cp "$(current_release)/.env" "$release/.env"

  dump="$BACKUPS/umami-pre-$stamp.sql.gz"
  echo "→ Backing up the database to $dump..."
  # Prisma URLs may carry ?schema=…, which pg_dump rejects.
  url="$(set -a && . "$release/.env" && printf '%s' "${DATABASE_URL%%\?*}")"
  (umask 077 && pg_dump --no-owner "$url" | gzip > "$dump")

  echo "→ Installing and building (this applies pending migrations)..."
  (
    cd "$release"
    nice -n 10 npx -y "$PNPM" install --frozen-lockfile
    NODE_OPTIONS="--max-old-space-size=$BUILD_HEAP_MB" nice -n 10 npx -y "$PNPM" build
  )

  adopt_legacy
  previous="$(current_release)"
  echo "→ Switching PM2 to $(basename "$release")..."
  activate "$release"
  if ! health_check; then
    echo "✗ New release did not answer on :$PORT; restoring $(basename "$previous")" >&2
    pm2 logs "$APP_NAME" --lines 30 --nostream || true
    activate "$previous"
    echo "  The database was migrated; if the old release fails, restore $dump" >&2
    exit 1
  fi
  pm2 save > /dev/null
  echo "✓ Umami is live on $(basename "$release") (backup: $dump)"

  # Keep the newest releases; the live one is never removed.
  find "$RELEASES" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn \
    | tail -n +$((KEEP_RELEASES + 1)) | cut -d' ' -f2- | while read -r old; do
      [ "$old" = "$(current_release)" ] || rm -rf "$old"
    done
}

case "${1:-}" in
  --rollback) rollback ;;
  *) deploy "${1:-master}" ;;
esac
