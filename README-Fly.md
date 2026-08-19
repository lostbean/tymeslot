# Deploying Tymeslot on Fly.io with Neon Postgres

A single always-on Fly machine, a Neon database, and Mailtrap for email. Enough
to run the app for real and exercise cross-calendar sync end to end.

## What you actually need

Three services, and only the first two are non-negotiable.

| Service | Why it is needed | Cost to start |
| --- | --- | --- |
| **Fly.io** | Runs the app and holds the uploads volume | ~$5–10/mo for `shared-cpu-1x` with 1GB |
| **Neon** | Postgres. Everything except uploaded files lives here | Free tier is enough to begin |
| **Mailtrap** | Booking confirmations, reminders, cancellations, password resets | Free tier |
| Google Cloud | *Only* if you want to connect Google Calendar | Free |

Nothing else is required. Redis, a job runner and a cron service are all
sometimes assumed for an app like this and none applies: Oban keeps its queues
**in Postgres** and runs its own cron inside the release, which is why the
machine must not auto-stop.

CalDAV (Fastmail, Nextcloud, iCloud) and ICS feeds need **no setup at all** —
users type a URL and an app password. Google is the only calendar provider that
costs you a registration, and it is the one worth doing, because it is the only
provider that supports mirroring a recurring series as a single repeating event.

## Order of operations

Do these in order; each step needs the one before it.

### 1. Neon

Create a project and a database named `tymeslot`. Copy the **pooled** connection
string — Neon offers a direct one too, and the pooled endpoint is what you want
for an app that holds a connection pool open.

It looks like:

```
postgresql://user:password@ep-xxx-pooler.eu-central-1.aws.neon.tech/tymeslot?sslmode=require
```

Keep the `?sslmode=require`. Neon rejects plaintext connections, and the app
reads that parameter to decide its TLS options — the entrypoint refuses to start
without it rather than letting you discover it as a connection error.

### 2. Mailtrap

For trying things out, use a **sandbox** inbox: mail is captured rather than
delivered, so you can watch a booking confirmation render without sending
anything to a real person. Its SMTP credentials are on the inbox's *Integrations*
tab.

When you want mail actually delivered, switch to a Mailtrap **sending domain**
(needs DNS records) and swap the host and credentials. Nothing else changes.

### 3. Fly

```sh
fly auth login
fly apps create tymeslot            # or your own name — update fly.toml to match
fly volumes create tymeslot_data --region ams --size 3
```

Then edit `fly.toml`: set `app` to the name you created, `primary_region` to
your region, and `PHX_HOST` to the hostname you will serve on.

**`PHX_HOST` is not cosmetic.** Every booking link, OAuth redirect and URL inside
an email is generated from it. Get it wrong and attendees are sent somewhere
else.

### 4. Secrets

```sh
fly secrets set \
  DATABASE_URL='postgresql://…?sslmode=require' \
  SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  DATA_ENCRYPTION_KEY="$(openssl rand -base64 48)" \
  EMAIL_ADAPTER='smtp' \
  SMTP_HOST='sandbox.smtp.mailtrap.io' \
  SMTP_PORT='587' \
  SMTP_USERNAME='your-mailtrap-username' \
  SMTP_PASSWORD='your-mailtrap-password' \
  EMAIL_FROM_ADDRESS='tymeslot@yourdomain.com' \
  EMAIL_FROM_NAME='Tymeslot'
```

Five of those are genuinely mandatory — the release refuses to boot without
`DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST` (set in `fly.toml`),
`EMAIL_FROM_ADDRESS` and `EMAIL_FROM_NAME`. The last two are required even when
email is switched off, because they are the From header on every message the app
composes. The entrypoint checks all of them before migrating and names the one
that is missing, rather than letting the release raise from inside its config
provider halfway through a deploy.

**Booting is not the same as working.** Those checks cover what the release
needs in order to start, and nothing more. A variable read only when a feature
is used — `GOOGLE_STATE_SECRET` when someone clicks Connect, for instance —
passes every boot-time check and then fails at the moment the feature is
reached. This list was built by booting the image and watching what it refused
to start without, so it is complete for booting and complete for nothing else.
Each optional integration below states its own variables.

