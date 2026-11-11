# Gostly self-hosted with Docker Compose

This repository runs Gostly on your own machine with Docker Compose. Gostly sits between your
services and the APIs they call: it records real traffic, then replays it as mocks you can
control. The Lite stack runs the proxy, the control plane with its dashboard, and PostgreSQL.
The Full stack adds the AI services that generate mocks. The images are private, so you need a
Gostly account at https://gostly.ai for a license key; the setup script uses the key to sign in
to the image registry. The local secrets are generated on your machine and never leave it.
Usage telemetry to gostly.ai is on by default. `GOSTLY_TELEMETRY=off` in `.env` turns it off; the
license checks still run. The hosts the stack contacts are listed under
[Network requirements](https://gostly.ai/docs/install#network-requirements).

Release `2026.11.0`. The image digests are listed under [Releases](#releases).

## Off by default: read this before you rely on a feature

Some capabilities ship off, or wait for a value from you, because they send traffic out of your
network, keep more than the defaults do, or ask you to trust something. Others changed their
default in this release. Each one below is a single line in `.env`: set it, then run
`docker compose up -d`, which recreates the services that read it. TLS interception also needs
port 8443 published (see [TLS interception port](#tls-interception-port)). `.template.env`
repeats this list at its top, and Settings > Status in the dashboard shows each one's current
state.

### Off, or waiting for a value

#### Accept invalid upstream TLS certificates

- **Why it is off:** For development upstreams only: with it on, the proxy cannot tell your upstream from anything impersonating it.
- **Tradeoffs:**
  - security: upstream certificate checks are skipped, so a man in the middle on the upstream path goes unnoticed
- **Turn it on:** `ACCEPT_INVALID_CERTS=true` in `.env`, then `docker compose up -d`.
- **Check it took effect:** A request to an upstream with a self-signed certificate is proxied instead of failing its TLS check.

#### AI mock-repair proposer

- **Why it is off:** The background proposer drafts repairs for drifted mocks on its own and replays a recorded request against the upstream for each. The Repair pages work either way.
- **Tradeoffs:**
  - egress: each proposal replays one recorded request, without credentials, to the service's upstream
  - resources: one leader-elected loop in ghost-web
  - license: proposals need the ai_mock_repair feature
- **Turn it on:** `ENABLE_AI_MOCK_REPAIR=true` in `.env`, then `docker compose up -d`.
- **Check it took effect:** ghost-web logs ai_mock_repair_loop_enabled at start, and proposals appear under Quality > Repair.
- **Stack:** `docker-compose.full.yaml` only.

#### Per-cluster threshold calibration

- **Why it is off:** Off uses the fixed RAG and generation thresholds (0.92, 0.75, 0.80); on, thresholds are calibrated per cluster from the observations recorded either way.
- **Tradeoffs:**
  - quality: calibrated thresholds follow your traffic, and move as it changes
  - operations: takes effect at restart
- **Turn it on:** `ENABLE_CONFORMAL_CALIBRATION=true` in `.env`, then `docker compose up -d`.
- **Check it took effect:** ghost-inference logs calibration_loaded at start instead of calibration_disabled.
- **Stack:** `docker-compose.full.yaml` only.

#### Pinned adapter set for the model sidecar

- **Why it is off:** Off, the llama.cpp sidecar loads every adapter in its directory. On, it loads exactly the digest- and size-verified set inference publishes, and refuses to start on a missing or changed adapter.
- **Tradeoffs:**
  - security: on, an adapter file changed on disk is refused
  - operations: restart ghost-llamacpp after a binding or pin change
- **Turn it on:** `ENABLE_ADAPTER_HOTSET_MANIFEST=true` in `.env`, then `docker compose up -d`.
- **Check it took effect:** ghost-llamacpp starts with the published set, and fails its start when an adapter in it is missing or changed.
- **Stack:** `docker-compose.full.yaml` only.

#### Smart swap on a Free license

- **Why it is off:** A Free license serves exact matches only. This opts the proxy in to answering a near miss with the closest recorded mock; paid licenses turn smart swap on themselves, and the license still sets the ceiling.
- **Tradeoffs:**
  - quality: a near miss gets a close recorded answer instead of the miss response, which can hide a recording you still need
- **Turn it on:** `SMART_SWAP_ENABLED=true` in `.env`, then `docker compose up -d`.
- **Check it took effect:** A request one field away from a recording answers from it instead of the miss response.
- **Stack:** `docker-compose.full.yaml` only.

#### Strict outbound guard (block private networks)

- **Why it is off:** Off so upstreams on your private Docker network, your LAN or loopback keep working. The floor that blocks link-local and cloud metadata addresses is always on.
- **Tradeoffs:**
  - security: on, the proxy also refuses loopback, RFC 1918, CGNAT and IPv6 ULA destinations, which narrows what a misrouted request can reach
  - egress: upstreams on private addresses stop working while it is on
- **Turn it on:** `GOSTLY_EGRESS_STRICT=true` in `.env`, then `docker compose up -d`.
- **Check it took effect:** ghost-proxy logs 'egress guard: STRICT mode ON' at start.
- **Stack:** `docker-compose.full.yaml` only.

#### TLS interception (HTTPS capture)

- **Why it is off:** To read HTTPS traffic the proxy acts as a certificate authority your clients trust. That is a trust decision you make, so the listener on port 8443 stays unbound.
- **Tradeoffs:**
  - security: a client that trusts the Gostly CA accepts any certificate the proxy mints; install the CA only on the clients you capture
  - privacy: decrypted HTTPS requests and responses are recorded like plain HTTP
  - resources: one TLS handshake per new host; leaf certificates are cached (TLS_CACHE_SIZE, TLS_CACHE_TTL_DAYS)
- **Turn it on:** `ENABLE_TLS_INTERCEPTION=true` in `.env`, then `docker compose up -d`.
- **Check it took effect:** GET http://localhost:8080/ca.crt returns the CA certificate instead of 503 and port 8443 accepts connections; then trust the CA on each client.
- **Stack:** `docker-compose.full.yaml` only.

#### Upstream alignment probing

- **Why it is off:** It sends recorded requests to your real upstreams to measure how closely the mocks still match them: outbound traffic the proxy would not otherwise make.
- **Tradeoffs:**
  - egress: the fidelity recomputer re-sends recorded requests, without credentials, to each service's upstream
  - resources: one probe per scored route per recompute
- **Turn it on:** `ENABLE_UPSTREAM_ALIGNMENT_SYNC=true` in `.env`, then `docker compose up -d`.
- **Check it took effect:** After the next recompute the fidelity scores' upstream-alignment values (GET /v1/fidelity) are filled instead of empty.
- **Stack:** `docker-compose.full.yaml` only.

#### Verbatim recordings on disk

- **Why it is off:** Off, recordings on disk drop Authorization, Cookie and token headers and live credential formats. On keeps them, for air-gapped installs that need byte-exact replay after a restart.
- **Tradeoffs:**
  - privacy: credentials in headers and bodies are written to disk as captured
  - security: anyone who can read the data volume can read them
- **Turn it on:** `MOCK_PERSIST_VERBATIM=true` in `.env`, then `docker compose up -d`.
- **Check it took effect:** The proxy's /health shows capture.disk_verbatim_mocks true and capture.redacted_at_rest false.
- **Stack:** `docker-compose.full.yaml` only.

#### Verbatim webhook headers on disk

- **Why it is off:** Off, captured webhooks on disk drop the redacted headers and live credential formats (bodies are always kept for signature replay). On keeps them, for air-gapped installs only.
- **Tradeoffs:**
  - privacy: webhook header credentials are written to disk as received
  - security: anyone who can read the data volume can read them
- **Turn it on:** `WEBHOOK_PERSIST_VERBATIM=true` in `.env`, then `docker compose up -d`.
- **Check it took effect:** The proxy's /health shows capture.disk_verbatim_webhooks true and capture.redacted_at_rest false.
- **Stack:** `docker-compose.full.yaml` only.

#### WebSocket frame capture

- **Why it is off:** Frames are written to disk exactly as sent, with no per-frame redaction, so a token carried inside a WebSocket (a connection_init payload, for example) is stored.
- **Tradeoffs:**
  - privacy: in-band credentials and message bodies are stored unredacted
  - resources: every frame in both directions of a captured service's WebSockets is written to the data volume
- **Turn it on:** `ENABLE_WS_CAPTURE=true` in `.env`, then `docker compose up -d`.
- **Check it took effect:** The proxy's GET http://localhost:8080/health shows capture.ws_capture_enabled true and capture.redacted_at_rest false.

#### Notification channels (Slack, Teams, Mattermost, webhook, email)

- **Why it is off:** There is no default destination: drift digests, webhook-capture failures and license deadlines go nowhere until you name a channel.
- **Tradeoffs:**
  - egress: messages go to the channel URL or SMTP relay you configure
  - privacy: a message carries the install name and an event summary; a channel's detail setting (minimal, summary or schema) sets how much
  - security: the channel URL is a credential; prefer GOSTLY_NOTIFY_URL_FILE, and sign a generic webhook with GOSTLY_NOTIFY_SECRET
- **Turn it on:** `GOSTLY_NOTIFY_URL=https://hooks.slack.com/services/...` in `.env`, then `docker compose up -d`.
- **Check it took effect:** Settings > Status shows the notifier check with the channel, and its test sends a message. Several channels: GOSTLY_NOTIFY_CONFIG (docs/operations/notifications.md).
- **Stack:** `docker-compose.full.yaml` only.

#### OpenTelemetry trace export (OTLP)

- **Why it is off:** Traces leave the install only when you name a collector; unset, no span is sent.
- **Tradeoffs:**
  - egress: the API sends its spans to the collector you name
  - privacy: what a span carries is listed in docs/operations/tracing.md
  - security: put a collector credential in OTEL_EXPORTER_OTLP_HEADERS
- **Turn it on:** `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318` in `.env`, then `docker compose up -d`.
- **Check it took effect:** The collector receives ghost-web's spans on /v1/traces.
- **Stack:** `docker-compose.full.yaml` only.

#### Outbound private-origin allow-list

- **Why it is off:** Empty admits no private address, so a webhook or canary replay, a spec import or a model connection reaches an internal host only once you list it.
- **Tradeoffs:**
  - security: each entry is one exact scheme://host:port the API may reach on your network; scope it (spec:, model:, replay:) and keep the list short
  - egress: link-local, metadata, multicast and reserved addresses are never admitted
- **Turn it on:** `GOSTLY_OUTBOUND_ALLOWED_PRIVATE_ORIGINS=spec:https://specs.internal:443` in `.env`, then `docker compose up -d`.
- **Check it took effect:** A refused internal target names the exact entry to add; Settings > Status shows the private_origins check.
- **Stack:** `docker-compose.full.yaml` only.

### On by default (changed in 2026.11.0)

#### Activities feed

- **What it does and why it is on:** On since 2026.11.0. It was held off until every API replica could read the 0033 projection; the Compose install replaces ghost-web in one step. Turn it off to hide the feed.
- **Tradeoffs:**
  - resources: reads the existing job tables; nothing new is written
- **Turn it off:** `ACTIVITIES_V2_ENABLED=0` in `.env`, then `docker compose up -d`.
- **Turn it back on:** `ACTIVITIES_V2_ENABLED=true`.
- **Check it took effect:** GET /v1/activities answers 200 (404 while it is off).

#### Archive training versions

- **What it does and why it is on:** On since 2026.11.0. It was held off until no API replica that predates training versions could delete adapter files. Turn it off to refuse archiving.
- **Tradeoffs:**
  - resources: an archived version keeps its files; nothing is deleted
- **Turn it off:** `TRAINING_VERSION_ARCHIVE_ENABLED=0` in `.env`, then `docker compose up -d`.
- **Turn it back on:** `TRAINING_VERSION_ARCHIVE_ENABLED=true`.
- **Check it took effect:** Training offers Archive on a version; while off, archiving answers 409 training_version_archive_rollout_incomplete.

#### Capture retention (30 days on new installs)

- **What it does and why it is on:** A new install keeps raw captures 30 days. An upgraded install keeps its own .env, which has no such line, so nothing it already holds is deleted unannounced: add the line to opt in. Empty keeps webhooks and frames; wide events, new in 2026.11.0, keep 30 days either way.
- **Tradeoffs:**
  - privacy: inbound webhooks, WebSocket frames and wide events older than the limit are deleted; recordings and LEARN traffic logs are kept
  - resources: bounds how much the data volume and the database grow
- **Turn it off:** `GOSTLY_CAPTURE_MAX_AGE_DAYS=` in `.env`, then `docker compose up -d`.
- **Turn it back on:** `GOSTLY_CAPTURE_MAX_AGE_DAYS=30`.
- **Check it took effect:** A retention pass that removed anything writes a capture.retention_prune record to the retained audit (Admin > Audit).

#### Receipt transition worker

- **What it does and why it is on:** On since 2026.11.0: the leader-elected worker runs the LEARN to MOCK jobs admitted with an operation receipt (no route admits one yet, so it idles). Turn it off to leave such jobs queued.
- **Tradeoffs:**
  - resources: one polling loop on one API worker, on the cross-tenant service pool (GOSTLY_WORKER_* settings)
- **Turn it off:** `GOSTLY_RECEIPT_TRANSITION_WORKER=0` in `.env`, then `docker compose up -d`.
- **Turn it back on:** `GOSTLY_RECEIPT_TRANSITION_WORKER=1`.
- **Check it took effect:** ghost-web logs receipt_transition_worker_loop_enabled at start.

#### Time Chamber snapshot, fork and reset

- **What it does and why it is on:** On since 2026.11.0. It was held off until no older ghost-web could replay a keyed episode retry. Turn it off to refuse REST and keyed MCP snapshot, fork and reset; the proxy's own /ghost/* episode routes do not need it.
- **Tradeoffs:**
  - resources: a snapshot or fork is stored by the proxy within its episode quotas
- **Turn it off:** `GOSTLY_SHARED_EPISODE_MUTATIONS_ENABLED=0` in `.env`, then `docker compose up -d`.
- **Turn it back on:** `GOSTLY_SHARED_EPISODE_MUTATIONS_ENABLED=true`.
- **Check it took effect:** GET /v1/time-chamber/capabilities reports the mutations; while off a snapshot answers 503 episode_mutation_cutover_not_enabled.

#### Wide-event observability

- **What it does and why it is on:** On since 2026.11.0: the proxy writes one event per recorded request (method, route pattern, status, latency, workload class) and the API mirrors them. Turn it off to write none.
- **Tradeoffs:**
  - privacy: events stay on the install (gostly.ai never receives them), and capture retention bounds them
  - resources: one line per recorded request on the data volume, mirrored into PostgreSQL
- **Turn it off:** `ENABLE_OBSERVABILITY=false` in `.env`, then `docker compose up -d`.
- **Turn it back on:** `ENABLE_OBSERVABILITY=true`.
- **Check it took effect:** Insights shows the Workload mix tile, and GET /v1/wide-events returns events.
- **Stack:** `docker-compose.full.yaml` only.

## Project structure

```text
gostly-docker-compose/
├── .gitignore                # keeps .env and local overrides out of git
├── .template.env             # the settings template; copy it to .env
├── docker-compose.full.yaml  # Full stack: Lite plus the AI services
├── docker-compose.yaml       # Lite stack (the default)
├── README.md                 # this file
└── setup.sh                  # fills .env, checks the key, signs in to the registry, starts the stack
```

## Services

`docker-compose.yaml` (excerpt). Every Gostly image is pinned by digest, so a release always
runs the same bytes:

```yaml
services:
  ghost-postgres:
    image: postgres:16-alpine
  ghost-migrate:
    image: 242201285974.dkr.ecr.us-east-1.amazonaws.com/gostlyai/web@sha256:7bbed4862ad153e216abf2e552d5ae0187a51c1cfb0e2d6abbfade7427c8aa98
  ghost-web:
    image: 242201285974.dkr.ecr.us-east-1.amazonaws.com/gostlyai/web@sha256:7bbed4862ad153e216abf2e552d5ae0187a51c1cfb0e2d6abbfade7427c8aa98
  ghost-proxy:
    image: 242201285974.dkr.ecr.us-east-1.amazonaws.com/gostlyai/proxy@sha256:b6a8fa17deedcb6c3d58e5e59b84b4afd3692547cf03999756089321ee140611
  gostly-demo-upstream:   # optional: runs only while .env sets COMPOSE_PROFILES=demo
    image: mccutchen/go-httpbin:v2.15.0@sha256:24528cf5229d0b70065ac27e6c9e4d96f5452a84a3ce4433e56573c18d96827a
```

`docker-compose.full.yaml` runs the same services plus:

```yaml
services:
  ghost-llamacpp:   # Full only: the model sidecar, with no route to the internet
    image: 242201285974.dkr.ecr.us-east-1.amazonaws.com/gostlyai/llamacpp@sha256:de9273feacad26bbcc66ea34a14ca2e6c88e0ffb622619ade41a7c0c9829bf8f
  ghost-inference:   # Full only: the inference router
    image: 242201285974.dkr.ecr.us-east-1.amazonaws.com/gostlyai/inference@sha256:b75220235d05ed251e859913d13a709aae1e02fa8b34f59e9113cee7503ff7aa
```

## Installation steps

You need Docker with Compose v2.22 or later (`docker compose`), git, curl, and a Gostly account.
The Full stack needs Docker Compose v2.26 or later and Docker Engine 26 or later, and enough
memory for the limits of its AI containers (see [Resources](#resources)). `setup.sh` is a POSIX
shell script for macOS and Linux; on Windows, run it inside WSL. It checks these before it asks
for anything (see [What setup.sh asks and does](#what-setupsh-asks-and-does)).

1. Get the files and go into them.

   ```bash
   git clone https://github.com/gostlyai/gostly-docker-compose gostly-docker-compose && cd gostly-docker-compose
   ```

2. Run the setup script. It checks Docker and the ports first, asks Lite or Full, asks for your
   account values and your license key, checks the key, signs in to the Gostly registry with the
   key when an image is missing, and starts the stack.

   ```bash
   ./setup.sh
   ```

3. Open http://localhost:3000 and sign in with the email and password from step 2. The script's
   last lines print the address, the email, and the password when it generated one.

Then send a first request through the bundled demo upstream:
`curl http://localhost:8080/gostly-demo/get`.

### What setup.sh asks and does

Every step is skipped when it is already done, so a second run changes nothing in `.env`,
except that on an update the rollout-gate step below turns on gates an older template wrote as
`false`.

- **Settings file.** Copies `.template.env` to `.env`, readable only by you, when `.env` is
  missing.
- **Rollout gates.** On an update, turns on each rollout gate an older template wrote as `false`
  (`ACTIVITIES_V2_ENABLED`, `GOSTLY_SHARED_EPISODE_MUTATIONS_ENABLED`,
  `TRAINING_VERSION_ARCHIVE_ENABLED`, `GOSTLY_RECEIPT_TRANSITION_WORKER`), and prints each line it
  changed. To keep one off, set it to `0`: this step leaves `0` alone.
- **Checks first.** Before it asks for anything, it checks that Docker is running and reachable
  from this terminal (it prints the engine, the Docker context and the Compose version), that
  Compose is v2.22 or later, and that the dashboard, API and proxy ports (3000, 8000 and 8080,
  or the ones set in `.env`) are free; ports this installation's own running containers hold
  are fine. It also stops when your shell exports `GOSTLY_LICENSE_KEY`, `GOSTLY_ADMIN_EMAIL`,
  `GOSTLY_ADMIN_PASSWORD`, `GOSTLY_TENANT_ID` or `COMPOSE_FILE` with a value other than the one
  in `.env`, because Docker Compose would use the shell's value (see
  [A variable exported in your shell overrides .env](#a-variable-exported-in-your-shell-overrides-env)).
- **Lite or Full.** Asks once, with Lite as the default, and writes `COMPOSE_FILE`. For Full it
  then checks Compose v2.26 and Docker Engine 26, and warns when Docker has less memory than
  the Full stack's limits or, on a Linux engine, less free disk than its images take (see
  [Lite or Full](#lite-or-full)).
- **Local secrets.** Generates `POSTGRES_PASSWORD`, `GOSTLY_APP_DB_PASSWORD`, `GOSTLY_SERVICE_DB_PASSWORD`, `GHOST_API_KEY` on this machine, once. They are never printed
  and never replaced.
- **Admin email.** Asks for the email you sign in with, suggesting your `git config user.email`,
  and writes `GOSTLY_ADMIN_EMAIL`.
- **Admin password.** Asks for a password of 12 to 72 characters without showing it, twice.
  Press Enter instead to have it generate 24 characters, which it prints once, when the script
  finishes or stops; it is also in `.env`. It writes `GOSTLY_ADMIN_PASSWORD`; a password you
  chose is never printed.
- **License key.** Asks for your key without showing it. Copy the key from your dashboard at
  https://gostly.ai/dashboard, which shows it in full once, when you create or rotate it. It
  writes `GOSTLY_LICENSE_KEY`.
- **Key check and Workspace ID.** Sends the key to gostly.ai (`POST /v1/license/features`, a
  check that takes no seat) on every run, so a key you replaced in `.env` is checked before
  anything starts. On a fresh install it writes the Workspace ID it returns to
  `GOSTLY_TENANT_ID`, so you never copy it; the Workspace ID keeps your data on one tenant when
  you rotate the key. A key gostly.ai does not recognise, or one whose trial or subscription has
  ended, stops the script before anything is downloaded or started. A `GOSTLY_TENANT_ID` already
  in `.env` is never replaced; when the key belongs to another workspace, the script says so. To
  start an installed stack without a connection, run `./setup.sh --skip-key-check`.
- **Existing data.** When this directory's database volume already exists but `.env` has no
  `GOSTLY_TENANT_ID` (an install from before the script set it), the script writes the tenant
  that data is under instead of the Workspace ID, so the data stays visible (see
  [Existing data and GOSTLY_TENANT_ID](#existing-data-and-gostly_tenant_id)). When Docker cannot
  list the volumes, the script leaves `GOSTLY_TENANT_ID` empty rather than guess, and fills it on
  a later run once `docker volume ls` works.
- **Registry login.** Only when an image is not on this machine yet. It asks gostly.ai for a
  registry token with your license key (`GET /v1/license/registry-credentials`; the key travels
  in a request header, never on a command line) and hands the token to `docker login` on its
  standard input. Nothing from it is stored by the script, and the login lasts 12 hours.
- **Start.** Runs `docker compose pull` for the missing images and `docker compose up -d`, then
  waits up to four minutes until every enabled service is running, and healthy where it has a
  health check, and the one-shot ghost-migrate job has exited 0. A service that stopped or was
  never created stops the script with its name, so the last line only says Gostly is running
  when it is.

`./setup.sh --help` lists the options: `--no-start` stops once `.env` is complete and checks,
pulls and starts nothing, `--non-interactive` lists the values `.env` still needs instead of
asking, and `--skip-key-check` leaves out the call to gostly.ai (the stack then runs unlicensed
if `.env` has no key).

### Lite or Full

Lite runs the proxy, the dashboard with its API, PostgreSQL and the demo upstream: everything you
need to record traffic and replay it as mocks. Full adds ghost-inference and ghost-llamacpp, the
AI services that generate mocks.

| | Lite | Full |
|---|---|---|
| Images on disk, as Docker reported them for the images pinned on 2026-10-20 (linux/arm64, Docker Desktop) | about 1.8 GB | about 21.4 GB |
| Memory limits of its containers (see [Resources](#resources)) | none | 12 GB for ghost-inference and `LLAMACPP_MEM_LIMIT` (6 GB by default) for ghost-llamacpp |
| Docker versions | Compose v2.22 | Compose v2.26 and Engine 26 |

Image sizes differ by platform and release. `setup.sh` warns, without stopping, when Docker has
less than about 20 GB of memory for Full, or (on a Linux engine, where it can read the free
space of Docker's data directory) less free disk than the images take. Start with Lite unless
your first task needs generated mocks; you can switch later (see
[Docker compose commands](#docker-compose-commands)).

### Agent Studio host requirements

Agent Studio runs generated code as Landlock and seccomp jailed child processes of ghost-web,
with no extra container, so what it can run depends on the host kernel. Studio checks need
Landlock ABI 1+ (Linux 5.13+); private-proxy runs need ABI 4 (Linux 6.7+); on Debian 12/AL2023
checks still run while proxy runs report unavailable. The Agent Studio page and `/health` name
the reason when a part cannot run. On Docker Desktop, a host directory bind-mounted at `/data`
makes jailed Studio proxy runs fail closed (Landlock rules do not match files on the shared
host filesystem), so keep `/data` on the `gostly-data` volume the Compose files define.

### Updating

```bash
git pull
./setup.sh
```

The script skips the account steps, checks your key again, signs in to the registry with your
key only when the new release has images this machine does not have, downloads them and
restarts the stack. Your data stays as it is, and `.env` keeps your values except the rollout
gates described under [What setup.sh asks and does](#what-setupsh-asks-and-does).

### Manual steps

The same install without `setup.sh`, for reference:

1. Get the files.

   ```bash
   git clone https://github.com/gostlyai/gostly-docker-compose gostly-docker-compose
   ```

2. Go into the directory.

   ```bash
   cd gostly-docker-compose
   ```

3. Create your private settings file. Do this once, on a fresh install: it replaces an
   existing `.env`.

   ```bash
   cp .template.env .env
   ```

4. Generate the local secrets. Each database password is 64 hex characters and `GHOST_API_KEY`
   is `gsk_svc_` and 43 URL-safe characters. Put each value on its empty line in `.env`:

   ```bash
   openssl rand -hex 32   # once for each of the three database passwords
   printf 'gsk_svc_%s\n' "$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"   # GHOST_API_KEY
   ```

5. Edit `.env` and set the values listed under
   [Required environment variable updates](#required-environment-variable-updates), including
   `GOSTLY_TENANT_ID`, your Workspace ID from Settings, Organization in your dashboard.

   ```bash
   "${EDITOR:-nano}" .env
   ```

6. Sign in to the Gostly registry. In your dashboard, open **Installing by hand**, choose
   **Copy registry login** and run the command. The token is valid for 12 hours and is read from
   standard input, never passed as an argument. The command has this form:

   ```bash
   printf '%s' '<registry-token>' | docker login --username AWS --password-stdin 242201285974.dkr.ecr.us-east-1.amazonaws.com
   ```

7. Download the images.

   ```bash
   docker compose pull
   ```

8. Start the stack.

   ```bash
   docker compose up -d
   ```

9. Open http://localhost:3000 and sign in with your `GOSTLY_ADMIN_EMAIL` and
   `GOSTLY_ADMIN_PASSWORD`.

## Required environment variable updates

`setup.sh` fills these in `.env` before the first start; set them yourself only when you follow
the manual steps. Everything else has a working default.

| Variable | What to set | Who sets it | Where the value comes from |
|---|---|---|---|
| `GOSTLY_ADMIN_EMAIL` | Your sign-in email address | setup.sh (asks you) | You choose it |
| `GOSTLY_ADMIN_PASSWORD` | 12 to 72 characters, in single quotes if it has `$`, `#` or spaces | setup.sh (asks you, or generates it) | You choose it, or setup.sh generates it and prints it once |
| `GOSTLY_ADMIN_FULL_NAME` | Optional display name | you | You choose it |
| `GOSTLY_AUTH_MODE` | Keep `password` | you (already set) | Already set in the template |
| `GOSTLY_LICENSE_KEY` | Your full license key | setup.sh (asks you) | Your gostly.ai dashboard, shown once when the key is created or rotated |
| `GOSTLY_TENANT_ID` | Your Workspace ID | setup.sh | Written by setup.sh from your key: gostly.ai returns the key's Workspace ID when it checks the key |

`setup.sh` writes `POSTGRES_PASSWORD`, `GOSTLY_APP_DB_PASSWORD`, `GOSTLY_SERVICE_DB_PASSWORD`, `GHOST_API_KEY`. Do not edit or regenerate them on an existing install: the
database volume keeps the passwords it started with.

## Configuration

### .env

Docker Compose reads `.env` from this directory for every command. `.template.env` is the
tracked template; `.env` is your copy of it. Copy rather than rename, so the template stays in
place and `git pull` never conflicts with your settings. `.env` is git-ignored and is never
replaced on upgrade.

- Compose expands `$` in unquoted and double-quoted values. Use single quotes for a value that
  must be read literally.
- A variable exported in your shell overrides the same line in `.env`.
- `docker compose config --quiet` checks the file and names the first missing required value.

### Admin

The first administrator of the local dashboard. The local sign-in page has no sign-up: this is
the only way to create the first account, so `setup.sh` asks for `GOSTLY_ADMIN_EMAIL` and
`GOSTLY_ADMIN_PASSWORD` before the first start. ghost-web creates the
account at the first start at which both are set and the database has no users; once it exists,
later starts never change it. If they were empty at the first start, set both in `.env` and run
`docker compose up -d` again, which recreates ghost-web with them and creates the account.

#### `GOSTLY_ADMIN_EMAIL`

The email address you sign in with at http://localhost:3000.

- Template value: empty
- Default when unset: empty

#### `GOSTLY_ADMIN_PASSWORD`

Your sign-in password: 12 to 72 characters. Wrap it in single quotes if it contains `$`, `#` or
spaces, so Compose reads it literally.

- Template value: empty
- Default when unset: empty

#### `GOSTLY_ADMIN_FULL_NAME`

Optional. The name the dashboard shows for this account.

- Template value: empty
- Default when unset: empty

#### `GOSTLY_AUTH_MODE`

The sign-in methods, comma separated. Keep `password`. `saml` and `oidc` also need the
identity-provider settings, which only `docker-compose.full.yaml` passes to ghost-web.

- Template value: `password`
- Default when unset: `password`

### License and tenant

These connect the install to your Gostly account. Both stacks read them.

#### `GOSTLY_LICENSE_KEY`

Your full license key; `setup.sh` asks for it. The dashboard shows it once, when you create
or rotate the key; if you no longer have it, rotate it there and run `./setup.sh` again after
emptying this line. Without it, licensed features stay off.

- Template value: empty
- Default when unset: empty

#### `GOSTLY_TENANT_ID`

Your organization ID, which the gostly.ai dashboard calls the Workspace ID and shows under
Settings, Organization. `setup.sh` writes it from your license key: gostly.ai returns the key's
Workspace ID when it checks the key. It keeps your data on one tenant when the license key is
rotated, because a Gostly license key does not carry it. It is not a secret. On an existing
install, keep the value you have; `setup.sh` never replaces it. An install whose data predates
this setting keeps the tenant its data is under instead (see
[Existing data and GOSTLY_TENANT_ID](#existing-data-and-gostly_tenant_id)).

- Template value: empty
- Default when unset: empty

### Demo upstream

A fresh install sends proxy traffic to a bundled demo service, so you can record and replay
before you connect your own. The two lines change together.

#### `COMPOSE_PROFILES`

`demo` starts the gostly-demo-upstream container. Delete the line when you proxy your own
service, then run `docker compose up -d` and `docker compose rm -sf gostly-demo-upstream`, which
stops and removes the demo container.

- Template value: `demo`
- Default when unset: read by Compose itself

#### `BACKEND_URL`

The upstream the proxy forwards to. The demo answers only under `/gostly-demo/`. For your own
service, set it to that service's URL, for example `http://your-service:3000`. Compose refuses
to start without it.

- Template value: `http://gostly-demo-upstream:8080`
- Default when unset: required

### Ports

| Service | Host | Container | What |
|---|---|---|---|
| ghost-web | `${GOSTLY_WEB_PORT:-3000}` | `3000` | the dashboard |
| ghost-web | `127.0.0.1:8000` | `8000` | the API, loopback only |
| ghost-proxy | `${GOSTLY_PROXY_PORT:-8080}` | `8080` | the proxy |

The dashboard and proxy host ports are read from `.env`; leave them unset to keep 3000 and 8080.
To use other ports, for example when 3000 is taken, set these four lines in `.env` (it already
has an `MCP_ALLOWED_ORIGINS` line: change that one):

```sh
GOSTLY_WEB_PORT=3001
GOSTLY_PROXY_PORT=8081
ALLOWED_ORIGINS=http://localhost:3001
MCP_ALLOWED_ORIGINS=http://localhost:3001
```

then run `docker compose up -d`. The two origin lines must name the dashboard's new address
exactly, or the dashboard cannot reach the API. Point your clients at the new proxy port.

The API stays on `127.0.0.1:8000`: the dashboard in this image calls `http://localhost:8000`,
so moving that port breaks the dashboard. If another program uses port 8000, stop it first.

An override in `docker-compose.override.yaml` (git-ignored) still works for other changes.
Use `ports: !override` there, because a plain `ports:` list is added to the published ports
rather than replacing them (Compose 2.24.4 or later). With `COMPOSE_FILE` set (`setup.sh`
writes it, and lists an override file that exists when it does), add the override to that line, for example
`COMPOSE_FILE=docker-compose.full.yaml:docker-compose.override.yaml`; otherwise Compose
ignores it.

```yaml
services:
  ghost-web:
    ports: !override
      - "3001:3000"
      - "127.0.0.1:8000:8000"
```

#### TLS interception port

With TLS interception on, the proxy captures HTTPS on port 8443. Neither Compose file publishes
port 8443. Only `docker-compose.full.yaml` passes `ENABLE_TLS_INTERCEPTION` from `.env` to the
proxy, so setting it in `.env` works in the Full stack only. To turn TLS interception on, set
`ENABLE_TLS_INTERCEPTION=true` in `.env` and publish the port in `docker-compose.override.yaml`:

```yaml
services:
  ghost-proxy:
    ports:
      - "8443:8443"
```

Here a plain `ports:` list is right: it adds 8443 to the proxy's published ports. The
`COMPOSE_FILE` line in `.env` must list the override after the Full file:
`COMPOSE_FILE=docker-compose.full.yaml:docker-compose.override.yaml`. Then run
`docker compose up -d`.

To check it took effect:

```bash
curl -fsS http://localhost:8080/ca.crt -o gostly-ca.crt   # saves the CA certificate
docker compose port ghost-proxy 8443                      # the published address, such as 0.0.0.0:8443
```

The first command fails with 503 until TLS interception has been turned on. When it succeeds,
trust `gostly-ca.crt` on each client you capture, and only on those.

### Resources

CPU and memory limits apply to the AI containers of `docker-compose.full.yaml`. The Lite stack
sets no limits.

| Service | Limit | Value |
|---|---|---|
| ghost-llamacpp | cpus | `${LLAMACPP_CPU_LIMIT:-4}` |
| ghost-llamacpp | memory | `${LLAMACPP_MEM_LIMIT:-6G}` |
| ghost-inference | cpus | `${INFERENCE_CPU_LIMIT:-4}` |
| ghost-inference | memory | `12G` |

The memory limit of ghost-inference is fixed in `docker-compose.full.yaml` and is not read from
`.env`. To change it, add this to `docker-compose.override.yaml`, list that file on the
`COMPOSE_FILE` line (see [Ports](#ports)), and run `docker compose up -d`:

```yaml
services:
  ghost-inference:
    deploy:
      resources:
        limits:
          memory: 16G
```

Replacing the container this way fails a training run that is in progress.

Training runs in ghost-inference, with its CPUs and threads (`INFERENCE_CPU_LIMIT`,
`INFERENCE_NUM_THREADS`). A training run has two hours. See
[Training time and failed runs](https://gostly.ai/docs/adapters#training-runs).

#### `INFERENCE_CPU_LIMIT`

CPUs for ghost-inference.

- Template value: not set
- Default when unset: `4`
- Read by: `docker-compose.full.yaml` only

#### `INFERENCE_NUM_THREADS`

Inference CPU threads; about three quarters of its CPUs.

- Template value: `4`
- Default when unset: `4`
- Read by: `docker-compose.full.yaml` only

#### `LLAMACPP_CPU_LIMIT`

CPUs for ghost-llamacpp.

- Template value: not set
- Default when unset: `4`
- Read by: `docker-compose.full.yaml` only

#### `LLAMACPP_MEM_LIMIT`

Memory for ghost-llamacpp. Raise it as you add trained adapters: the sidecar loads every
adapter at start.

- Template value: not set
- Default when unset: `6G`
- Read by: `docker-compose.full.yaml` only

### Inference (Full only)

These tune the AI services, which only `docker-compose.full.yaml` runs.

#### `ENABLE_RAG`

Match responses against recorded mocks before generating.

- Template value: `true`
- Default when unset: `true`
- Read by: `docker-compose.full.yaml` only

#### `GOSTLY_OUTPUT_BUDGET`

The output-token ceiling for one generated response.

- Template value: not set
- Default when unset: `2048`
- Read by: `docker-compose.full.yaml` only

#### `GOSTLY_INFERENCE_TIMEOUT_S`

The sidecar decode timeout; it must cover a full output budget.

- Template value: not set
- Default when unset: `120`
- Read by: `docker-compose.full.yaml` only

#### `GOSTLY_PREWARM_TIMEOUT_S`

The proxy's background prewarm timeout; it must also cover a full output budget.

- Template value: not set
- Default when unset: `120`
- Read by: `docker-compose.full.yaml` only

#### `GOSTLY_EVAL_TIMEOUT_S`

The ghost-web timeout for one evaluation run.

- Template value: not set
- Default when unset: `300`
- Read by: `docker-compose.full.yaml` only

#### `FINETUNE_CALLBACK_REQUEST_TIMEOUT_S`

The training callback request timeout, 0.05 to 30 seconds.

- Template value: `2`
- Default when unset: `2`
- Read by: `docker-compose.full.yaml` only

#### `FINETUNE_CALLBACK_TOTAL_DEADLINE_S`

The training callback total deadline, 0.1 to 120 seconds and at least the request timeout.

- Template value: `10`
- Default when unset: `10`
- Read by: `docker-compose.full.yaml` only

#### `FINETUNE_CALLBACK_TRANSPORT_THREAD_LIMIT`

The training callback threads, 1 to 64.

- Template value: `8`
- Default when unset: `8`
- Read by: `docker-compose.full.yaml` only

### MCP boundary

The browser boundary of the MCP endpoint. MCP stays a licensed feature; these settings do not
turn it on.

#### `MCP_ALLOWED_ORIGINS`

The exact browser origin of the dashboard. Change it if you publish the dashboard at another
URL; wildcards are refused.

- Template value: `http://localhost:3000`
- Default when unset: `http://localhost:3000`

#### `MCP_MAX_REQUEST_BODY_BYTES`

The largest MCP request body accepted, 1 KiB to 1 MiB.

- Template value: `1048576`
- Default when unset: `1048576`

### Generated secrets

`./setup.sh` fills each of these once, only when its line is present and empty, and never
prints a value. The database passwords are 64 hex characters; `GHOST_API_KEY` is `gsk_svc_`
and 43 URL-safe characters. Send the key as the `X-API-Key` header on API calls to port 8000.
If you delete the `GHOST_API_KEY` line before the first start, the dashboard manages the key
instead and can rotate it.

- `POSTGRES_PASSWORD`
- `GOSTLY_APP_DB_PASSWORD`
- `GOSTLY_SERVICE_DB_PASSWORD`
- `GHOST_API_KEY`

### Other settings

`.template.env` explains each of these in the comment above it.

| Variable | Template value | Default when unset |
|---|---|---|
| `ACTIVITIES_V2_ENABLED` | `true` | `true` |
| `GOSTLY_CAPTURE_MAX_AGE_DAYS` | `30` | empty |
| `GOSTLY_EPISODES` | `1` | `1` |
| `GOSTLY_SHARED_EPISODE_MUTATIONS_ENABLED` | `true` | `true` |
| `ENABLE_WS_CAPTURE` | `false` | `false` |
| `GOSTLY_CASCADE_SHADOW` | `1` | `1` |
| `AI_CONFIDENCE_THRESHOLD` | `0.70` | `0.70` |
| `POSTGRES_USER` | `ghost` | `ghost` |
| `POSTGRES_DB` | `ghost` | `ghost` |

## Docker compose commands

Run them from this directory.

```bash
docker compose pull                            # download the pinned images
docker compose up -d                           # start the stack, or apply changes to it
docker compose ps -a                           # list containers; ghost-migrate shows Exited (0)
docker compose logs -f ghost-web ghost-proxy   # follow the logs
docker compose down                            # stop and remove containers; data volumes stay
```

Never add `-v` to `down` unless you mean to delete every recording, mock and database row.

**Lite or Full.** `setup.sh` asks once and writes `COMPOSE_FILE` in `.env`; every command above
then uses that file. To switch later, set `COMPOSE_FILE=docker-compose.full.yaml` (Full) or
`COMPOSE_FILE=docker-compose.yaml` (Lite) and check with `docker compose config --services`.
Then run `docker compose up -d`, adding `--remove-orphans` when you go back to Lite so the AI
containers are removed.

**Upgrade.** `.env` keeps your values, except the rollout gates `setup.sh` turns on (see
[What setup.sh asks and does](#what-setupsh-asks-and-does)):

```bash
git pull                     # or: git fetch --tags && git checkout <release tag>
./setup.sh
```

## Deploy

```bash
docker compose up -d
```

Example output for the Lite stack on a first start. The layout depends on your Compose
version:

```text
[+] Running 8/8
 ✔ Network gostly-docker-compose_default       Created
 ✔ Volume gostly-docker-compose_postgres-data  Created
 ✔ Volume gostly-docker-compose_gostly-data    Created
 ✔ Container ghost-postgres                    Healthy
 ✔ Container ghost-migrate                     Exited
 ✔ Container ghost-web                         Healthy
 ✔ Container ghost-proxy                       Started
 ✔ Container gostly-demo-upstream              Started
```

ghost-migrate is a one-shot job: it applies the database migrations, prepares the service key
and exits. ghost-web starts only after it succeeds, and ghost-proxy after ghost-web is healthy.

## Validate the deployment

```bash
docker compose ps -a --format 'table {{.Name}}\t{{.Status}}'
```

Example (Lite, a few minutes after the start):

```text
NAME                   STATUS
ghost-postgres         Up 3 minutes (healthy)
ghost-migrate          Exited (0) 3 minutes ago
ghost-web              Up 3 minutes (healthy)
ghost-proxy            Up 3 minutes (healthy)
gostly-demo-upstream   Up 3 minutes
```

Then open the dashboard at http://localhost:3000. These log lines show that each step finished:

```bash
docker compose logs ghost-migrate | grep 'migration job complete'
docker compose logs ghost-migrate | grep 'installer_service_key_bootstrap'   # "status": "ready"
docker compose logs ghost-web | grep 'Application startup complete'
docker compose logs ghost-web | grep 'auth_admin_bootstrapped'   # the start that created the admin
docker compose logs ghost-proxy | grep 'License validated (live)'
docker compose logs ghost-proxy | grep 'proxy live at'
curl -fsS http://127.0.0.1:8000/health   # the API
curl -fsS http://localhost:8080/health   # the proxy
```

## Troubleshooting

### If setup.sh stops

- *Docker is not running, or this user cannot reach it*: start Docker Desktop (or the Docker
  service), check that `docker info` works in this terminal and that the Docker context the
  message names is the one you use, and run `./setup.sh` again.
- *Docker Compose ... is too old*, or *the Full stack needs Docker Compose 2.26 or later and
  Docker Engine 26 or later*: update Docker. For Full, you can also set
  `COMPOSE_FILE=docker-compose.yaml` in `.env` to run Lite.
- *another program is using port ...*: see [A port is in use](#a-port-is-in-use).
- *this shell exports ... with a value other than the one in .env*: see
  [A variable exported in your shell overrides .env](#a-variable-exported-in-your-shell-overrides-env).
- *gostly.ai does not recognise this key*: the key is mistyped, revoked, expired, or belongs to
  another Gostly account. The script empties `GOSTLY_LICENSE_KEY` in `.env`; create or rotate a
  key at https://gostly.ai/dashboard and run `./setup.sh` again.
  On an installed stack (`GOSTLY_TENANT_ID` set) the script keeps the key line: put a key from
  the dashboard in `GOSTLY_LICENSE_KEY`, keep `GOSTLY_TENANT_ID`, and run `./setup.sh` again.
- *this key's trial or subscription has ended*: renew at https://gostly.ai, then run
  `./setup.sh` again; `./setup.sh --skip-key-check` starts the stack without the check.
- *could not check the key*: gostly.ai was not reachable. Check the connection, or run
  `./setup.sh --skip-key-check` (on a fresh install, then set `GOSTLY_TENANT_ID` yourself:
  Settings, Organization).
- *this directory already has Gostly data ... setup.sh could not tell which tenant*: see
  [Existing data and GOSTLY_TENANT_ID](#existing-data-and-gostly_tenant_id).
- *gostly.ai did not accept this license key for the image registry*: the key in `.env` is
  mistyped, revoked, expired, or from another account. Create or rotate a key at
  https://gostly.ai/dashboard, replace `GOSTLY_LICENSE_KEY` in `.env`, keep `GOSTLY_TENANT_ID`,
  and run `./setup.sh` again.
- *gostly.ai is still rate limiting registry sign-ins*: the script already waited a minute and
  tried once more. Wait a few minutes and run `./setup.sh` again.
- *Could not get a registry sign-in from gostly.ai*: the script then asks for the registry
  login command instead. In your dashboard, open **Installing by hand**, choose **Copy registry
  login** and paste the command at the prompt; it is not shown, and only that exact command, for
  the registry these Compose files use, is run. Press Enter instead if you are signed in already.
- *that is not the registry login command*: copy it again with **Copy registry login** and
  paste the whole line. Registry logins last 12 hours.
- *still empty in .env*: you ran it with `--non-interactive`; set the named values in `.env`,
  or run it in a terminal to be asked.
- *... stopped (exit code ...)* or *the stack was not healthy*: a service that must keep running
  stopped, or was never created. Run `docker compose ps -a` and `docker compose logs <service>`
  for the one named, fix the cause, and run `./setup.sh` again.

### If the dashboard does not load

1. See which container is not running: `docker compose ps -a`. ghost-web waits for
   ghost-migrate, so a failed migration leaves the dashboard down.
2. Check `.env` itself: `docker compose config --quiet` names a required value that is missing,
   such as `BACKEND_URL must be set in .env`.
3. Database connection and migrations:

   ```bash
   docker compose logs ghost-migrate | grep -E 'alembic_migrations_(applied|failed)|credential boundary'
   docker compose logs ghost-web | grep -E 'alembic_head_preflight_passed|migration preflight complete'
   ```

   `alembic_migrations_failed` right after you changed or regenerated a database password means
   the existing volume still has the old one. Put the original values back in `.env`.
4. License validation:

   ```bash
   docker compose logs ghost-proxy | grep -E 'License validated|No GOSTLY_LICENSE_KEY set'
   ```

   `No GOSTLY_LICENSE_KEY set` means `.env` has no key. Paste the full key, then run
   `docker compose up -d`.
5. Admin bootstrap:

   ```bash
   docker compose logs ghost-web | grep -E 'auth_admin_bootstrap'
   ```

   `auth_admin_bootstrapped` appears once, on the start that creates the account.
   `auth_admin_bootstrap_failed` and `auth_admin_bootstrap_tenant_mismatch` give the reason. If
   the admin values were empty at the first start, set both and run `docker compose up -d`: the
   account is created while the database has no users. Once an account exists, changing the
   values does not change it.
6. The proxy answers `502 Bad Gateway` for `/gostly-demo/` requests: `.env` still points
   `BACKEND_URL` at the demo, but `COMPOSE_PROFILES=demo` is missing, so the demo container never
   started.

   ```bash
   grep -E '^(COMPOSE_PROFILES|BACKEND_URL)=' .env
   docker ps -a --filter name=gostly-demo-upstream   # nothing listed: the demo is not running
   ```

   Put `COMPOSE_PROFILES=demo` back and run `docker compose up -d`, or set `BACKEND_URL` to your
   own service.

## Common issues

Each entry gives the symptom, its cause and the fix. Run the commands from this directory.

### Sign-in fails in Safari or another WebKit browser

- **Symptom:** on a plain-http install such as http://localhost:3000, the local sign-in page takes
  your email and password and then shows the sign-in page again.
- **Cause:** the session cookie is marked `Secure` by default, and WebKit browsers do not keep
  a Secure cookie over plain http. The default assumes Chrome or Firefox on `localhost`.
- **Fix:** set `GOSTLY_AUTH_COOKIE_SECURE=false` in `.env`, then restart ghost-web with
  `docker compose up -d ghost-web`.

### The local sign-in page accepts no account

- **Symptom:** every email and password is refused, and
  `docker compose logs ghost-web | grep auth_admin_bootstrapped` prints nothing.
- **Cause:** `GOSTLY_ADMIN_EMAIL` or `GOSTLY_ADMIN_PASSWORD` was empty at the first start, so no
  account was created.
- **Fix:** set both in `.env` and run `docker compose up -d` again. The account is created on
  the next start when the database has no users.

### The dashboard says the key is not recognised, or the proxy logs 401

- **Symptom:** the local dashboard reports that gostly.ai does not recognise the license key,
  or `docker compose logs ghost-proxy` shows a 401 from the license server.
- **Cause:** the key is mistyped, revoked, expired, or from another Gostly account.
- **Fix:** create or rotate a key at https://gostly.ai/dashboard, replace `GOSTLY_LICENSE_KEY`
  in `.env` with it, keep `GOSTLY_TENANT_ID` as it is, and run `docker compose up -d`.

### The proxy reports the license seat in use

- **Symptom:** after a reinstall, or on a second machine, `docker compose logs ghost-proxy`
  shows *licence seat in use* (the license server's `seat_limit_exceeded`), and customer
  traffic stays locked.
- **Cause:** a trial has one seat, and the earlier install still holds it.
- **Fix:** wait for the seat to lapse, 24 hours after the earlier install was last seen (the
  proxy retries every minute), or revoke and rotate the key at https://gostly.ai/dashboard and
  put the new key in `.env`.

### The registry login expired

- **Symptom:** `docker compose pull` fails with an authorization error.
- **Cause:** registry logins last 12 hours.
- **Fix:** run `./setup.sh` again; it signs in with your key before it downloads.

### A port is in use

- **Symptom:** `setup.sh` stops with *another program is using port ...*, or
  `docker compose up -d` fails with *port is already allocated* or *address already in use*.
- **Cause:** another program uses 3000, 8080 or 8000 on this machine (or the ports set in
  `.env`). `setup.sh` checks 127.0.0.1 before it asks for anything. `lsof -i :3000` (macOS) or
  `ss -ltnp` (Linux) shows which program it is.
- **Fix:** set `GOSTLY_WEB_PORT` and `GOSTLY_PROXY_PORT` in `.env`, with `ALLOWED_ORIGINS` and
  `MCP_ALLOWED_ORIGINS` naming the new dashboard address (see [Ports](#ports)). Port 8000 must
  stay free, because the dashboard calls `http://localhost:8000`.

### A variable exported in your shell overrides .env

- **Symptom:** `setup.sh` stops with *this shell exports ... with a value other than the one in
  .env*, or the stack uses another license key, admin account or tenant than `.env` names.
- **Cause:** Docker Compose takes a variable set in the shell before the same line in `.env`,
  for example after you exported `GOSTLY_LICENSE_KEY` while working on another installation.
- **Fix:** run the `unset` command the message names (or open a new terminal), then run
  `./setup.sh` again. `env | grep -E '^(GOSTLY_|COMPOSE_FILE)' | cut -d= -f1` lists the names
  set in your shell without their values.

### Existing data and GOSTLY_TENANT_ID

- **Symptom:** `setup.sh` says this directory already has Gostly data and sets
  `GOSTLY_TENANT_ID` to a short value (16 hex characters, or `default`) instead of your
  Workspace ID, or it stops because it could not tell which tenant the data is under.
- **Cause:** the install ran before `GOSTLY_TENANT_ID` was set, so its data is under the tenant
  Gostly derived then: `default` without a license key, otherwise one derived from that key.
  Writing the Workspace ID would hide that data.
- **Fix:** nothing, when the script set the value: keep it, also when you rotate the key. When
  it stopped, start the stack as it is (`docker compose up -d`), print the tenant the running
  dashboard uses, which prints only the tenant ID:

  ```bash
  docker compose exec -T -w /app/api ghost-web python3 -c 'from deps import _resolve_tenant_id; print(_resolve_tenant_id())'
  ```

  put that value in `GOSTLY_TENANT_ID` in `.env`, and run `./setup.sh` again.

### An override file is ignored

- **Symptom:** a change in `docker-compose.override.yaml` has no effect.
- **Cause:** `COMPOSE_FILE` in `.env` names the Full file (or the Lite file), and with
  `COMPOSE_FILE` set Compose reads only the files it lists.
- **Fix:** list the override too, for example
  `COMPOSE_FILE=docker-compose.full.yaml:docker-compose.override.yaml`, and run
  `docker compose up -d`.

### The containers cannot connect to the database after .env was replaced

- **Symptom:** ghost-migrate exits with an error and the logs show
  `alembic_migrations_failed` or a password authentication failure.
- **Cause:** `.env` was regenerated or copied from `.template.env` over an existing install, so
  the database passwords changed, while the database volume keeps the ones it started with.
- **Fix:** restore the old `.env` from a backup and run `docker compose up -d`. Never run
  `cp .template.env .env` on an existing install.

### The Full stack fails to start for memory

- **Symptom:** an AI container of the Full stack exits or restarts, or Docker reports that it
  cannot allocate memory.
- **Cause:** Docker Desktop has less than about 20 GB of memory.
- **Fix:** raise it in Docker Desktop under Settings, Resources, or use the Lite stack (see
  [Resources](#resources)).

### A training run fails

- **Symptom:** a version on the Fine-tuning page shows Failed with "Training did not complete
  within 120 min and was reaped ..." or "Training worker shut down".
- **Cause:** the run reached its two-hour limit, or the inference service in ghost-inference
  stopped or restarted during the run.
- **Fix:** see [Training time and failed runs](https://gostly.ai/docs/adapters#training-runs). To
  train again, choose **Create new version** on the failed version, then **Train Model**.

## Upgrading

An upgrade changes the Compose files. In `.env`, `setup.sh` changes only the rollout gates an
older template wrote as `false` (see [What setup.sh asks and does](#what-setupsh-asks-and-does)):
keep `.env`, and keep your volumes. Take a
[backup](#backup) first: an upgrade migrates the database when ghost-migrate starts, and a migrated
database cannot be moved back by the older release.

```bash
git pull
./setup.sh
```

`setup.sh` signs in to the registry with your key only when the new release has an image this
machine does not have. Without the script, sign in with the command from **Installing by hand**,
**Copy registry login** in your dashboard, then run `docker compose pull` and
`docker compose up -d`.

What changes between releases is the set of image digests in the Compose files, plus any new
settings. `git diff <old tag> <new tag>` shows both. When `.template.env` gains a line, copy that
line into your `.env` if you want to change its default; a missing line uses the default, and
`docker compose config --quiet` names any new required value before you start.

`git pull` follows `main`, where every release is committed. A checkout of a release tag (see
[Releases](#releases)) has no branch to pull: move it with `git fetch --tags && git checkout <new
tag>`, or go back to following releases with `git checkout main && git pull`, then run
`./setup.sh`.

### Backup

Take one before every upgrade, from this directory, while the stack runs. It keeps four things in
`backups/`: the database, the secret-store key that opens the credentials sealed in it, your `.env`,
and the release you are on, whose Compose files pin its image digests.

```bash
mkdir -p backups && chmod 700 backups
git rev-parse HEAD > backups/release-commit
cp .env backups/env && chmod 600 backups/env
docker compose exec -T ghost-postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --create --clean --if-exists' > backups/gostly-db.sql; chmod 600 backups/gostly-db.sql
docker compose exec -T ghost-web sh -c 'cat "${GOSTLY_SECRET_STORE_KEY_FILE:-${DATA_DIR:-/data}/secret-store.key}"' > backups/secret-store.key; chmod 600 backups/secret-store.key
```

- The dump holds every service, recording index, user and setting, and the credentials you saved
  (model connections, provider keys) in sealed form. The key file opens them: keep the two together,
  and restore them together, or the sealed credentials cannot be read. When the key command says
  the file does not exist, no credential has been saved yet: the backup's key file stays empty, and
  the restore below skips it.
- `backups/` holds secrets (the key, the database passwords in `env`, recorded API traffic in the
  dump), and git ignores it. Whoever holds the folder can read the credentials you saved, because
  the key and the dump are in it together: store it as you would those credentials. Copy it off
  this machine to storage you trust, and keep the folder of each upgrade until the next one has run
  for a while.
- The recordings, mock library and adapters live on the `gostly-data` volume, which these steps do
  not copy. To keep them too, stop the stack (`docker compose stop`) and copy the volume with your
  usual volume backup tool, then `docker compose start`.

### Restore

Puts the database and the secret-store key back as they were when the backup was taken, on the
release this directory is on now. Every service but the database stops first, because the restore
drops and re-creates the database and nothing may hold it open.

On a new machine, set the stack up first: clone this repository, check out the release in
`backups/release-commit`, copy `backups/env` to `.env` (`chmod 600 .env`), and run `./setup.sh`
once. That creates the database and the roles the dump grants to, which the restore needs. Then run
the block below.

```bash
docker compose stop
docker compose up -d --wait ghost-postgres
docker compose exec -T ghost-postgres sh -c 'psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -q' < backups/gostly-db.sql
[ -s backups/secret-store.key ] && docker compose run --rm --no-deps -T --entrypoint sh ghost-web -c 'umask 077 && cat > "${GOSTLY_SECRET_STORE_KEY_FILE:-${DATA_DIR:-/data}/secret-store.key}"' < backups/secret-store.key
docker compose up -d
```

A dump only restores into the release that wrote it or a later one. To go back to the release
before an upgrade, use [Rollback](#rollback), which checks that release out first.

### Rollback

Goes back to the release you backed up, when an upgrade went wrong. The database is restored from
the backup, not migrated down: some migrations cannot be undone without losing data. Database
changes since the backup are lost; files written to the `gostly-data` volume since then stay.

```bash
docker compose stop
git checkout "$(cat backups/release-commit)"
cp backups/env .env
docker compose pull
docker compose up -d --wait ghost-postgres
docker compose exec -T ghost-postgres sh -c 'psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -q' < backups/gostly-db.sql
[ -s backups/secret-store.key ] && docker compose run --rm --no-deps -T --entrypoint sh ghost-web -c 'umask 077 && cat > "${GOSTLY_SECRET_STORE_KEY_FILE:-${DATA_DIR:-/data}/secret-store.key}"' < backups/secret-store.key
docker compose up -d
```

`git checkout` puts back the Compose files of that release, and with them its image digests;
`docker compose pull` downloads any of those images this machine no longer has (sign in to the
registry first if it asks, see [Manual steps](#manual-steps)). ghost-migrate then finds the
database at that release's schema and changes nothing. The checkout has no branch: when a fixed
release is out, `git checkout main && git pull`, take a new backup, and upgrade again.

### Rotating your license key

Rotating replaces the key and keeps your workspace. Your data stays on the same tenant as long as
`GOSTLY_TENANT_ID` in `.env` names it, so check that line before you rotate.

1. Before you rotate, open `.env` and look at `GOSTLY_TENANT_ID`. If it has a value, as on an
   install `setup.sh` made, go on to step 2. If it is empty, as on an install made before
   `setup.sh`, your data may be stored under a tenant derived from the current key, and a new key
   would point at a different, empty tenant. While the current key is still in place, pin that
   tenant first: https://gostly.ai/docs/install#license-key-rotation. Do not rotate until it is
   pinned.
2. In your dashboard at https://gostly.ai/dashboard, open **Settings**, **License keys**, and
   choose **Rotate**. Copy the new key; it is shown once. The old key stops working at the next
   license check, within about 24 hours.
3. In `.env`, replace the value of `GOSTLY_LICENSE_KEY` with the new key. Keep `GOSTLY_TENANT_ID`
   as it is: the key does not carry the tenant, so this line keeps your data where it is.
4. Apply the change:

   ```bash
   docker compose up -d
   ```

   Compose recreates ghost-web and ghost-proxy, the containers that read the key, because
   their settings changed. On the Full stack ghost-migrate reads it too, so its one-shot job
   runs again first. Restarting only one of them leaves the other on the old key.

### Releases

Each release is a git tag of this repository named `YYYY.MM.N`. Its Compose files pin the four
Gostly images by digest, the set that release promoted. The Gostly release tooling regenerates
this whole tree from Gostly's install templates when it publishes new images, commits it to
`main` and tags that commit. To stay on one release, check out its tag in your clone
(`git checkout <tag>`); `git checkout main` follows releases again.

Release: `2026.11.0`

| Image | Digest |
|---|---|
| `proxy` | `sha256:b6a8fa17deedcb6c3d58e5e59b84b4afd3692547cf03999756089321ee140611` |
| `web` | `sha256:7bbed4862ad153e216abf2e552d5ae0187a51c1cfb0e2d6abbfade7427c8aa98` |
| `inference` | `sha256:b75220235d05ed251e859913d13a709aae1e02fa8b34f59e9113cee7503ff7aa` |
| `llamacpp` | `sha256:de9273feacad26bbcc66ea34a14ca2e6c88e0ffb622619ade41a7c0c9829bf8f` |

## All environment variables

### Read from .env

Every variable the Compose files read from `.env` (or your shell), with the default Compose
uses when it is unset. `required` means Compose refuses to start without it.

| Variable | Default when unset | Lite | Full |
|---|---|---|---|
| `ACCEPT_INVALID_CERTS` | `false` | yes | yes |
| `ACTIVITIES_V2_ENABLED` | `true` | yes | yes |
| `ADAPTER_HOTSET_MAX_BYTES` | `68719476736` | no | yes |
| `ADAPTER_HOTSET_MAX_COUNT` | `64` | no | yes |
| `ADAPTER_HOTSET_PINS_FILE` | empty | no | yes |
| `AI_CONFIDENCE_THRESHOLD` | `0.70` | yes | yes |
| `ALLOWED_ORIGINS` | `http://localhost:3000` | yes | yes |
| `BACKEND_URL` | required | yes | yes |
| `CHAOS_SEED` | empty | yes | yes |
| `COMPOSE_FILE` | read by Compose itself | yes | yes |
| `COMPOSE_PROFILES` | read by Compose itself | yes | yes |
| `COMPOSE_PROJECT_NAME` | read by Compose itself | yes | yes |
| `DATABASE_URL` | `postgresql://gostly_app:${GOSTLY_APP_DB_PASSWORD:?}@ghost-postgres:5432/${POSTGRES_DB:-ghost}` | yes | yes |
| `DB_MAX_OVERFLOW` | `10` | no | yes |
| `DB_POOL_SIZE` | `5` | no | yes |
| `DRIFT_MATVIEW_REFRESH_ENABLED` | `1` | no | yes |
| `DRIFT_MATVIEW_REFRESH_INTERVAL_SECS` | `300` | no | yes |
| `DRIFT_MATVIEW_REFRESH_JITTER_SECS` | `30` | no | yes |
| `DRIFT_MATVIEW_REFRESH_STATEMENT_TIMEOUT_SECS` | `120` | no | yes |
| `EMBED_MODEL` | `all-MiniLM-L6-v2` | no | yes |
| `ENABLE_ADAPTER_HOTSET_MANIFEST` | `false` | no | yes |
| `ENABLE_AI_MOCK_REPAIR` | `false` | no | yes |
| `ENABLE_CONFORMAL_CALIBRATION` | `false` | no | yes |
| `ENABLE_OBSERVABILITY` | `true` | no | yes |
| `ENABLE_RAG` | `true` | no | yes |
| `ENABLE_TLS_INTERCEPTION` | `false` | no | yes |
| `ENABLE_UPSTREAM_ALIGNMENT_SYNC` | `false` | no | yes |
| `ENABLE_WS_CAPTURE` | `false` | yes | yes |
| `ENVIRONMENT` | `production` | yes | yes |
| `FINETUNE_CALLBACK_REQUEST_TIMEOUT_S` | `2` | no | yes |
| `FINETUNE_CALLBACK_TOTAL_DEADLINE_S` | `10` | no | yes |
| `FINETUNE_CALLBACK_TRANSPORT_THREAD_LIMIT` | `8` | no | yes |
| `GHOST_API_KEY` | empty | yes | yes |
| `GOSTLY_ADMIN_EMAIL` | empty | yes | yes |
| `GOSTLY_ADMIN_FULL_NAME` | empty | yes | yes |
| `GOSTLY_ADMIN_PASSWORD` | empty | yes | yes |
| `GOSTLY_AGENT_ID` | empty | no | yes |
| `GOSTLY_AGENT_SESSION_MAX_AGE_DAYS` | `365` | no | yes |
| `GOSTLY_APP_DB_PASSWORD` | required | yes | yes |
| `GOSTLY_AUDIT_RETENTION_DAYS` | `365` | yes | yes |
| `GOSTLY_AUTH_ALLOWED_DOMAINS` | empty | no | yes |
| `GOSTLY_AUTH_AUTO_PROVISION` | `true` | no | yes |
| `GOSTLY_AUTH_COOKIE_DOMAIN` | empty | yes | yes |
| `GOSTLY_AUTH_COOKIE_SECURE` | `true` | yes | yes |
| `GOSTLY_AUTH_DEFAULT_ROLE` | `viewer` | no | yes |
| `GOSTLY_AUTH_GROUP_TO_ROLE_MAP` | empty | no | yes |
| `GOSTLY_AUTH_MODE` | `password` | yes | yes |
| `GOSTLY_AUTH_SESSION_IDLE_MINUTES` | `0` | no | yes |
| `GOSTLY_AUTH_SESSION_TTL_HOURS` | `12` | yes | yes |
| `GOSTLY_AUTH_SIGN_IN_PER_HOUR` | `30` | no | yes |
| `GOSTLY_AUTH_SIGN_IN_PER_MINUTE` | `10` | no | yes |
| `GOSTLY_CAPTURE_MAX_AGE_DAYS` | empty | yes | yes |
| `GOSTLY_CASCADE_SHADOW` | `1` | yes | yes |
| `GOSTLY_DEFINITION_DIR` | `./.gostly` | no | yes |
| `GOSTLY_DRIFT_CHECK_MAX_EVENTS_PER_CHECK` | `500` | no | yes |
| `GOSTLY_DRIFT_CHECK_MAX_PROJECTED_BYTES_PER_CHECK` | `12582912` | no | yes |
| `GOSTLY_DRIFT_CHECK_MAX_PROJECTED_BYTES_PER_SESSION` | `8388608` | no | yes |
| `GOSTLY_DRIFT_CHECK_MAX_RECURSIVE_NODES_PER_CHECK` | `24000` | no | yes |
| `GOSTLY_DRIFT_CHECK_MAX_RECURSIVE_NODES_PER_SESSION` | `16000` | no | yes |
| `GOSTLY_DRIFT_CHECK_MAX_ROUTES_PER_CHECK` | `1500` | no | yes |
| `GOSTLY_DRIFT_CHECK_MAX_ROUTES_PER_SESSION` | `1000` | no | yes |
| `GOSTLY_DRIFT_CHECK_MAX_ROWS_PER_CHECK` | `8000` | no | yes |
| `GOSTLY_DRIFT_CHECK_MAX_ROWS_PER_SESSION` | `5000` | no | yes |
| `GOSTLY_EGRESS_STRICT` | `false` | no | yes |
| `GOSTLY_EPISODES` | `1` | yes | yes |
| `GOSTLY_EPISODE_TTL_SECS` | `3600` | no | yes |
| `GOSTLY_EVAL_ATTEMPT_MAX_HORIZON_S` | `3600` | no | yes |
| `GOSTLY_EVAL_ATTEMPT_REGISTRY_SIZE` | `4096` | no | yes |
| `GOSTLY_EVAL_LEASE_GRACE_S` | `30` | no | yes |
| `GOSTLY_EVAL_TIMEOUT_S` | `300` | no | yes |
| `GOSTLY_INFERENCE_TIMEOUT_S` | `120` | no | yes |
| `GOSTLY_LICENSE_KEY` | empty | yes | yes |
| `GOSTLY_LICENSE_REVALIDATE_SECS` | `300` | no | yes |
| `GOSTLY_MAX_EXECUTION_JOURNAL_BYTES` | `268435456` | no | yes |
| `GOSTLY_MAX_LIVE_EPISODES` | `64` | no | yes |
| `GOSTLY_MAX_SNAPSHOTS` | `64` | no | yes |
| `GOSTLY_MODEL_ALLOWED_PRIVATE_ORIGINS` | empty | no | yes |
| `GOSTLY_NOTIFY_CONFIG` | empty | no | yes |
| `GOSTLY_NOTIFY_SECRET` | empty | no | yes |
| `GOSTLY_NOTIFY_SECRET_FILE` | empty | no | yes |
| `GOSTLY_NOTIFY_URL` | empty | no | yes |
| `GOSTLY_NOTIFY_URL_FILE` | empty | no | yes |
| `GOSTLY_OIDC_CLIENT_ID` | empty | no | yes |
| `GOSTLY_OIDC_CLIENT_KEY_FILE` | empty | no | yes |
| `GOSTLY_OIDC_CLIENT_SECRET` | empty | no | yes |
| `GOSTLY_OIDC_CLIENT_SECRET_FILE` | empty | no | yes |
| `GOSTLY_OIDC_DISPLAY_NAME` | empty | no | yes |
| `GOSTLY_OIDC_EMAIL_CLAIM` | `email` | no | yes |
| `GOSTLY_OIDC_GROUP_CLAIM` | `groups` | no | yes |
| `GOSTLY_OIDC_ISSUER` | empty | no | yes |
| `GOSTLY_OIDC_NAME_CLAIM` | `name` | no | yes |
| `GOSTLY_OIDC_REDIRECT_URI` | empty | no | yes |
| `GOSTLY_OIDC_SCOPES` | `openid email profile groups` | no | yes |
| `GOSTLY_OUTBOUND_ALLOWED_ORIGINS` | empty | no | yes |
| `GOSTLY_OUTBOUND_ALLOWED_PRIVATE_ORIGINS` | empty | no | yes |
| `GOSTLY_OUTPUT_BUDGET` | `2048` | no | yes |
| `GOSTLY_PREWARM_TIMEOUT_S` | `120` | no | yes |
| `GOSTLY_PROXY_PORT` | `8080` | yes | yes |
| `GOSTLY_PROXY_PUBLIC_URL` | empty | no | yes |
| `GOSTLY_PUBLIC_URL` | empty | no | yes |
| `GOSTLY_RECEIPT_TRANSITION_WORKER` | `1` | yes | yes |
| `GOSTLY_SAML_EMAIL_ATTRIBUTE` | `email` | no | yes |
| `GOSTLY_SAML_GROUP_ATTRIBUTE` | `memberOf` | no | yes |
| `GOSTLY_SAML_IDP_ENTITY_ID` | empty | no | yes |
| `GOSTLY_SAML_IDP_METADATA_URL` | empty | no | yes |
| `GOSTLY_SAML_IDP_METADATA_XML` | empty | no | yes |
| `GOSTLY_SAML_NAME_ATTRIBUTE` | `displayName` | no | yes |
| `GOSTLY_SAML_SP_ACS_URL` | empty | no | yes |
| `GOSTLY_SAML_SP_ENTITY_ID` | empty | no | yes |
| `GOSTLY_SAML_SP_PRIVATE_KEY` | empty | no | yes |
| `GOSTLY_SAML_SP_PRIVATE_KEY_FILE` | empty | no | yes |
| `GOSTLY_SAML_SP_SLO_URL` | empty | no | yes |
| `GOSTLY_SAML_SP_X509_CERT` | empty | no | yes |
| `GOSTLY_SAML_SP_X509_CERT_FILE` | empty | no | yes |
| `GOSTLY_SERVICE_DB_PASSWORD` | required | yes | yes |
| `GOSTLY_SHARED_EPISODE_MUTATIONS_ENABLED` | `true` | yes | yes |
| `GOSTLY_SNAPSHOT_TTL_SECS` | `86400` | no | yes |
| `GOSTLY_STUDIO_RESULT_TTL_DAYS` | `7` | no | yes |
| `GOSTLY_TELEMETRY` | empty | yes | yes |
| `GOSTLY_TELEMETRY_TIER` | empty | no | yes |
| `GOSTLY_TENANT_ID` | empty | yes | yes |
| `GOSTLY_TRANSITION_CALIBRATION_MAX_LEGACY_CALLS` | `100` | no | yes |
| `GOSTLY_TRANSITION_MAX_CONCURRENT` | `4` | no | yes |
| `GOSTLY_TRANSITION_MAX_CONCURRENT_PER_TENANT` | `2` | no | yes |
| `GOSTLY_TRANSITION_MAX_SAMPLED_ENDPOINTS` | `1000` | no | yes |
| `GOSTLY_WEB_PORT` | `3000` | yes | yes |
| `GOSTLY_WORKER_HEARTBEAT_SECS` | `30` | no | yes |
| `GOSTLY_WORKER_LEASE_SECS` | `120` | no | yes |
| `GOSTLY_WORKER_MAX_CONCURRENT` | `1` | no | yes |
| `GOSTLY_WORKER_MAX_CONCURRENT_PER_TENANT` | `1` | no | yes |
| `GOSTLY_WORKER_POLL_INTERVAL_SECS` | `2.0` | no | yes |
| `GOSTLY_WORKER_RECONCILIATION_BACKOFF_SECS` | `30` | no | yes |
| `HTTPS_PROXY` | empty | no | yes |
| `HTTP_PROXY` | empty | no | yes |
| `INFERENCE_CPU_LIMIT` | `4` | no | yes |
| `INFERENCE_NUM_THREADS` | `4` | no | yes |
| `INITIAL_MODE` | `LEARN` | yes | yes |
| `INTERNAL_API_TOKEN` | empty | no | yes |
| `LICENSE_STALE_TTL` | `14400` | no | yes |
| `LLAMACPP_CPU_LIMIT` | `4` | no | yes |
| `LLAMACPP_DRAFT_MODEL` | empty | no | yes |
| `LLAMACPP_MEM_LIMIT` | `6G` | no | yes |
| `LLAMACPP_PARALLEL` | empty | no | yes |
| `LLAMACPP_THREADS` | empty | no | yes |
| `LLM_AZURE_API_KEY` | empty | no | yes |
| `LOG_FORMAT` | `json` | yes | yes |
| `LOG_LEVEL` | `info` | no | yes |
| `MAX_BODY_BYTES` | `1048576` | no | yes |
| `MCP_ALLOWED_ORIGINS` | `http://localhost:3000` | yes | yes |
| `MCP_MAX_REQUEST_BODY_BYTES` | `1048576` | yes | yes |
| `MIGRATIONS_DATABASE_URL` | `postgresql://${POSTGRES_USER:-ghost}:${POSTGRES_PASSWORD}@ghost-postgres:5432/${POSTGRES_DB:-ghost}` | yes | yes |
| `MOCK_PERSIST_VERBATIM` | `false` | no | yes |
| `MOCK_SESSION_MAX_BYTES` | `268435456` | no | yes |
| `MOCK_SESSION_MAX_ENTRIES` | `10000` | no | yes |
| `MOCK_SESSION_MAX_ENTRIES_TOTAL` | `10000` | no | yes |
| `NO_PROXY` | empty | no | yes |
| `OPENAI_API_KEY` | empty | no | yes |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | not passed | no | yes |
| `OTEL_EXPORTER_OTLP_HEADERS` | not passed | no | yes |
| `POSTGRES_DB` | `ghost` | yes | yes |
| `POSTGRES_PASSWORD` | required | yes | yes |
| `POSTGRES_USER` | `ghost` | yes | yes |
| `REDACT_HEADERS` | `Authorization,Cookie,X-Api-Key` | yes | yes |
| `SERVICE_DATABASE_URL` | `postgresql://gostly_service:${GOSTLY_SERVICE_DB_PASSWORD:?}@ghost-postgres:5432/${POSTGRES_DB:-ghost}` | yes | yes |
| `SERVICE_KEY_ROTATE_GRACE_SECS` | `300` | no | yes |
| `SMART_SWAP_ENABLED` | `false` | no | yes |
| `SSL_CERT_FILE` | not passed | no | yes |
| `TLS_CACHE_SIZE` | `8192` | no | yes |
| `TLS_CACHE_TTL_DAYS` | `7` | no | yes |
| `TLS_PRELOAD_HOSTS` | empty | no | yes |
| `TRAINING_VERSION_ARCHIVE_ENABLED` | `true` | yes | yes |
| `TRUSTED_PROXIES` | `127.0.0.1/32,::1/128,gateway` | no | yes |
| `WEBHOOK_CAPTURE_TOKEN` | empty | no | yes |
| `WEBHOOK_PERSIST_VERBATIM` | `false` | no | yes |

### Per container

What each container receives. A value with `${...}` comes from `.env`; any other value is fixed
by the Compose file.

#### ghost-postgres

| Variable | Value | Stack |
|---|---|---|
| `POSTGRES_USER` | `${POSTGRES_USER:-ghost}` | both |
| `POSTGRES_PASSWORD` | `${POSTGRES_PASSWORD:?}` | both |
| `POSTGRES_DB` | `${POSTGRES_DB:-ghost}` | both |

#### ghost-migrate

| Variable | Value | Stack |
|---|---|---|
| `GOSTLY_MIGRATION_MODE` | `migrate` | both |
| `ENVIRONMENT` | `${ENVIRONMENT:-production}` | both |
| `GHOST_API_KEY` | `${GHOST_API_KEY:-}` | both |
| `GOSTLY_REQUIRE_DISTINCT_DB_CREDENTIALS` | `1` | both |
| `MIGRATIONS_DATABASE_URL` | `${MIGRATIONS_DATABASE_URL:-postgresql://${POSTGRES_USER:-ghost}:${POSTGRES_PASSWORD}@ghost-postgres:5432/${POSTGRES_DB:-ghost}}` | both |
| `GOSTLY_APP_DB_PASSWORD` | `${GOSTLY_APP_DB_PASSWORD:?}` | both |
| `GOSTLY_SERVICE_DB_PASSWORD` | `${GOSTLY_SERVICE_DB_PASSWORD:?}` | both |
| `POSTGRES_PASSWORD` | `${POSTGRES_PASSWORD}` | both |
| `DATABASE_URL` | `${DATABASE_URL:-postgresql://gostly_app:${GOSTLY_APP_DB_PASSWORD:?}@ghost-postgres:5432/${POSTGRES_DB:-ghost}}` | both |
| `SERVICE_DATABASE_URL` | `${SERVICE_DATABASE_URL:-postgresql://gostly_service:${GOSTLY_SERVICE_DB_PASSWORD:?}@ghost-postgres:5432/${POSTGRES_DB:-ghost}}` | both |
| `AGENT_URL` | `http://ghost-proxy:8080` | both |
| `MOCK_DIR` | `/data/mocks` | both |
| `GOSTLY_AUDIT_RETENTION_DAYS` | `${GOSTLY_AUDIT_RETENTION_DAYS:-365}` | Full |
| `LOG_FORMAT` | `${LOG_FORMAT:-json}` | Full |
| `GOSTLY_LICENSE_KEY` | `${GOSTLY_LICENSE_KEY:-}` | Full |
| `GOSTLY_TENANT_ID` | `${GOSTLY_TENANT_ID:-}` | Full |
| `TRAINING_VERSION_ARCHIVE_ENABLED` | `${TRAINING_VERSION_ARCHIVE_ENABLED:-true}` | Full |
| `ACTIVITIES_V2_ENABLED` | `${ACTIVITIES_V2_ENABLED:-true}` | Full |
| `GOSTLY_SHARED_EPISODE_MUTATIONS_ENABLED` | `${GOSTLY_SHARED_EPISODE_MUTATIONS_ENABLED:-true}` | Full |
| `GOSTLY_RECEIPT_TRANSITION_WORKER` | `${GOSTLY_RECEIPT_TRANSITION_WORKER:-1}` | Full |
| `GOSTLY_TELEMETRY` | `${GOSTLY_TELEMETRY:-}` | Full |
| `GOSTLY_EVAL_TIMEOUT_S` | `${GOSTLY_EVAL_TIMEOUT_S:-300}` | Full |
| `GOSTLY_EVAL_ATTEMPT_MAX_HORIZON_S` | `${GOSTLY_EVAL_ATTEMPT_MAX_HORIZON_S:-3600}` | Full |
| `GOSTLY_EVAL_LEASE_GRACE_S` | `${GOSTLY_EVAL_LEASE_GRACE_S:-30}` | Full |
| `INFERENCE_URL` | `http://ghost-inference:5000` | Full |
| `API_BASE_URL` | `http://ghost-web:8000` | Full |
| `TRAFFIC_LOG_DIR` | `/data/traffic` | Full |
| `WEBHOOK_DIR` | `/data/webhooks` | Full |
| `ENABLE_OBSERVABILITY` | `${ENABLE_OBSERVABILITY:-true}` | Full |
| `WIDE_EVENTS_DIR` | `/data/wide_events` | Full |
| `ALLOWED_ORIGINS` | `${ALLOWED_ORIGINS:-http://localhost:3000}` | Full |
| `MCP_ALLOWED_ORIGINS` | `${MCP_ALLOWED_ORIGINS:-http://localhost:3000}` | Full |
| `MCP_MAX_REQUEST_BODY_BYTES` | `${MCP_MAX_REQUEST_BODY_BYTES:-1048576}` | Full |
| `OPENAI_API_KEY` | `${OPENAI_API_KEY:-}` | Full |
| `GOSTLY_OUTBOUND_ALLOWED_PRIVATE_ORIGINS` | `${GOSTLY_OUTBOUND_ALLOWED_PRIVATE_ORIGINS:-}` | Full |
| `GOSTLY_AUTH_MODE` | `${GOSTLY_AUTH_MODE:-password}` | Full |
| `GOSTLY_ADMIN_EMAIL` | `${GOSTLY_ADMIN_EMAIL:-}` | Full |
| `GOSTLY_ADMIN_PASSWORD` | `${GOSTLY_ADMIN_PASSWORD:-}` | Full |
| `GOSTLY_ADMIN_FULL_NAME` | `${GOSTLY_ADMIN_FULL_NAME:-}` | Full |
| `GOSTLY_AUTH_SESSION_TTL_HOURS` | `${GOSTLY_AUTH_SESSION_TTL_HOURS:-12}` | Full |
| `GOSTLY_AUTH_SESSION_IDLE_MINUTES` | `${GOSTLY_AUTH_SESSION_IDLE_MINUTES:-0}` | Full |
| `GOSTLY_AUTH_SIGN_IN_PER_MINUTE` | `${GOSTLY_AUTH_SIGN_IN_PER_MINUTE:-10}` | Full |
| `GOSTLY_AUTH_SIGN_IN_PER_HOUR` | `${GOSTLY_AUTH_SIGN_IN_PER_HOUR:-30}` | Full |
| `TRUSTED_PROXIES` | `${TRUSTED_PROXIES:-127.0.0.1/32,::1/128,gateway}` | Full |
| `GOSTLY_AUTH_COOKIE_SECURE` | `${GOSTLY_AUTH_COOKIE_SECURE:-true}` | Full |
| `GOSTLY_AUTH_COOKIE_DOMAIN` | `${GOSTLY_AUTH_COOKIE_DOMAIN:-}` | Full |
| `GOSTLY_AUTH_ALLOWED_DOMAINS` | `${GOSTLY_AUTH_ALLOWED_DOMAINS:-}` | Full |
| `GOSTLY_AUTH_AUTO_PROVISION` | `${GOSTLY_AUTH_AUTO_PROVISION:-true}` | Full |
| `GOSTLY_AUTH_DEFAULT_ROLE` | `${GOSTLY_AUTH_DEFAULT_ROLE:-viewer}` | Full |
| `GOSTLY_AUTH_GROUP_TO_ROLE_MAP` | `${GOSTLY_AUTH_GROUP_TO_ROLE_MAP:-}` | Full |
| `GOSTLY_SAML_IDP_METADATA_URL` | `${GOSTLY_SAML_IDP_METADATA_URL:-}` | Full |
| `GOSTLY_SAML_IDP_METADATA_XML` | `${GOSTLY_SAML_IDP_METADATA_XML:-}` | Full |
| `GOSTLY_SAML_IDP_ENTITY_ID` | `${GOSTLY_SAML_IDP_ENTITY_ID:-}` | Full |
| `GOSTLY_SAML_SP_ENTITY_ID` | `${GOSTLY_SAML_SP_ENTITY_ID:-}` | Full |
| `GOSTLY_SAML_SP_ACS_URL` | `${GOSTLY_SAML_SP_ACS_URL:-}` | Full |
| `GOSTLY_SAML_SP_SLO_URL` | `${GOSTLY_SAML_SP_SLO_URL:-}` | Full |
| `GOSTLY_SAML_GROUP_ATTRIBUTE` | `${GOSTLY_SAML_GROUP_ATTRIBUTE:-memberOf}` | Full |
| `GOSTLY_SAML_EMAIL_ATTRIBUTE` | `${GOSTLY_SAML_EMAIL_ATTRIBUTE:-email}` | Full |
| `GOSTLY_SAML_NAME_ATTRIBUTE` | `${GOSTLY_SAML_NAME_ATTRIBUTE:-displayName}` | Full |
| `GOSTLY_SAML_SP_X509_CERT` | `${GOSTLY_SAML_SP_X509_CERT:-}` | Full |
| `GOSTLY_SAML_SP_X509_CERT_FILE` | `${GOSTLY_SAML_SP_X509_CERT_FILE:-}` | Full |
| `GOSTLY_SAML_SP_PRIVATE_KEY` | `${GOSTLY_SAML_SP_PRIVATE_KEY:-}` | Full |
| `GOSTLY_SAML_SP_PRIVATE_KEY_FILE` | `${GOSTLY_SAML_SP_PRIVATE_KEY_FILE:-}` | Full |
| `GOSTLY_OIDC_ISSUER` | `${GOSTLY_OIDC_ISSUER:-}` | Full |
| `GOSTLY_OIDC_CLIENT_ID` | `${GOSTLY_OIDC_CLIENT_ID:-}` | Full |
| `GOSTLY_OIDC_CLIENT_SECRET` | `${GOSTLY_OIDC_CLIENT_SECRET:-}` | Full |
| `GOSTLY_OIDC_CLIENT_SECRET_FILE` | `${GOSTLY_OIDC_CLIENT_SECRET_FILE:-}` | Full |
| `GOSTLY_OIDC_CLIENT_KEY_FILE` | `${GOSTLY_OIDC_CLIENT_KEY_FILE:-}` | Full |
| `GOSTLY_OIDC_REDIRECT_URI` | `${GOSTLY_OIDC_REDIRECT_URI:-}` | Full |
| `GOSTLY_OIDC_SCOPES` | `${GOSTLY_OIDC_SCOPES:-openid email profile groups}` | Full |
| `GOSTLY_OIDC_EMAIL_CLAIM` | `${GOSTLY_OIDC_EMAIL_CLAIM:-email}` | Full |
| `GOSTLY_OIDC_NAME_CLAIM` | `${GOSTLY_OIDC_NAME_CLAIM:-name}` | Full |
| `GOSTLY_OIDC_GROUP_CLAIM` | `${GOSTLY_OIDC_GROUP_CLAIM:-groups}` | Full |
| `GOSTLY_OIDC_DISPLAY_NAME` | `${GOSTLY_OIDC_DISPLAY_NAME:-}` | Full |
| `GOSTLY_SECRET_STORE_KEY_FILE` | `/var/lib/gostly/secret-store/secret-store.key` | Full |
| `DB_MAX_OVERFLOW` | `${DB_MAX_OVERFLOW:-10}` | Full |
| `DB_POOL_SIZE` | `${DB_POOL_SIZE:-5}` | Full |
| `DRIFT_MATVIEW_REFRESH_ENABLED` | `${DRIFT_MATVIEW_REFRESH_ENABLED:-1}` | Full |
| `DRIFT_MATVIEW_REFRESH_INTERVAL_SECS` | `${DRIFT_MATVIEW_REFRESH_INTERVAL_SECS:-300}` | Full |
| `DRIFT_MATVIEW_REFRESH_JITTER_SECS` | `${DRIFT_MATVIEW_REFRESH_JITTER_SECS:-30}` | Full |
| `DRIFT_MATVIEW_REFRESH_STATEMENT_TIMEOUT_SECS` | `${DRIFT_MATVIEW_REFRESH_STATEMENT_TIMEOUT_SECS:-120}` | Full |
| `ENABLE_AI_MOCK_REPAIR` | `${ENABLE_AI_MOCK_REPAIR:-false}` | Full |
| `ENABLE_UPSTREAM_ALIGNMENT_SYNC` | `${ENABLE_UPSTREAM_ALIGNMENT_SYNC:-false}` | Full |
| `GOSTLY_AGENT_SESSION_MAX_AGE_DAYS` | `${GOSTLY_AGENT_SESSION_MAX_AGE_DAYS:-365}` | Full |
| `GOSTLY_CAPTURE_MAX_AGE_DAYS` | `${GOSTLY_CAPTURE_MAX_AGE_DAYS:-}` | Full |
| `GOSTLY_DRIFT_CHECK_MAX_EVENTS_PER_CHECK` | `${GOSTLY_DRIFT_CHECK_MAX_EVENTS_PER_CHECK:-500}` | Full |
| `GOSTLY_DRIFT_CHECK_MAX_PROJECTED_BYTES_PER_CHECK` | `${GOSTLY_DRIFT_CHECK_MAX_PROJECTED_BYTES_PER_CHECK:-12582912}` | Full |
| `GOSTLY_DRIFT_CHECK_MAX_PROJECTED_BYTES_PER_SESSION` | `${GOSTLY_DRIFT_CHECK_MAX_PROJECTED_BYTES_PER_SESSION:-8388608}` | Full |
| `GOSTLY_DRIFT_CHECK_MAX_RECURSIVE_NODES_PER_CHECK` | `${GOSTLY_DRIFT_CHECK_MAX_RECURSIVE_NODES_PER_CHECK:-24000}` | Full |
| `GOSTLY_DRIFT_CHECK_MAX_RECURSIVE_NODES_PER_SESSION` | `${GOSTLY_DRIFT_CHECK_MAX_RECURSIVE_NODES_PER_SESSION:-16000}` | Full |
| `GOSTLY_DRIFT_CHECK_MAX_ROUTES_PER_CHECK` | `${GOSTLY_DRIFT_CHECK_MAX_ROUTES_PER_CHECK:-1500}` | Full |
| `GOSTLY_DRIFT_CHECK_MAX_ROUTES_PER_SESSION` | `${GOSTLY_DRIFT_CHECK_MAX_ROUTES_PER_SESSION:-1000}` | Full |
| `GOSTLY_DRIFT_CHECK_MAX_ROWS_PER_CHECK` | `${GOSTLY_DRIFT_CHECK_MAX_ROWS_PER_CHECK:-8000}` | Full |
| `GOSTLY_DRIFT_CHECK_MAX_ROWS_PER_SESSION` | `${GOSTLY_DRIFT_CHECK_MAX_ROWS_PER_SESSION:-5000}` | Full |
| `GOSTLY_MODEL_ALLOWED_PRIVATE_ORIGINS` | `${GOSTLY_MODEL_ALLOWED_PRIVATE_ORIGINS:-}` | Full |
| `GOSTLY_NOTIFY_CONFIG` | `${GOSTLY_NOTIFY_CONFIG:-}` | Full |
| `GOSTLY_NOTIFY_SECRET` | `${GOSTLY_NOTIFY_SECRET:-}` | Full |
| `GOSTLY_NOTIFY_SECRET_FILE` | `${GOSTLY_NOTIFY_SECRET_FILE:-}` | Full |
| `GOSTLY_NOTIFY_URL` | `${GOSTLY_NOTIFY_URL:-}` | Full |
| `GOSTLY_NOTIFY_URL_FILE` | `${GOSTLY_NOTIFY_URL_FILE:-}` | Full |
| `GOSTLY_OUTBOUND_ALLOWED_ORIGINS` | `${GOSTLY_OUTBOUND_ALLOWED_ORIGINS:-}` | Full |
| `GOSTLY_PROXY_PUBLIC_URL` | `${GOSTLY_PROXY_PUBLIC_URL:-}` | Full |
| `GOSTLY_PUBLIC_URL` | `${GOSTLY_PUBLIC_URL:-}` | Full |
| `GOSTLY_STUDIO_RESULT_TTL_DAYS` | `${GOSTLY_STUDIO_RESULT_TTL_DAYS:-7}` | Full |
| `GOSTLY_TELEMETRY_TIER` | `${GOSTLY_TELEMETRY_TIER:-}` | Full |
| `GOSTLY_TRANSITION_CALIBRATION_MAX_LEGACY_CALLS` | `${GOSTLY_TRANSITION_CALIBRATION_MAX_LEGACY_CALLS:-100}` | Full |
| `GOSTLY_TRANSITION_MAX_CONCURRENT` | `${GOSTLY_TRANSITION_MAX_CONCURRENT:-4}` | Full |
| `GOSTLY_TRANSITION_MAX_CONCURRENT_PER_TENANT` | `${GOSTLY_TRANSITION_MAX_CONCURRENT_PER_TENANT:-2}` | Full |
| `GOSTLY_TRANSITION_MAX_SAMPLED_ENDPOINTS` | `${GOSTLY_TRANSITION_MAX_SAMPLED_ENDPOINTS:-1000}` | Full |
| `GOSTLY_WORKER_HEARTBEAT_SECS` | `${GOSTLY_WORKER_HEARTBEAT_SECS:-30}` | Full |
| `GOSTLY_WORKER_LEASE_SECS` | `${GOSTLY_WORKER_LEASE_SECS:-120}` | Full |
| `GOSTLY_WORKER_MAX_CONCURRENT` | `${GOSTLY_WORKER_MAX_CONCURRENT:-1}` | Full |
| `GOSTLY_WORKER_MAX_CONCURRENT_PER_TENANT` | `${GOSTLY_WORKER_MAX_CONCURRENT_PER_TENANT:-1}` | Full |
| `GOSTLY_WORKER_POLL_INTERVAL_SECS` | `${GOSTLY_WORKER_POLL_INTERVAL_SECS:-2.0}` | Full |
| `GOSTLY_WORKER_RECONCILIATION_BACKOFF_SECS` | `${GOSTLY_WORKER_RECONCILIATION_BACKOFF_SECS:-30}` | Full |
| `HTTPS_PROXY` | `${HTTPS_PROXY:-}` | Full |
| `HTTP_PROXY` | `${HTTP_PROXY:-}` | Full |
| `LICENSE_STALE_TTL` | `${LICENSE_STALE_TTL:-14400}` | Full |
| `LLM_AZURE_API_KEY` | `${LLM_AZURE_API_KEY:-}` | Full |
| `MAX_BODY_BYTES` | `${MAX_BODY_BYTES:-1048576}` | Full |
| `NO_PROXY` | `${NO_PROXY:-}` | Full |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | from .env when set | Full |
| `OTEL_EXPORTER_OTLP_HEADERS` | from .env when set | Full |
| `SERVICE_KEY_ROTATE_GRACE_SECS` | `${SERVICE_KEY_ROTATE_GRACE_SECS:-300}` | Full |
| `SSL_CERT_FILE` | from .env when set | Full |

#### ghost-web

| Variable | Value | Stack |
|---|---|---|
| `GOSTLY_AUDIT_RETENTION_DAYS` | `${GOSTLY_AUDIT_RETENTION_DAYS:-365}` | both |
| `GOSTLY_MIGRATION_MODE` | `skip` | both |
| `ENVIRONMENT` | `${ENVIRONMENT:-production}` | both |
| `LOG_FORMAT` | `${LOG_FORMAT:-json}` | both |
| `GHOST_API_KEY` | `${GHOST_API_KEY:-}` | both |
| `GOSTLY_LICENSE_KEY` | `${GOSTLY_LICENSE_KEY:-}` | both |
| `GOSTLY_TENANT_ID` | `${GOSTLY_TENANT_ID:-}` | both |
| `TRAINING_VERSION_ARCHIVE_ENABLED` | `${TRAINING_VERSION_ARCHIVE_ENABLED:-true}` | both |
| `ACTIVITIES_V2_ENABLED` | `${ACTIVITIES_V2_ENABLED:-true}` | both |
| `GOSTLY_SHARED_EPISODE_MUTATIONS_ENABLED` | `${GOSTLY_SHARED_EPISODE_MUTATIONS_ENABLED:-true}` | both |
| `GOSTLY_RECEIPT_TRANSITION_WORKER` | `${GOSTLY_RECEIPT_TRANSITION_WORKER:-1}` | both |
| `GOSTLY_CAPTURE_MAX_AGE_DAYS` | `${GOSTLY_CAPTURE_MAX_AGE_DAYS:-}` | both |
| `GOSTLY_TELEMETRY` | `${GOSTLY_TELEMETRY:-}` | both |
| `AGENT_URL` | `http://ghost-proxy:8080` | both |
| `API_BASE_URL` | `http://ghost-web:8000` | both |
| `MOCK_DIR` | `/data/mocks` | both |
| `TRAFFIC_LOG_DIR` | `/data/traffic` | both |
| `WEBHOOK_DIR` | `/data/webhooks` | both |
| `ALLOWED_ORIGINS` | `${ALLOWED_ORIGINS:-http://localhost:3000}` | both |
| `MCP_ALLOWED_ORIGINS` | `${MCP_ALLOWED_ORIGINS:-http://localhost:3000}` | both |
| `MCP_MAX_REQUEST_BODY_BYTES` | `${MCP_MAX_REQUEST_BODY_BYTES:-1048576}` | both |
| `DATABASE_URL` | `${DATABASE_URL:-postgresql://gostly_app:${GOSTLY_APP_DB_PASSWORD:?}@ghost-postgres:5432/${POSTGRES_DB:-ghost}}` | both |
| `SERVICE_DATABASE_URL` | `${SERVICE_DATABASE_URL:-postgresql://gostly_service:${GOSTLY_SERVICE_DB_PASSWORD:?}@ghost-postgres:5432/${POSTGRES_DB:-ghost}}` | both |
| `GOSTLY_AUTH_MODE` | `${GOSTLY_AUTH_MODE:-password}` | both |
| `GOSTLY_ADMIN_EMAIL` | `${GOSTLY_ADMIN_EMAIL:-}` | both |
| `GOSTLY_ADMIN_PASSWORD` | `${GOSTLY_ADMIN_PASSWORD:-}` | both |
| `GOSTLY_ADMIN_FULL_NAME` | `${GOSTLY_ADMIN_FULL_NAME:-}` | both |
| `GOSTLY_AUTH_SESSION_TTL_HOURS` | `${GOSTLY_AUTH_SESSION_TTL_HOURS:-12}` | both |
| `GOSTLY_AUTH_COOKIE_SECURE` | `${GOSTLY_AUTH_COOKIE_SECURE:-true}` | both |
| `GOSTLY_AUTH_COOKIE_DOMAIN` | `${GOSTLY_AUTH_COOKIE_DOMAIN:-}` | both |
| `GOSTLY_EVAL_TIMEOUT_S` | `${GOSTLY_EVAL_TIMEOUT_S:-300}` | Full |
| `GOSTLY_EVAL_ATTEMPT_MAX_HORIZON_S` | `${GOSTLY_EVAL_ATTEMPT_MAX_HORIZON_S:-3600}` | Full |
| `GOSTLY_EVAL_LEASE_GRACE_S` | `${GOSTLY_EVAL_LEASE_GRACE_S:-30}` | Full |
| `INFERENCE_URL` | `http://ghost-inference:5000` | Full |
| `ENABLE_OBSERVABILITY` | `${ENABLE_OBSERVABILITY:-true}` | Full |
| `WIDE_EVENTS_DIR` | `/data/wide_events` | Full |
| `OPENAI_API_KEY` | `${OPENAI_API_KEY:-}` | Full |
| `GOSTLY_OUTBOUND_ALLOWED_PRIVATE_ORIGINS` | `${GOSTLY_OUTBOUND_ALLOWED_PRIVATE_ORIGINS:-}` | Full |
| `GOSTLY_AUTH_SESSION_IDLE_MINUTES` | `${GOSTLY_AUTH_SESSION_IDLE_MINUTES:-0}` | Full |
| `GOSTLY_AUTH_SIGN_IN_PER_MINUTE` | `${GOSTLY_AUTH_SIGN_IN_PER_MINUTE:-10}` | Full |
| `GOSTLY_AUTH_SIGN_IN_PER_HOUR` | `${GOSTLY_AUTH_SIGN_IN_PER_HOUR:-30}` | Full |
| `TRUSTED_PROXIES` | `${TRUSTED_PROXIES:-127.0.0.1/32,::1/128,gateway}` | Full |
| `GOSTLY_AUTH_ALLOWED_DOMAINS` | `${GOSTLY_AUTH_ALLOWED_DOMAINS:-}` | Full |
| `GOSTLY_AUTH_AUTO_PROVISION` | `${GOSTLY_AUTH_AUTO_PROVISION:-true}` | Full |
| `GOSTLY_AUTH_DEFAULT_ROLE` | `${GOSTLY_AUTH_DEFAULT_ROLE:-viewer}` | Full |
| `GOSTLY_AUTH_GROUP_TO_ROLE_MAP` | `${GOSTLY_AUTH_GROUP_TO_ROLE_MAP:-}` | Full |
| `GOSTLY_SAML_IDP_METADATA_URL` | `${GOSTLY_SAML_IDP_METADATA_URL:-}` | Full |
| `GOSTLY_SAML_IDP_METADATA_XML` | `${GOSTLY_SAML_IDP_METADATA_XML:-}` | Full |
| `GOSTLY_SAML_IDP_ENTITY_ID` | `${GOSTLY_SAML_IDP_ENTITY_ID:-}` | Full |
| `GOSTLY_SAML_SP_ENTITY_ID` | `${GOSTLY_SAML_SP_ENTITY_ID:-}` | Full |
| `GOSTLY_SAML_SP_ACS_URL` | `${GOSTLY_SAML_SP_ACS_URL:-}` | Full |
| `GOSTLY_SAML_SP_SLO_URL` | `${GOSTLY_SAML_SP_SLO_URL:-}` | Full |
| `GOSTLY_SAML_GROUP_ATTRIBUTE` | `${GOSTLY_SAML_GROUP_ATTRIBUTE:-memberOf}` | Full |
| `GOSTLY_SAML_EMAIL_ATTRIBUTE` | `${GOSTLY_SAML_EMAIL_ATTRIBUTE:-email}` | Full |
| `GOSTLY_SAML_NAME_ATTRIBUTE` | `${GOSTLY_SAML_NAME_ATTRIBUTE:-displayName}` | Full |
| `GOSTLY_SAML_SP_X509_CERT` | `${GOSTLY_SAML_SP_X509_CERT:-}` | Full |
| `GOSTLY_SAML_SP_X509_CERT_FILE` | `${GOSTLY_SAML_SP_X509_CERT_FILE:-}` | Full |
| `GOSTLY_SAML_SP_PRIVATE_KEY` | `${GOSTLY_SAML_SP_PRIVATE_KEY:-}` | Full |
| `GOSTLY_SAML_SP_PRIVATE_KEY_FILE` | `${GOSTLY_SAML_SP_PRIVATE_KEY_FILE:-}` | Full |
| `GOSTLY_OIDC_ISSUER` | `${GOSTLY_OIDC_ISSUER:-}` | Full |
| `GOSTLY_OIDC_CLIENT_ID` | `${GOSTLY_OIDC_CLIENT_ID:-}` | Full |
| `GOSTLY_OIDC_CLIENT_SECRET` | `${GOSTLY_OIDC_CLIENT_SECRET:-}` | Full |
| `GOSTLY_OIDC_CLIENT_SECRET_FILE` | `${GOSTLY_OIDC_CLIENT_SECRET_FILE:-}` | Full |
| `GOSTLY_OIDC_CLIENT_KEY_FILE` | `${GOSTLY_OIDC_CLIENT_KEY_FILE:-}` | Full |
| `GOSTLY_OIDC_REDIRECT_URI` | `${GOSTLY_OIDC_REDIRECT_URI:-}` | Full |
| `GOSTLY_OIDC_SCOPES` | `${GOSTLY_OIDC_SCOPES:-openid email profile groups}` | Full |
| `GOSTLY_OIDC_EMAIL_CLAIM` | `${GOSTLY_OIDC_EMAIL_CLAIM:-email}` | Full |
| `GOSTLY_OIDC_NAME_CLAIM` | `${GOSTLY_OIDC_NAME_CLAIM:-name}` | Full |
| `GOSTLY_OIDC_GROUP_CLAIM` | `${GOSTLY_OIDC_GROUP_CLAIM:-groups}` | Full |
| `GOSTLY_OIDC_DISPLAY_NAME` | `${GOSTLY_OIDC_DISPLAY_NAME:-}` | Full |
| `GOSTLY_SECRET_STORE_KEY_FILE` | `/var/lib/gostly/secret-store/secret-store.key` | Full |
| `DB_MAX_OVERFLOW` | `${DB_MAX_OVERFLOW:-10}` | Full |
| `DB_POOL_SIZE` | `${DB_POOL_SIZE:-5}` | Full |
| `DRIFT_MATVIEW_REFRESH_ENABLED` | `${DRIFT_MATVIEW_REFRESH_ENABLED:-1}` | Full |
| `DRIFT_MATVIEW_REFRESH_INTERVAL_SECS` | `${DRIFT_MATVIEW_REFRESH_INTERVAL_SECS:-300}` | Full |
| `DRIFT_MATVIEW_REFRESH_JITTER_SECS` | `${DRIFT_MATVIEW_REFRESH_JITTER_SECS:-30}` | Full |
| `DRIFT_MATVIEW_REFRESH_STATEMENT_TIMEOUT_SECS` | `${DRIFT_MATVIEW_REFRESH_STATEMENT_TIMEOUT_SECS:-120}` | Full |
| `ENABLE_AI_MOCK_REPAIR` | `${ENABLE_AI_MOCK_REPAIR:-false}` | Full |
| `ENABLE_UPSTREAM_ALIGNMENT_SYNC` | `${ENABLE_UPSTREAM_ALIGNMENT_SYNC:-false}` | Full |
| `GOSTLY_AGENT_SESSION_MAX_AGE_DAYS` | `${GOSTLY_AGENT_SESSION_MAX_AGE_DAYS:-365}` | Full |
| `GOSTLY_DRIFT_CHECK_MAX_EVENTS_PER_CHECK` | `${GOSTLY_DRIFT_CHECK_MAX_EVENTS_PER_CHECK:-500}` | Full |
| `GOSTLY_DRIFT_CHECK_MAX_PROJECTED_BYTES_PER_CHECK` | `${GOSTLY_DRIFT_CHECK_MAX_PROJECTED_BYTES_PER_CHECK:-12582912}` | Full |
| `GOSTLY_DRIFT_CHECK_MAX_PROJECTED_BYTES_PER_SESSION` | `${GOSTLY_DRIFT_CHECK_MAX_PROJECTED_BYTES_PER_SESSION:-8388608}` | Full |
| `GOSTLY_DRIFT_CHECK_MAX_RECURSIVE_NODES_PER_CHECK` | `${GOSTLY_DRIFT_CHECK_MAX_RECURSIVE_NODES_PER_CHECK:-24000}` | Full |
| `GOSTLY_DRIFT_CHECK_MAX_RECURSIVE_NODES_PER_SESSION` | `${GOSTLY_DRIFT_CHECK_MAX_RECURSIVE_NODES_PER_SESSION:-16000}` | Full |
| `GOSTLY_DRIFT_CHECK_MAX_ROUTES_PER_CHECK` | `${GOSTLY_DRIFT_CHECK_MAX_ROUTES_PER_CHECK:-1500}` | Full |
| `GOSTLY_DRIFT_CHECK_MAX_ROUTES_PER_SESSION` | `${GOSTLY_DRIFT_CHECK_MAX_ROUTES_PER_SESSION:-1000}` | Full |
| `GOSTLY_DRIFT_CHECK_MAX_ROWS_PER_CHECK` | `${GOSTLY_DRIFT_CHECK_MAX_ROWS_PER_CHECK:-8000}` | Full |
| `GOSTLY_DRIFT_CHECK_MAX_ROWS_PER_SESSION` | `${GOSTLY_DRIFT_CHECK_MAX_ROWS_PER_SESSION:-5000}` | Full |
| `GOSTLY_MODEL_ALLOWED_PRIVATE_ORIGINS` | `${GOSTLY_MODEL_ALLOWED_PRIVATE_ORIGINS:-}` | Full |
| `GOSTLY_NOTIFY_CONFIG` | `${GOSTLY_NOTIFY_CONFIG:-}` | Full |
| `GOSTLY_NOTIFY_SECRET` | `${GOSTLY_NOTIFY_SECRET:-}` | Full |
| `GOSTLY_NOTIFY_SECRET_FILE` | `${GOSTLY_NOTIFY_SECRET_FILE:-}` | Full |
| `GOSTLY_NOTIFY_URL` | `${GOSTLY_NOTIFY_URL:-}` | Full |
| `GOSTLY_NOTIFY_URL_FILE` | `${GOSTLY_NOTIFY_URL_FILE:-}` | Full |
| `GOSTLY_OUTBOUND_ALLOWED_ORIGINS` | `${GOSTLY_OUTBOUND_ALLOWED_ORIGINS:-}` | Full |
| `GOSTLY_PROXY_PUBLIC_URL` | `${GOSTLY_PROXY_PUBLIC_URL:-}` | Full |
| `GOSTLY_PUBLIC_URL` | `${GOSTLY_PUBLIC_URL:-}` | Full |
| `GOSTLY_STUDIO_RESULT_TTL_DAYS` | `${GOSTLY_STUDIO_RESULT_TTL_DAYS:-7}` | Full |
| `GOSTLY_TELEMETRY_TIER` | `${GOSTLY_TELEMETRY_TIER:-}` | Full |
| `GOSTLY_TRANSITION_CALIBRATION_MAX_LEGACY_CALLS` | `${GOSTLY_TRANSITION_CALIBRATION_MAX_LEGACY_CALLS:-100}` | Full |
| `GOSTLY_TRANSITION_MAX_CONCURRENT` | `${GOSTLY_TRANSITION_MAX_CONCURRENT:-4}` | Full |
| `GOSTLY_TRANSITION_MAX_CONCURRENT_PER_TENANT` | `${GOSTLY_TRANSITION_MAX_CONCURRENT_PER_TENANT:-2}` | Full |
| `GOSTLY_TRANSITION_MAX_SAMPLED_ENDPOINTS` | `${GOSTLY_TRANSITION_MAX_SAMPLED_ENDPOINTS:-1000}` | Full |
| `GOSTLY_WORKER_HEARTBEAT_SECS` | `${GOSTLY_WORKER_HEARTBEAT_SECS:-30}` | Full |
| `GOSTLY_WORKER_LEASE_SECS` | `${GOSTLY_WORKER_LEASE_SECS:-120}` | Full |
| `GOSTLY_WORKER_MAX_CONCURRENT` | `${GOSTLY_WORKER_MAX_CONCURRENT:-1}` | Full |
| `GOSTLY_WORKER_MAX_CONCURRENT_PER_TENANT` | `${GOSTLY_WORKER_MAX_CONCURRENT_PER_TENANT:-1}` | Full |
| `GOSTLY_WORKER_POLL_INTERVAL_SECS` | `${GOSTLY_WORKER_POLL_INTERVAL_SECS:-2.0}` | Full |
| `GOSTLY_WORKER_RECONCILIATION_BACKOFF_SECS` | `${GOSTLY_WORKER_RECONCILIATION_BACKOFF_SECS:-30}` | Full |
| `HTTPS_PROXY` | `${HTTPS_PROXY:-}` | Full |
| `HTTP_PROXY` | `${HTTP_PROXY:-}` | Full |
| `LICENSE_STALE_TTL` | `${LICENSE_STALE_TTL:-14400}` | Full |
| `LLM_AZURE_API_KEY` | `${LLM_AZURE_API_KEY:-}` | Full |
| `MAX_BODY_BYTES` | `${MAX_BODY_BYTES:-1048576}` | Full |
| `NO_PROXY` | `${NO_PROXY:-}` | Full |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | from .env when set | Full |
| `OTEL_EXPORTER_OTLP_HEADERS` | from .env when set | Full |
| `SERVICE_KEY_ROTATE_GRACE_SECS` | `${SERVICE_KEY_ROTATE_GRACE_SECS:-300}` | Full |
| `SSL_CERT_FILE` | from .env when set | Full |
| `GOSTLY_CONNECTED_AI_AUTHORITY_DIR` | `/var/lib/gostly/connected-ai` | Full |

#### ghost-llamacpp

| Variable | Value | Stack |
|---|---|---|
| `ADAPTER_HOTSET_MAX_BYTES` | `${ADAPTER_HOTSET_MAX_BYTES:-68719476736}` | Full |
| `ADAPTER_HOTSET_MAX_COUNT` | `${ADAPTER_HOTSET_MAX_COUNT:-64}` | Full |
| `ENABLE_ADAPTER_HOTSET_MANIFEST` | `${ENABLE_ADAPTER_HOTSET_MANIFEST:-false}` | Full |
| `LLAMACPP_DRAFT_MODEL` | `${LLAMACPP_DRAFT_MODEL:-}` | Full |
| `LLAMACPP_PARALLEL` | `${LLAMACPP_PARALLEL:-}` | Full |
| `LLAMACPP_THREADS` | `${LLAMACPP_THREADS:-}` | Full |

#### ghost-inference

| Variable | Value | Stack |
|---|---|---|
| `GOSTLY_CONNECTED_AI_AUTHORITY_DIR` | `/var/lib/gostly/connected-ai` | Full |
| `MOCK_DIR` | `/data/mocks` | Full |
| `ENABLE_RAG` | `${ENABLE_RAG:-true}` | Full |
| `API_BASE_URL` | `http://ghost-web:8000` | Full |
| `LLAMACPP_ENDPOINT` | `http://ghost-llamacpp:8080` | Full |
| `GOSTLY_OUTPUT_BUDGET` | `${GOSTLY_OUTPUT_BUDGET:-2048}` | Full |
| `GOSTLY_INFERENCE_TIMEOUT_S` | `${GOSTLY_INFERENCE_TIMEOUT_S:-120}` | Full |
| `GOSTLY_EVAL_ATTEMPT_MAX_HORIZON_S` | `${GOSTLY_EVAL_ATTEMPT_MAX_HORIZON_S:-3600}` | Full |
| `GOSTLY_EVAL_ATTEMPT_REGISTRY_SIZE` | `${GOSTLY_EVAL_ATTEMPT_REGISTRY_SIZE:-4096}` | Full |
| `FINETUNE_CALLBACK_REQUEST_TIMEOUT_S` | `${FINETUNE_CALLBACK_REQUEST_TIMEOUT_S:-2}` | Full |
| `FINETUNE_CALLBACK_TOTAL_DEADLINE_S` | `${FINETUNE_CALLBACK_TOTAL_DEADLINE_S:-10}` | Full |
| `FINETUNE_CALLBACK_TRANSPORT_THREAD_LIMIT` | `${FINETUNE_CALLBACK_TRANSPORT_THREAD_LIMIT:-8}` | Full |
| `OMP_NUM_THREADS` | `${INFERENCE_NUM_THREADS:-4}` | Full |
| `MKL_NUM_THREADS` | `${INFERENCE_NUM_THREADS:-4}` | Full |
| `OPENBLAS_NUM_THREADS` | `${INFERENCE_NUM_THREADS:-4}` | Full |
| `ADAPTER_HOTSET_MAX_BYTES` | `${ADAPTER_HOTSET_MAX_BYTES:-68719476736}` | Full |
| `ADAPTER_HOTSET_MAX_COUNT` | `${ADAPTER_HOTSET_MAX_COUNT:-64}` | Full |
| `ADAPTER_HOTSET_PINS_FILE` | `${ADAPTER_HOTSET_PINS_FILE:-}` | Full |
| `EMBED_MODEL` | `${EMBED_MODEL:-all-MiniLM-L6-v2}` | Full |
| `ENABLE_ADAPTER_HOTSET_MANIFEST` | `${ENABLE_ADAPTER_HOTSET_MANIFEST:-false}` | Full |
| `ENABLE_CONFORMAL_CALIBRATION` | `${ENABLE_CONFORMAL_CALIBRATION:-false}` | Full |
| `INTERNAL_API_TOKEN` | `${INTERNAL_API_TOKEN:-}` | Full |

#### ghost-proxy

| Variable | Value | Stack |
|---|---|---|
| `GOSTLY_LICENSE_KEY` | `${GOSTLY_LICENSE_KEY:-}` | both |
| `BACKEND_URL` | `${BACKEND_URL:?}` | both |
| `INITIAL_MODE` | `${INITIAL_MODE:-LEARN}` | both |
| `PROXY_PORT` | `8080` | both |
| `MOCK_DIR` | `/data/mocks` | both |
| `MODE_FILE_PATH` | `/data/mode.txt` | both |
| `AI_CONFIDENCE_THRESHOLD` | `${AI_CONFIDENCE_THRESHOLD:-0.70}` | both |
| `ACCEPT_INVALID_CERTS` | `${ACCEPT_INVALID_CERTS:-false}` | both |
| `REDACT_HEADERS` | `${REDACT_HEADERS:-Authorization,Cookie,X-Api-Key}` | both |
| `API_URL` | `http://ghost-web:8000` | both |
| `TRAFFIC_LOG_DIR` | `/data/traffic` | both |
| `WEBHOOK_DIR` | `/data/webhooks` | both |
| `ENABLE_WS_CAPTURE` | `${ENABLE_WS_CAPTURE:-false}` | both |
| `GOSTLY_CASCADE_SHADOW` | `${GOSTLY_CASCADE_SHADOW:-1}` | both |
| `GOSTLY_TELEMETRY` | `${GOSTLY_TELEMETRY:-}` | both |
| `GOSTLY_EPISODES` | `${GOSTLY_EPISODES:-1}` | both |
| `CHAOS_SEED` | `${CHAOS_SEED:-}` | both |
| `TRAJECTORY_DIR` | `/data/trajectories` | both |
| `SNAPSHOT_ARTIFACT_DIR` | `/data/snapshots` | both |
| `INFERENCE_URL` | `http://ghost-inference:5000` | Full |
| `GOSTLY_PREWARM_TIMEOUT_S` | `${GOSTLY_PREWARM_TIMEOUT_S:-120}` | Full |
| `ENABLE_OBSERVABILITY` | `${ENABLE_OBSERVABILITY:-true}` | Full |
| `WIDE_EVENTS_DIR` | `/data/wide_events` | Full |
| `ENABLE_RAG` | `${ENABLE_RAG:-true}` | Full |
| `ENABLE_TLS_INTERCEPTION` | `${ENABLE_TLS_INTERCEPTION:-false}` | Full |
| `ENVIRONMENT` | `${ENVIRONMENT:-production}` | Full |
| `GOSTLY_AGENT_ID` | `${GOSTLY_AGENT_ID:-}` | Full |
| `GOSTLY_EGRESS_STRICT` | `${GOSTLY_EGRESS_STRICT:-false}` | Full |
| `GOSTLY_EPISODE_TTL_SECS` | `${GOSTLY_EPISODE_TTL_SECS:-3600}` | Full |
| `GOSTLY_LICENSE_REVALIDATE_SECS` | `${GOSTLY_LICENSE_REVALIDATE_SECS:-300}` | Full |
| `GOSTLY_MAX_EXECUTION_JOURNAL_BYTES` | `${GOSTLY_MAX_EXECUTION_JOURNAL_BYTES:-268435456}` | Full |
| `GOSTLY_MAX_LIVE_EPISODES` | `${GOSTLY_MAX_LIVE_EPISODES:-64}` | Full |
| `GOSTLY_MAX_SNAPSHOTS` | `${GOSTLY_MAX_SNAPSHOTS:-64}` | Full |
| `GOSTLY_OUTBOUND_ALLOWED_ORIGINS` | `${GOSTLY_OUTBOUND_ALLOWED_ORIGINS:-}` | Full |
| `GOSTLY_SNAPSHOT_TTL_SECS` | `${GOSTLY_SNAPSHOT_TTL_SECS:-86400}` | Full |
| `GOSTLY_TELEMETRY_TIER` | `${GOSTLY_TELEMETRY_TIER:-}` | Full |
| `LOG_FORMAT` | `${LOG_FORMAT:-json}` | Full |
| `LOG_LEVEL` | `${LOG_LEVEL:-info}` | Full |
| `MAX_BODY_BYTES` | `${MAX_BODY_BYTES:-1048576}` | Full |
| `MOCK_PERSIST_VERBATIM` | `${MOCK_PERSIST_VERBATIM:-false}` | Full |
| `MOCK_SESSION_MAX_BYTES` | `${MOCK_SESSION_MAX_BYTES:-268435456}` | Full |
| `MOCK_SESSION_MAX_ENTRIES` | `${MOCK_SESSION_MAX_ENTRIES:-10000}` | Full |
| `MOCK_SESSION_MAX_ENTRIES_TOTAL` | `${MOCK_SESSION_MAX_ENTRIES_TOTAL:-10000}` | Full |
| `SMART_SWAP_ENABLED` | `${SMART_SWAP_ENABLED:-false}` | Full |
| `TLS_CACHE_SIZE` | `${TLS_CACHE_SIZE:-8192}` | Full |
| `TLS_CACHE_TTL_DAYS` | `${TLS_CACHE_TTL_DAYS:-7}` | Full |
| `TLS_PRELOAD_HOSTS` | `${TLS_PRELOAD_HOSTS:-}` | Full |
| `WEBHOOK_CAPTURE_TOKEN` | `${WEBHOOK_CAPTURE_TOKEN:-}` | Full |
| `WEBHOOK_PERSIST_VERBATIM` | `${WEBHOOK_PERSIST_VERBATIM:-false}` | Full |

#### gostly-demo-upstream

| Variable | Value | Stack |
|---|---|---|
| `PORT` | `8080` | both |
| `PREFIX` | `/gostly-demo` | both |
