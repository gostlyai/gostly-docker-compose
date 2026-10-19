# Gostly self-hosted with Docker Compose

This repository runs Gostly on your own machine with Docker Compose. Gostly sits between your
services and the APIs they call: it records real traffic, then replays it as mocks you can
control. The Lite stack runs the proxy, the control plane with its dashboard, and PostgreSQL.
The Full stack adds the AI services that generate mocks. The images are private, so you need a
Gostly account at https://gostly.ai for a licence key and a registry sign-in. The local secrets
are generated on your machine and never leave it.

This tree is not a tagged release. The image digests are listed under [Releases](#releases).

## Project structure

```text
gostly-docker-compose/
├── .gitignore                # keeps .env and local overrides out of git
├── .template.env             # the settings template; copy it to .env
├── docker-compose.full.yaml  # Full stack: Lite plus the AI services
├── docker-compose.yaml       # Lite stack (the default)
├── LICENSE                   # licence placeholder
├── new-secrets.sh            # writes the local secrets into .env
└── README.md                 # this file
```

## Services

`docker-compose.yaml` (excerpt). Every Gostly image is pinned by digest, so a release always
runs the same bytes:

```yaml
services:
  ghost-postgres:
    image: postgres:16-alpine
  ghost-migrate:
    image: 242201285974.dkr.ecr.us-east-1.amazonaws.com/gostlyai/web@sha256:426bf865655543689d472d14e574d1c6f7d9a97711adbd8dd11742596e10e170
  ghost-web:
    image: 242201285974.dkr.ecr.us-east-1.amazonaws.com/gostlyai/web@sha256:426bf865655543689d472d14e574d1c6f7d9a97711adbd8dd11742596e10e170
  ghost-proxy:
    image: 242201285974.dkr.ecr.us-east-1.amazonaws.com/gostlyai/proxy@sha256:d614b119ac4380aaaa0142c63071bfc3e0ebc63340cb1dbba45dcf3e777e1aec
  gostly-demo-upstream:   # optional: runs only while .env sets COMPOSE_PROFILES=demo
    image: mccutchen/go-httpbin:v2.15.0@sha256:24528cf5229d0b70065ac27e6c9e4d96f5452a84a3ce4433e56573c18d96827a
```

`docker-compose.full.yaml` runs the same services plus:

```yaml
services:
  ghost-llamacpp:   # Full only: the model sidecar, with no route to the internet
    image: 242201285974.dkr.ecr.us-east-1.amazonaws.com/gostlyai/llamacpp@sha256:2869da914368a5297e1a735daea424d6877da76bd6fc791f5acbe3498dee1e9b
  ghost-inference:   # Full only: the inference router
    image: 242201285974.dkr.ecr.us-east-1.amazonaws.com/gostlyai/inference@sha256:be3f4d770d6ec8b9044a98c3e68cd9af7a11dd9e4c14c9040b993a7c87e6c533
```

## Installation steps

You need Docker with Compose v2 (`docker compose`), git, and a Gostly account. The Full stack
needs Docker Engine 26 or later and enough memory for the limits of its AI containers (see
[Resources](#resources)).

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

4. Generate the local secrets: the three database passwords and the API key. Running it again
   changes nothing.

   ```bash
   ./new-secrets.sh
   ```

5. Edit `.env` and set the values listed under
   [Required environment variable updates](#required-environment-variable-updates).

   ```bash
   "${EDITOR:-nano}" .env
   ```

6. Sign in to the Gostly registry. In the dashboard at https://gostly.ai/dashboard, choose
   **Get registry token** and run the command it shows. The token is valid for 12 hours and is
   read from standard input, never passed as an argument. The command has this form:

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

Then send a first request through the bundled demo upstream:
`curl http://localhost:8080/gostly-demo/get`.

## Required environment variable updates

Set these in `.env` before the first `docker compose up -d`. Everything else has a working
default.

| Variable | What to set | Where the value comes from |
|---|---|---|
| `GOSTLY_ADMIN_EMAIL` | Your sign-in email address | You choose it |
| `GOSTLY_ADMIN_PASSWORD` | 12 to 72 characters, in single quotes if it has `$`, `#` or spaces | You choose it |
| `GOSTLY_ADMIN_FULL_NAME` | Optional display name | You choose it |
| `GOSTLY_AUTH_MODE` | Keep `password` | Already set in the template |
| `GOSTLY_LICENSE_KEY` | Your full licence key | Your gostly.ai dashboard, shown once when the key is created or rotated |
| `GOSTLY_TENANT_ID` | Your Workspace ID | Your gostly.ai dashboard: the Workspace ID in the Install block, and Settings, Organization |

`./new-secrets.sh` writes `POSTGRES_PASSWORD`, `GOSTLY_APP_DB_PASSWORD`, `GOSTLY_SERVICE_DB_PASSWORD`, `GHOST_API_KEY`. Do not edit or regenerate them on an existing
install: the database volume keeps the passwords it started with.

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
the only way to create the first account, so set `GOSTLY_ADMIN_EMAIL` and
`GOSTLY_ADMIN_PASSWORD` in `.env` before the first `docker compose up -d`. ghost-web creates the
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

### Licence and tenant

These connect the install to your Gostly account. Both stacks read them.

#### `GOSTLY_LICENSE_KEY`

Your full licence key. The dashboard shows it once, when you create the key; if you no longer
have it, create a new key there. Without it, licensed features stay off.

- Template value: empty
- Default when unset: empty

#### `GOSTLY_TENANT_ID`

Your organization ID, which the gostly.ai dashboard calls the Workspace ID and shows in the
Install block and under Settings, Organization. It keeps your data on one tenant when the
licence key is rotated. It is not a secret. On an existing install, keep the value you have.

- Template value: empty
- Default when unset: empty

### Demo upstream

A fresh install sends proxy traffic to a bundled demo service, so you can record and replay
before you connect your own. The two lines change together.

#### `COMPOSE_PROFILES`

`demo` starts the gostly-demo-upstream container. Delete the line when you proxy your own
service, then run `docker compose up -d --remove-orphans`.

- Template value: `demo`
- Default when unset: read by Compose itself

#### `BACKEND_URL`

The upstream the proxy forwards to. The demo answers only under `/gostly-demo/`. For your own
service, set it to that service's URL, for example `http://your-service:3000`. Compose refuses
to start without it.

- Template value: `http://gostly-demo-upstream:8080`
- Default when unset: required

### Ports

The published ports are fixed in the Compose files rather than read from `.env`:

| Service | Host | Container | What |
|---|---|---|---|
| ghost-web | `3000` | `3000` | the dashboard |
| ghost-web | `127.0.0.1:8000` | `8000` | the API, loopback only |
| ghost-proxy | `8080` | `8080` | the proxy |

To publish on other host ports, put an override in `docker-compose.override.yaml` (git-ignored,
so `git pull` stays clean). Compose reads it automatically next to `docker-compose.yaml`; with
`COMPOSE_FILE` set, add it to that line, for example
`COMPOSE_FILE=docker-compose.full.yaml:docker-compose.override.yaml`. `!override` replaces the
list instead of adding to it (Compose 2.24.4 or later):

```yaml
services:
  ghost-web:
    ports: !override
      - "3001:3000"
      - "127.0.0.1:8000:8000"
```

If the dashboard moves to another URL, also set `ALLOWED_ORIGINS` and `MCP_ALLOWED_ORIGINS` in
`.env` to that exact origin, for example `http://localhost:3001`.

### Resources

CPU and memory limits apply to the AI containers of `docker-compose.full.yaml`. The Lite stack
sets no limits.

| Service | Limit | Value |
|---|---|---|
| ghost-llamacpp | cpus | `${LLAMACPP_CPU_LIMIT:-4}` |
| ghost-llamacpp | memory | `${LLAMACPP_MEM_LIMIT:-6G}` |
| ghost-inference | cpus | `${INFERENCE_CPU_LIMIT:-4}` |
| ghost-inference | memory | `12G` |

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

`./new-secrets.sh` fills each of these once, only when its line is present and empty, and never
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
| `ACTIVITIES_V2_ENABLED` | `false` | `false` |
| `GOSTLY_EPISODES` | `1` | `1` |
| `GOSTLY_SHARED_EPISODE_MUTATIONS_ENABLED` | `false` | `false` |
| `AI_CONFIDENCE_THRESHOLD` | `0.70` | `0.70` |
| `POSTGRES_USER` | `ghost` | `ghost` |
| `POSTGRES_DB` | `ghost` | `ghost` |

### Settings these Compose files do not pass on

`.template.env` carries these lines, but neither Compose file passes them to a container, so changing them has no effect here: `ENABLE_GENERATION`, `LLAMACPP_ENDPOINT`.

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

**Lite or Full.** `docker compose` reads `docker-compose.yaml` (Lite) by default. To run the Full
stack, uncomment `COMPOSE_FILE=docker-compose.full.yaml` in `.env`; every command above then
uses it. Check with `docker compose config --services`, then run `docker compose up -d`. To go
back to Lite, comment the line out again and run `docker compose up -d --remove-orphans`, which
removes the AI containers.

**Upgrade.** Your `.env` stays as it is:

```bash
git pull                     # or: git fetch --tags && git checkout <release tag>
printf '%s' '<registry-token>' | docker login --username AWS --password-stdin 242201285974.dkr.ecr.us-east-1.amazonaws.com
docker compose pull
docker compose up -d
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
4. Licence validation:

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

## Upgrading

An upgrade changes the Compose files, never your `.env`: keep it, and keep your volumes.

```bash
git pull
printf '%s' '<registry-token>' | docker login --username AWS --password-stdin 242201285974.dkr.ecr.us-east-1.amazonaws.com
docker compose pull
docker compose up -d
```

What changes between releases is the set of image digests in the Compose files, plus any new
settings. `git diff <old tag> <new tag>` shows both. When `.template.env` gains a line, copy that
line into your `.env` if you want to change its default; a missing line uses the default, and
`docker compose config --quiet` names any new required value before you start.

### Releases

Each release is a git tag of this repository named `YYYY.MM.N`. Its Compose files pin the four
Gostly images by digest, the set that release promoted. The Gostly release tooling regenerates
this whole tree from Gostly's install templates when it publishes new images. To stay on one
release, clone or check out its tag.

Release: not tagged

| Image | Digest |
|---|---|
| `proxy` | `sha256:d614b119ac4380aaaa0142c63071bfc3e0ebc63340cb1dbba45dcf3e777e1aec` |
| `web` | `sha256:426bf865655543689d472d14e574d1c6f7d9a97711adbd8dd11742596e10e170` |
| `inference` | `sha256:be3f4d770d6ec8b9044a98c3e68cd9af7a11dd9e4c14c9040b993a7c87e6c533` |
| `llamacpp` | `sha256:2869da914368a5297e1a735daea424d6877da76bd6fc791f5acbe3498dee1e9b` |

## All environment variables

### Read from .env

Every variable the Compose files read from `.env` (or your shell), with the default Compose
uses when it is unset. `required` means Compose refuses to start without it.

| Variable | Default when unset | Lite | Full |
|---|---|---|---|
| `ACCEPT_INVALID_CERTS` | `false` | yes | yes |
| `ACTIVITIES_V2_ENABLED` | `false` | yes | yes |
| `AI_CONFIDENCE_THRESHOLD` | `0.70` | yes | yes |
| `ALLOWED_ORIGINS` | `http://localhost:3000` | yes | yes |
| `BACKEND_URL` | required | yes | yes |
| `CHAOS_SEED` | empty | yes | yes |
| `COMPOSE_FILE` | read by Compose itself | yes | yes |
| `COMPOSE_PROFILES` | read by Compose itself | yes | yes |
| `COMPOSE_PROJECT_NAME` | read by Compose itself | yes | yes |
| `DATABASE_URL` | `postgresql://gostly_app:${GOSTLY_APP_DB_PASSWORD:?}@ghost-postgres:5432/${POSTGRES_DB:-ghost}` | yes | yes |
| `ENABLE_RAG` | `true` | no | yes |
| `ENVIRONMENT` | `production` | yes | yes |
| `FINETUNE_CALLBACK_REQUEST_TIMEOUT_S` | `2` | no | yes |
| `FINETUNE_CALLBACK_TOTAL_DEADLINE_S` | `10` | no | yes |
| `FINETUNE_CALLBACK_TRANSPORT_THREAD_LIMIT` | `8` | no | yes |
| `GHOST_API_KEY` | empty | yes | yes |
| `GOSTLY_ADMIN_EMAIL` | empty | yes | yes |
| `GOSTLY_ADMIN_FULL_NAME` | empty | yes | yes |
| `GOSTLY_ADMIN_PASSWORD` | empty | yes | yes |
| `GOSTLY_APP_DB_PASSWORD` | required | yes | yes |
| `GOSTLY_AUTH_ALLOWED_DOMAINS` | empty | no | yes |
| `GOSTLY_AUTH_AUTO_PROVISION` | `true` | no | yes |
| `GOSTLY_AUTH_COOKIE_DOMAIN` | empty | yes | yes |
| `GOSTLY_AUTH_COOKIE_SECURE` | `true` | yes | yes |
| `GOSTLY_AUTH_DEFAULT_ROLE` | `viewer` | no | yes |
| `GOSTLY_AUTH_GROUP_TO_ROLE_MAP` | empty | no | yes |
| `GOSTLY_AUTH_MODE` | `password` | yes | yes |
| `GOSTLY_AUTH_SESSION_TTL_HOURS` | `12` | yes | yes |
| `GOSTLY_EPISODES` | `1` | yes | yes |
| `GOSTLY_EVAL_ATTEMPT_MAX_HORIZON_S` | `3600` | no | yes |
| `GOSTLY_EVAL_ATTEMPT_REGISTRY_SIZE` | `4096` | no | yes |
| `GOSTLY_EVAL_LEASE_GRACE_S` | `30` | no | yes |
| `GOSTLY_EVAL_TIMEOUT_S` | `300` | no | yes |
| `GOSTLY_INFERENCE_TIMEOUT_S` | `120` | no | yes |
| `GOSTLY_LICENSE_KEY` | empty | yes | yes |
| `GOSTLY_OIDC_CLIENT_ID` | empty | no | yes |
| `GOSTLY_OIDC_CLIENT_SECRET` | empty | no | yes |
| `GOSTLY_OIDC_DISPLAY_NAME` | empty | no | yes |
| `GOSTLY_OIDC_GROUP_CLAIM` | `groups` | no | yes |
| `GOSTLY_OIDC_ISSUER` | empty | no | yes |
| `GOSTLY_OIDC_REDIRECT_URI` | empty | no | yes |
| `GOSTLY_OIDC_SCOPES` | `openid email profile groups` | no | yes |
| `GOSTLY_OUTPUT_BUDGET` | `2048` | no | yes |
| `GOSTLY_PREWARM_TIMEOUT_S` | `120` | no | yes |
| `GOSTLY_SAML_EMAIL_ATTRIBUTE` | `email` | no | yes |
| `GOSTLY_SAML_GROUP_ATTRIBUTE` | `memberOf` | no | yes |
| `GOSTLY_SAML_IDP_METADATA_URL` | empty | no | yes |
| `GOSTLY_SAML_IDP_METADATA_XML` | empty | no | yes |
| `GOSTLY_SAML_NAME_ATTRIBUTE` | `displayName` | no | yes |
| `GOSTLY_SAML_SP_ACS_URL` | empty | no | yes |
| `GOSTLY_SAML_SP_ENTITY_ID` | empty | no | yes |
| `GOSTLY_SERVICE_DB_PASSWORD` | required | yes | yes |
| `GOSTLY_SHARED_EPISODE_MUTATIONS_ENABLED` | `false` | yes | yes |
| `GOSTLY_TELEMETRY` | empty | yes | yes |
| `GOSTLY_TENANT_ID` | empty | yes | yes |
| `INFERENCE_CPU_LIMIT` | `4` | no | yes |
| `INFERENCE_NUM_THREADS` | `4` | no | yes |
| `INITIAL_MODE` | `LEARN` | yes | yes |
| `LLAMACPP_CPU_LIMIT` | `4` | no | yes |
| `LLAMACPP_MEM_LIMIT` | `6G` | no | yes |
| `LOG_FORMAT` | `json` | yes | yes |
| `MCP_ALLOWED_ORIGINS` | `http://localhost:3000` | yes | yes |
| `MCP_MAX_REQUEST_BODY_BYTES` | `1048576` | yes | yes |
| `MIGRATIONS_DATABASE_URL` | `postgresql://${POSTGRES_USER:-ghost}:${POSTGRES_PASSWORD}@ghost-postgres:5432/${POSTGRES_DB:-ghost}` | yes | yes |
| `OPENAI_API_KEY` | empty | no | yes |
| `POSTGRES_DB` | `ghost` | yes | yes |
| `POSTGRES_PASSWORD` | required | yes | yes |
| `POSTGRES_USER` | `ghost` | yes | yes |
| `REDACT_HEADERS` | `Authorization,Cookie,X-Api-Key` | yes | yes |
| `SERVICE_DATABASE_URL` | `postgresql://gostly_service:${GOSTLY_SERVICE_DB_PASSWORD:?}@ghost-postgres:5432/${POSTGRES_DB:-ghost}` | yes | yes |
| `TRAINING_VERSION_ARCHIVE_ENABLED` | `false` | yes | yes |

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

#### ghost-web

| Variable | Value | Stack |
|---|---|---|
| `GOSTLY_MIGRATION_MODE` | `skip` | both |
| `ENVIRONMENT` | `${ENVIRONMENT:-production}` | both |
| `LOG_FORMAT` | `${LOG_FORMAT:-json}` | both |
| `GHOST_API_KEY` | `${GHOST_API_KEY:-}` | both |
| `GOSTLY_LICENSE_KEY` | `${GOSTLY_LICENSE_KEY:-}` | both |
| `GOSTLY_TENANT_ID` | `${GOSTLY_TENANT_ID:-}` | both |
| `TRAINING_VERSION_ARCHIVE_ENABLED` | `${TRAINING_VERSION_ARCHIVE_ENABLED:-false}` | both |
| `ACTIVITIES_V2_ENABLED` | `${ACTIVITIES_V2_ENABLED:-false}` | both |
| `GOSTLY_SHARED_EPISODE_MUTATIONS_ENABLED` | `${GOSTLY_SHARED_EPISODE_MUTATIONS_ENABLED:-false}` | both |
| `GOSTLY_TELEMETRY` | `${GOSTLY_TELEMETRY:-}` | both |
| `AGENT_URL` | `http://ghost-proxy:8080` | both |
| `API_BASE_URL` | `http://ghost-web:8000` | both |
| `MOCK_DIR` | `/data/mocks` | both |
| `TRAFFIC_LOG_DIR` | `/data/traffic` | both |
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
| `GOSTLY_CONNECTED_AI_AUTHORITY_DIR` | `/var/lib/gostly/connected-ai` | Full |
| `GOSTLY_EVAL_TIMEOUT_S` | `${GOSTLY_EVAL_TIMEOUT_S:-300}` | Full |
| `GOSTLY_EVAL_ATTEMPT_MAX_HORIZON_S` | `${GOSTLY_EVAL_ATTEMPT_MAX_HORIZON_S:-3600}` | Full |
| `GOSTLY_EVAL_LEASE_GRACE_S` | `${GOSTLY_EVAL_LEASE_GRACE_S:-30}` | Full |
| `INFERENCE_URL` | `http://ghost-inference:5000` | Full |
| `OPENAI_API_KEY` | `${OPENAI_API_KEY:-}` | Full |
| `GOSTLY_AUTH_ALLOWED_DOMAINS` | `${GOSTLY_AUTH_ALLOWED_DOMAINS:-}` | Full |
| `GOSTLY_AUTH_AUTO_PROVISION` | `${GOSTLY_AUTH_AUTO_PROVISION:-true}` | Full |
| `GOSTLY_AUTH_DEFAULT_ROLE` | `${GOSTLY_AUTH_DEFAULT_ROLE:-viewer}` | Full |
| `GOSTLY_AUTH_GROUP_TO_ROLE_MAP` | `${GOSTLY_AUTH_GROUP_TO_ROLE_MAP:-}` | Full |
| `GOSTLY_SAML_IDP_METADATA_URL` | `${GOSTLY_SAML_IDP_METADATA_URL:-}` | Full |
| `GOSTLY_SAML_IDP_METADATA_XML` | `${GOSTLY_SAML_IDP_METADATA_XML:-}` | Full |
| `GOSTLY_SAML_SP_ENTITY_ID` | `${GOSTLY_SAML_SP_ENTITY_ID:-}` | Full |
| `GOSTLY_SAML_SP_ACS_URL` | `${GOSTLY_SAML_SP_ACS_URL:-}` | Full |
| `GOSTLY_SAML_GROUP_ATTRIBUTE` | `${GOSTLY_SAML_GROUP_ATTRIBUTE:-memberOf}` | Full |
| `GOSTLY_SAML_EMAIL_ATTRIBUTE` | `${GOSTLY_SAML_EMAIL_ATTRIBUTE:-email}` | Full |
| `GOSTLY_SAML_NAME_ATTRIBUTE` | `${GOSTLY_SAML_NAME_ATTRIBUTE:-displayName}` | Full |
| `GOSTLY_OIDC_ISSUER` | `${GOSTLY_OIDC_ISSUER:-}` | Full |
| `GOSTLY_OIDC_CLIENT_ID` | `${GOSTLY_OIDC_CLIENT_ID:-}` | Full |
| `GOSTLY_OIDC_CLIENT_SECRET` | `${GOSTLY_OIDC_CLIENT_SECRET:-}` | Full |
| `GOSTLY_OIDC_REDIRECT_URI` | `${GOSTLY_OIDC_REDIRECT_URI:-}` | Full |
| `GOSTLY_OIDC_SCOPES` | `${GOSTLY_OIDC_SCOPES:-openid email profile groups}` | Full |
| `GOSTLY_OIDC_GROUP_CLAIM` | `${GOSTLY_OIDC_GROUP_CLAIM:-groups}` | Full |
| `GOSTLY_OIDC_DISPLAY_NAME` | `${GOSTLY_OIDC_DISPLAY_NAME:-}` | Full |

#### ghost-inference

| Variable | Value | Stack |
|---|---|---|
| `GOSTLY_CONNECTED_AI_AUTHORITY_DIR` | `/var/lib/gostly/connected-ai` | Full |
| `MOCK_DIR` | `/data/mocks` | Full |
| `FAISS_INDEX_PATH` | `/data/faiss.index` | Full |
| `FAISS_MAP_PATH` | `/data/faiss_id_map.json` | Full |
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
| `GOSTLY_TELEMETRY` | `${GOSTLY_TELEMETRY:-}` | both |
| `GOSTLY_EPISODES` | `${GOSTLY_EPISODES:-1}` | both |
| `CHAOS_SEED` | `${CHAOS_SEED:-}` | both |
| `TRAJECTORY_DIR` | `/data/trajectories` | both |
| `SNAPSHOT_ARTIFACT_DIR` | `/data/snapshots` | both |
| `INFERENCE_URL` | `http://ghost-inference:5000` | Full |
| `GOSTLY_PREWARM_TIMEOUT_S` | `${GOSTLY_PREWARM_TIMEOUT_S:-120}` | Full |

#### gostly-demo-upstream

| Variable | Value | Stack |
|---|---|---|
| `PORT` | `8080` | both |
| `PREFIX` | `/gostly-demo` | both |

## Evaluator stack (not the customer path)

Gostly's source tree has a separate Compose stack, `quickstarts/customer-compose/`, for
development, end-to-end tests and evaluators. It differs from these files in several defaults
and is not an install path. Install from this repository.

## Licence

The licence for this repository is to be chosen by its owner; see `LICENSE`. The Gostly images
are distributed under their own terms.