To boot with no mail provider at all while you click around, set
`EMAIL_ADAPTER=test` and drop the four `SMTP_*` values. Every email is then
discarded, so booking flows complete but nothing is delivered or captured.

**Set `DATA_ENCRYPTION_KEY` now, before anyone connects a calendar.** Without it
the app derives its encryption key from `SECRET_KEY_BASE`, which means rotating
that secret later makes every stored calendar credential permanently
undecryptable. Setting it afterwards means running the re-encryption sweep. The
entrypoint warns when it is missing but will not stop you.

### 5. Deploy

```sh
fly deploy
```

The entrypoint checks its configuration, runs migrations, and only then starts
the server. Fly keeps the previous version serving until the new one passes its
health check, so a failed migration is a failed deploy rather than an outage.

Create your first account at `https://<your-app>.fly.dev` — the first registered
user becomes the admin.

### 6. Google Calendar (optional, but the interesting one)

In [Google Cloud Console](https://console.cloud.google.com):

1. New project → enable the **Google Calendar API**.
2. Configure the OAuth consent screen. While it is in *Testing*, add your own
   account under *Test users* or the sign-in will be refused.
3. Create an **OAuth client ID** of type *Web application*, with these exact
   redirect URIs:

   ```
   https://<your-app>.fly.dev/auth/google/calendar/callback
   https://<your-app>.fly.dev/auth/google/callback
   ```

   The first is for connecting a calendar; the second only if you also want
   Google sign-in.

4. ```sh
   fly secrets set \
     GOOGLE_CLIENT_ID='…apps.googleusercontent.com' \
     GOOGLE_CLIENT_SECRET='GOCSPX-…' \
     GOOGLE_STATE_SECRET="$(openssl rand -base64 48)"
   ```

**`GOOGLE_STATE_SECRET` is the one that is easy to miss.** It does not come
from Google — you generate it. It signs the OAuth `state` parameter, which is
what proves a callback belongs to a flow this app started rather than one an
attacker began on their own account. Any high-entropy string works; there is no
length or format requirement, because it is used as an HMAC-SHA256 key.

Without it the **Connect** button fails before it ever reaches Google, with:

> Google Auth is not configured. Please set GOOGLE_CLIENT_ID,
> GOOGLE_CLIENT_SECRET, and GOOGLE_STATE_SECRET environment variables.

Nothing appears in `fly logs` when this happens, which makes it confusing to
diagnose: the failure is raised while building the authorisation URL, so no
request is ever made and no callback is ever received. If Connect does nothing
and the logs are silent, this is why.

Generate it somewhere you can keep it. Rotating it later invalidates any
authorisation already in progress — someone mid-consent gets an invalid-state
error and has to start again. Harmless with one user, worth knowing with more.

Outlook and Zoom have the same requirement under `OUTLOOK_STATE_SECRET` and
`ZOOM_STATE_SECRET`, and fail the same silent way. Set them if you connect
those providers.

To sign in with Google as well as connect calendars, add
`ENABLE_OAUTH_AUTH=true` and `ENABLE_GOOGLE_AUTH=true`. Leave them unset and
Google is a calendar integration only.

## Exercising cross-calendar sync

The feature needs two connected calendars on one account. The cheapest real test
is two Google calendars, or one Google plus a Fastmail/Nextcloud CalDAV account.

1. Connect both under **Integrations → Calendars**.
2. Open the **Calendar sync** tab and link one to the other.
3. Create an event on the source calendar.
4. Within a minute or two a "Busy" block appears on the target.

What to look for, since these are the parts most likely to be wrong:

- The mirror is **hidden from your own grid** — it exists for external tools, and
  drawing it beside its source would double every event.
- It still **blocks availability**: your booking page will not offer that slot.
- A **recurring** Google event becomes **one** repeating block, not one per
  occurrence, and it starts where the series starts rather than at its last
  occurrence.
- Cancelling a single occurrence frees that slot on the target, and leaves the
  rest of the series blocked. Google reports the cancellation on the occurrence
  rather than on the series master, so a full re-sync alone does not carry it —
  the change arrives on the delta sync a webhook triggers, or on the next sweep.
- Moving a single occurrence moves the block with it: the slot it left is freed
  and the slot it went to is blocked, both on the same repeating placeholder
  rather than a second event. It is still recorded in the conflict log, which is
  what you read when a calendar looked wrong and you want to know why. Detection
  reads a marker only Google supplies, so a move on a CalDAV source is neither
  corrected nor reported.

Nothing happens instantly. Google pushes changes by webhook, and everything else
is caught by a sweep every fifteen minutes with a mirror reconcile every thirty.
`fly logs` shows the jobs running.

### Validating it from the running node

`scripts/validate_sync_links.exs` performs the checks above automatically:
create, move, cancel and delete, for a one-off event and for a recurring
series, then an inventory of the invariants a mirror loop violates. It uses
whichever sync link the account already has, writes only events prefixed
`TYMESLOT-VALIDATION`, and withdraws each one before it finishes.

```sh
fly ssh sftp shell --app tymeslot <<'SFTP'
put scripts/validate_sync_links.exs /tmp/validate_sync_links.exs
SFTP

fly ssh console --app tymeslot <<'REMOTE'
/app/bin/tymeslot rpc 'Code.eval_file("/tmp/validate_sync_links.exs")'
exit
REMOTE
```

Three mechanics in those commands are not incidental:

- **`rpc`, not `eval`.** `eval` starts a fresh VM with no application, so every
  `Repo` call dies with "could not lookup Ecto repo Tymeslot.Repo because it was
  not started".
- **Heredocs, not `-C`.** Passing the script through
  `fly ssh console -C "... rpc '...'"` fails on the nested quotes, and reports
  it as an Elixir macro-expansion error rather than as a shell one.
- **`put` refuses to overwrite.** Re-uploading after an edit needs the remote
  path removed first, or a new name.

Read the last two lines. `RESULT: OK` means every check passed; anything else
names the check that failed and what it saw. The inventory section is the part
worth watching over time — it asserts that no placeholder sits on the *source*
calendar, that no mirror names another mirror's output as its source, and that
no mirror row targets the link's own source. Those three were all false during a
live mirror loop, where one real event grew copies three generations deep in two
minutes.

A count of zero is reported as a **failure**, not a pass: a run that examined
nothing otherwise reports success exactly as loudly as one that examined
everything.

If the target calendar has lost its authorisation the run stops at the
preconditions and says so. That is the correct outcome rather than a fault —
a mirror onto an inactive target is refused by design, because the alternative
is a placeholder written to whichever calendar the booking resolver falls back
to, which is how the loop above started.

## Operating it

```sh
fly logs                                   # follow
fly ssh console                            # shell on the machine
fly ssh console -C "/app/bin/tymeslot remote"   # IEx against the running node
fly status                                 # machine health
```

**If a Connect button does nothing and `fly logs` shows nothing**, the
provider's `*_STATE_SECRET` is missing — `GOOGLE_STATE_SECRET`,
`OUTLOOK_STATE_SECRET` or `ZOOM_STATE_SECRET`. The failure happens while
building the authorisation URL, so no request leaves the app and no log line is
written. Silence in the logs is the symptom, not the absence of one.

Uploads live on the volume, so `fly volumes snapshots` covers avatars and theme
backgrounds. Neon takes care of database backups, and its branching feature is
worth knowing about: you can fork the database to test a migration against real
data without touching production.

## Things worth knowing before they surprise you

**The machine deliberately never sleeps.** `auto_stop_machines = false` looks
like a cost mistake and is not. Oban's cron lives in the release, so a stopped
machine runs no calendar sync and no mirror reconcile. The first symptom of an
overnight sleep is a double booking, not a slow page.

**One machine, because of the volume.** A Fly volume belongs to a single machine
and cannot be shared, and uploads are written to disk rather than to Postgres.
Running two machines means half your avatars 404. Scaling out means moving
uploads to object storage — Tigris is Fly-native and S3-compatible — and that is
the one change that unlocks it.

**Watch the connection pool.** `DATABASE_POOL_SIZE` is set to 10 here, well below
the app's own default of 60, which is sized for a Postgres you own. Neon's pooler
is stricter. If you scale up, raise this deliberately rather than by accident.

**Region matters more than usual.** Every calendar sync is an outbound HTTPS call
to Google or a CalDAV host, and every query crosses to Neon. Put the Fly region
and the Neon region in the same place; `ams` and `eu-central-1` are close enough,
but a machine in `syd` talking to a database in Virginia will feel slow in a way
no amount of tuning fixes.
