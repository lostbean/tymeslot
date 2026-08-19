#!/bin/bash
#
# Fly.io entrypoint.
#
# Deliberately small. `start-docker.sh` is mostly the embedded-Postgres path —
# initialising a cluster, migrating a data directory between major versions,
# waiting for a local socket — and none of that applies when the database is a
# managed service. What is left is the part that is genuinely necessary: fix up
# the volume's ownership, refuse to start on a misconfiguration that would
# otherwise fail confusingly later, migrate, and hand over to the release.
set -euo pipefail

log() { echo "[fly-entrypoint] $*"; }
die() { echo "[fly-entrypoint] FATAL: $*" >&2; exit 1; }

# --- Preflight -------------------------------------------------------------
#
# Each of these is checked here rather than left to the release because the
# failure it prevents is one that reads as something else. A missing
# DATABASE_URL surfaces as a connection refused to localhost; a missing
# SECRET_KEY_BASE raises from deep inside config/runtime.exs during boot, after
# the machine has already been marked as started.

[ -n "${DATABASE_URL:-}" ] || die "DATABASE_URL is not set. Set it to the Neon connection string:
  fly secrets set DATABASE_URL='postgresql://user:pass@ep-xxx.region.aws.neon.tech/tymeslot?sslmode=require'"

[ -n "${SECRET_KEY_BASE:-}" ] || die "SECRET_KEY_BASE is not set. Generate one with:
  fly secrets set SECRET_KEY_BASE=\$(mix phx.gen.secret)"

[ -n "${PHX_HOST:-}" ] || die "PHX_HOST is not set. It must match the hostname the app is served on,
  or generated URLs (booking links, OAuth redirects, email links) will point elsewhere."

# Neon requires TLS and rejects a plaintext connection outright. The app maps an
# `sslmode` in the URL onto Postgrex's TLS options, so its absence is a silent
# misconfiguration rather than a loud one — caught here while the message can
# still say what to do about it.
case "${DATABASE_URL}" in
  *sslmode=*) ;;
  *) die "DATABASE_URL carries no sslmode. Neon requires TLS; append ?sslmode=require" ;;
esac

# Mail is not optional at boot. `EMAIL_ADAPTER` defaults to `smtp`, and the
# release raises out of its config provider when the SMTP settings are absent —
# during migration, as an ArgumentError several frames deep, long after the
# machine looks like it started. Checked here so the message names the secret
# instead of the stack frame.
#
# `EMAIL_ADAPTER=test` is the deliberate escape hatch: it discards every email
# and lets the app boot with no mail provider at all, which is worth having
# while you are still clicking through the UI.
if [ "${EMAIL_ADAPTER:-smtp}" = "smtp" ]; then
  [ -n "${SMTP_HOST:-}" ] || die "SMTP_HOST is not set, and EMAIL_ADAPTER defaults to smtp.
  Set the Mailtrap credentials:
    fly secrets set SMTP_HOST=sandbox.smtp.mailtrap.io SMTP_USERNAME=... SMTP_PASSWORD=...
  Or discard email entirely while trying things out:
    fly secrets set EMAIL_ADAPTER=test"
fi

# Both are required even when email is discarded — they are the From header on
# every message the app composes, so `runtime.exs` raises for them whichever
# adapter is in use. Checked together because discovering them one failed boot
# at a time is exactly what this block exists to prevent.
[ -n "${EMAIL_FROM_ADDRESS:-}" ] || die "EMAIL_FROM_ADDRESS is not set. It is the From address on
  every booking confirmation and reminder, and is required even with
  EMAIL_ADAPTER=test:
    fly secrets set EMAIL_FROM_ADDRESS=tymeslot@yourdomain.com"

[ -n "${EMAIL_FROM_NAME:-}" ] || die "EMAIL_FROM_NAME is not set. It is the display name beside the
  From address:
    fly secrets set EMAIL_FROM_NAME=Tymeslot"

if [ -z "${DATA_ENCRYPTION_KEY:-}" ]; then
  log "WARNING: DATA_ENCRYPTION_KEY is unset. Calendar credentials are encrypted"
  log "         with a key derived from SECRET_KEY_BASE, so rotating that secret"
  log "         would make every stored credential undecryptable. Set it with:"
  log "           fly secrets set DATA_ENCRYPTION_KEY=\$(openssl rand -base64 48)"
fi

# --- Volume ----------------------------------------------------------------
#
# Fly mounts the volume as root, and the release runs as `app`. Without this the
# first avatar upload fails on a permission error that looks like an application
# bug. Runs every boot because a newly-provisioned volume is empty and a
# restored one may carry different ownership.
mkdir -p /app/data/uploads
chown -R app:app /app/data

# --- Migrate ---------------------------------------------------------------
#
# Before the server accepts traffic, and fatal if it fails: a release serving
# requests against a schema it does not expect produces errors that are far
# harder to read than a machine that refused to start. Fly keeps the previous
# version serving until the new one passes its health check, so a failure here
# is a failed deploy rather than an outage.
log "running migrations"
if ! su -p app -c "cd /app && bin/tymeslot eval 'Ecto.Migrator.with_repo(Tymeslot.Repo, &Ecto.Migrator.run(&1, :up, all: true))'"; then
  die "migrations failed — not starting the server. The previous release keeps serving."
fi
log "migrations complete"

# --- Serve -----------------------------------------------------------------
#
# `exec` so the BEAM becomes PID 1 and receives Fly's SIGTERM directly, which is
# what lets Oban finish the job it is holding instead of being killed mid-write
# to somebody's calendar.
log "starting tymeslot on port ${PORT:-8080}"
exec su -p app -c "cd /app && bin/tymeslot start"
