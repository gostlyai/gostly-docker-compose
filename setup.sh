#!/bin/sh
# setup.sh: install, start or update Gostly from this directory. Run it again at any time.
#
#   ./setup.sh                    # first install, and again after every git pull
#   ./setup.sh --no-start         # only complete .env
#   ./setup.sh --help
#
# Each step is skipped when it is already done, so a second run changes nothing in .env:
#   1. .env      copied from .template.env when missing (mode 0600); on an update, a rollout
#                gate an older template wrote as false is turned on (printed)
#   2. checks    before anything is asked for: Docker reachable, Compose and Engine versions,
#                the dashboard, API and proxy ports free (skipped with --no-start), and no
#                exported shell variable that Compose would take over a value in .env
#   3. stack     Lite or Full, asked once and kept in COMPOSE_FILE; then the memory and disk
#                that stack needs
#   4. secrets   the three database passwords and GHOST_API_KEY, generated here once, never
#                replaced and never printed (a new database password would lock the stack out
#                of its existing volume; a deleted GHOST_API_KEY line stays deleted)
#   5. account   the admin email and password and your license key, asked for when empty; the
#                key and the password are typed without echo, never pass through argv, and a
#                password you choose is never printed
#   6. key       checked at gostly.ai on every run. A fresh install writes the key's Workspace
#                ID to GOSTLY_TENANT_ID; an installation that already has data keeps the tenant
#                its data is under; a tenant already set is never replaced
#   7. images    only when an image is missing: a 12-hour registry token fetched from gostly.ai
#                with the license key and handed to docker login on its standard input (the
#                registry login command from the dashboard is asked for only when that fails),
#                then docker compose pull for the missing images
#   8. start     docker compose up -d, then a wait until every enabled service is running (and
#                healthy where it has a health check) and the one-shot migration has finished
# A password generated here is printed once, when the script finishes or stops; it stays in .env.
# Exit status: 0 done, 1 refused or failed (the message says why), 2 usage.

# SU_V_<KEY> variables are read by write_env through export "SU_V_$key", which shellcheck cannot see.
# shellcheck disable=SC2034
set -eu

PLATFORM_URL=${GOSTLY_PLATFORM_URL:-https://gostly.ai}
DASHBOARD_URL="https://gostly.ai/dashboard"
WAIT_SECONDS=${GOSTLY_SETUP_WAIT_SECONDS:-240}
POLL_SECONDS=${GOSTLY_SETUP_POLL_SECONDS:-5}
# The registry route limits calls per address and per license key: one retry after this many seconds.
RETRY_SECONDS=${GOSTLY_SETUP_RETRY_SECONDS:-60}
FULL_FILE=docker-compose.full.yaml
LITE_FILE=docker-compose.yaml
SECRETS="POSTGRES_PASSWORD GOSTLY_APP_DB_PASSWORD GOSTLY_SERVICE_DB_PASSWORD GHOST_API_KEY"
# The rollout gates an update turns on when an older template wrote them as false.
GATES="ACTIVITIES_V2_ENABLED GOSTLY_SHARED_EPISODE_MUTATIONS_ENABLED TRAINING_VERSION_ARCHIVE_ENABLED GOSTLY_RECEIPT_TRANSITION_WORKER"
# Every key this script writes; each must appear at most once in .env.
WRITTEN="$SECRETS GOSTLY_ADMIN_EMAIL GOSTLY_ADMIN_PASSWORD GOSTLY_LICENSE_KEY GOSTLY_TENANT_ID COMPOSE_FILE"
# Values Docker Compose takes from the shell before .env: an exported one that differs from .env
# would start a stack with values other than the ones this script checks and prints (the ports
# included: an exported port would be published instead of the one probed).
SHELL_CHECKED="GOSTLY_LICENSE_KEY GOSTLY_ADMIN_EMAIL GOSTLY_ADMIN_PASSWORD GOSTLY_TENANT_ID COMPOSE_FILE GOSTLY_WEB_PORT GOSTLY_PROXY_PORT"
# Docker Compose: pull --policy missing needs 2.22. The Full file mounts a volume subpath, which
# Compose passes to the engine from 2.26 and the engine supports from Docker Engine 26.
COMPOSE_MIN=2.22
FULL_COMPOSE_MIN=2.26
FULL_ENGINE_MIN=26
# Docker memory (bytes) below which the Full stack gets a warning: its AI containers are limited
# to 12 GiB and 6 GiB by default (docker-compose.full.yaml), plus the Lite services.
FULL_MEMORY=20000000000
# Images on disk, in GB, as Docker reported them for the images pinned on 2026-10-20 (linux/arm64;
# README.md, Lite or Full). Below this much free space a download gets a warning.
LITE_DISK_GB=2
FULL_DISK_GB=22
# Services that run once and exit 0 when done; every other enabled service must keep running.
ONE_SHOT="ghost-migrate"
# The volume that holds the database, as named in the Compose files.
DATA_VOLUME_NAME=postgres-data
ENV_FILE=.env

usage() {
  cat <<'EOF'
Usage: ./setup.sh [--no-start] [--skip-key-check] [--non-interactive]

Checks Docker, completes .env, checks your license key at gostly.ai, signs in to the Gostly
registry when an image is missing, and starts the stack. Run it again after git pull to update.

  --no-start          stop once .env is complete; check, pull and start nothing
  --skip-key-check    do not check the key at gostly.ai (GOSTLY_TENANT_ID is then not filled,
                      and an empty key is accepted: the stack runs unlicensed). Use it to start
                      an installed stack without a connection.
  --non-interactive   never prompt; list the values .env still needs and exit 1 instead
  -h, --help          show this help
EOF
}

NO_START=0
SKIP_KEY_CHECK=0
INTERACTIVE=1
for arg in "$@"; do
  case "$arg" in
    --no-start) NO_START=1 ;;
    --skip-key-check) SKIP_KEY_CHECK=1 ;;
    --non-interactive) INTERACTIVE=0 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'setup.sh: unknown option %s\n\n' "$arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

say() { printf '%s\n' "$*"; }
die() {
  printf 'setup.sh: %s\n' "$*" >&2
  exit 1
}

cd "$(dirname "$0")"

# ── Terminal input ────────────────────────────────────────────────────────────
# Prompts read /dev/tty, so they work when stdin is a pipe. POSIX read has no -s: hidden input
# turns echo off with stty, and the traps put the terminal back however the script ends.
TTY_SAVED=""
restore_tty() {
  if [ -n "$TTY_SAVED" ]; then
    stty "$TTY_SAVED" </dev/tty 2>/dev/null || true
    TTY_SAVED=""
    printf '\n' >/dev/tty 2>/dev/null || true
  fi
}
TMP_FILES=""
# Set once a password generated in this run is in .env, cleared once it has been printed: a run
# that stops after writing it (a failed pull or start, a health timeout) still shows it,
# exactly once, on the way out.
PASSWORD_UNSHOWN=0
password_notice() {
  if [ "$PASSWORD_UNSHOWN" -eq 1 ]; then
    PASSWORD_UNSHOWN=0
    say "The admin password generated for $ADMIN_EMAIL is: $GENERATED_PASSWORD (it is saved in .env as GOSTLY_ADMIN_PASSWORD)"
  fi
}
cleanup() {
  restore_tty
  password_notice
  for f in $TMP_FILES; do rm -f "$f"; done
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

if [ "$INTERACTIVE" -eq 1 ] && ! { : </dev/tty; } 2>/dev/null; then
  say "No terminal to ask in; continuing as --non-interactive."
  INTERACTIVE=0
fi

# ask PROMPT: one visible line from the terminal, in ANSWER.
ask() {
  printf '%s' "$1" >/dev/tty
  ANSWER=""
  IFS= read -r ANSWER </dev/tty || true
}

# ask_hidden PROMPT [long]: one line typed without echo, in ANSWER. "long" also turns off
# canonical mode: macOS discards a canonical line over 1024 bytes (MAX_CANON) and the read never
# returns, and the pasted registry login is longer than that.
ask_hidden() {
  TTY_SAVED=$(stty -g </dev/tty)
  if [ "${2:-}" = long ]; then
    stty -echo -icanon min 1 time 0 </dev/tty
  else
    stty -echo </dev/tty
  fi
  # The prompt appears only once echo is off, so nothing pasted at it is ever shown.
  printf '%s' "$1" >/dev/tty
  ANSWER=""
  IFS= read -r ANSWER </dev/tty || true
  restore_tty
}

trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# ── .env helpers ──────────────────────────────────────────────────────────────

# value_of KEY: the value of the single active KEY= line, with a trailing CR and one pair of
# surrounding quotes removed.
value_of() {
  sed -n "s/^$1=//p" "$ENV_FILE" | tr -d '\r' | sed -e "s/^'\(.*\)'\$/\1/" -e 's/^"\(.*\)"$/\1/'
}
has_line() { grep -q "^$1=" "$ENV_FILE"; }

# write_env KEY...: set each KEY to the value in the variable SU_V_<KEY>, in one atomic rewrite.
# An active KEY= line is replaced; otherwise the first "# KEY=" line is uncommented; otherwise
# the line is appended. Values reach awk through its environment, never its argument list.
write_env() {
  tmp="$ENV_FILE.setup.$$"
  TMP_FILES="$TMP_FILES $tmp"
  (umask 077 && : >"$tmp")
  # The exports stay inside this subshell, so later commands (docker, curl) never inherit them.
  (
    for key in "$@"; do
      export "SU_V_$key"
    done
    SU_KEYS="$*" exec awk '
    BEGIN { n = split(ENVIRON["SU_KEYS"], k, " "); for (i = 1; i <= n; i++) want[k[i]] = 1 }
    { lines[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        line = lines[i]; sub(/\r$/, "", line)
        eq = index(line, "=")
        key = eq ? substr(line, 1, eq - 1) : ""
        if ((key in want) && !(key in at)) at[key] = i
      }
      for (key in want) {
        if (key in at) continue
        for (i = 1; i <= NR; i++) if (index(lines[i], "# " key "=") == 1) { at[key] = i; break }
      }
      for (i = 1; i <= NR; i++) {
        out = lines[i]
        for (key in at) if (at[key] == i) out = key "=" ENVIRON["SU_V_" key]
        print out
      }
      for (key in want) if (!(key in at)) print key "=" ENVIRON["SU_V_" key]
    }
  ' "$ENV_FILE" >"$tmp"
  )
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}

# check_shell_values: refuse when a variable in SHELL_CHECKED is set in this shell's environment
# with a value other than the one in .env. Docker Compose takes the shell's value first, so the
# stack would run with values this script never checked. The values are never printed.
check_shell_values() {
  conflicts=""
  for key in $SHELL_CHECKED; do
    is_set=""
    eval "is_set=\${$key+set}"
    [ "$is_set" = set ] || continue
    eval "shell_value=\${$key}"
    [ "$shell_value" = "$(value_of "$key")" ] || conflicts="$conflicts $key"
  done
  shell_value=""
  if [ -n "$conflicts" ]; then
    die "this shell exports$conflicts with a value other than the one in .env, and Docker Compose would use the shell's value (values not shown). Run: unset$conflicts (or open a new terminal), then run ./setup.sh again"
  fi
}

# ── 1. .env ───────────────────────────────────────────────────────────────────
if [ -L "$ENV_FILE" ]; then
  die "$ENV_FILE is a symbolic link; replace it with the real file and run again"
fi
if [ ! -f "$ENV_FILE" ]; then
  [ -f .template.env ] || die ".template.env not found; run setup.sh from the repository it came with"
  (umask 077 && cp .template.env "$ENV_FILE")
  chmod 600 "$ENV_FILE"
  say "Created .env from .template.env (readable only by you)."
fi
for key in $WRITTEN; do
  count=$(grep -c "^$key=" "$ENV_FILE" || true)
  if [ "$count" -gt 1 ]; then
    die "$ENV_FILE has $count $key= lines; keep exactly one (Compose uses the last) and run again"
  fi
done
# The rollout gates are on by default from 2026.11.0. An .env an older template wrote holds
# them as false; this step turns each one on. To keep one off, set it to 0, which every gate
# also reads as off and this step leaves alone.
for key in $GATES; do
  if [ "$(value_of "$key")" = false ]; then
    eval "SU_V_$key=true"
    write_env "$key"
    say "$key=false -> $key=true in .env (on by default from 2026.11.0; set $key=0 to keep it off)"
  fi
done

# ── 2. Checks before anything is asked for ────────────────────────────────────
check_shell_values

# version_at_least HAVE NEED: HAVE (such as v2.29.1-desktop.1) is at least NEED (major or
# major.minor). A HAVE with no readable version passes: the docker command reports its own errors.
version_at_least() {
  have=${1#v}
  have_major=${have%%.*}
  have_rest=${have#"$have_major"}
  have_rest=${have_rest#.}
  have_minor=${have_rest%%[!0-9]*}
  [ -n "$have_minor" ] || have_minor=0
  need_major=${2%%.*}
  need_minor=0
  case "$2" in *.*) need_minor=${2#*.} ;; esac
  case "$have_major" in "" | *[!0-9]*) return 0 ;; esac
  [ "$have_major" -gt "$need_major" ] && return 0
  [ "$have_major" -eq "$need_major" ] && [ "$have_minor" -ge "$need_minor" ]
}

# compose_project: the Compose project name for this directory, read without interpolating
# .env (which may not be complete yet), so nothing in .env is ever printed.
compose_project() {
  docker compose config --no-interpolate 2>/dev/null | sed -n 's/^name: //p' | head -n 1
}

# running_container SERVICE: the id of this project's running container for SERVICE, if any.
# Exits 1 when docker ps itself fails, so "Docker could not list" is never read as "not running".
running_container() {
  [ -n "$PROJECT" ] || return 0
  # Captured before trimming: in a pipeline the status would be head's, not Docker's.
  ids=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.service=$1" --filter status=running 2>/dev/null) || return 1
  printf '%s\n' "$ids" | sed -n 1p
}

# port_in_use PORT: something accepts connections on 127.0.0.1:PORT (curl exit 7 is "refused").
# --noproxy '*': curl honours http_proxy and all_proxy, and a proxy that answers would make a
# free port read as busy.
port_in_use() {
  probe=0
  curl -q -s -o /dev/null --noproxy '*' --connect-timeout 2 --max-time 3 "http://127.0.0.1:$1/" 2>/dev/null || probe=$?
  [ "$probe" -ne 7 ]
}

# effective_port NAME DEFAULT: the host port Compose publishes for ${NAME:-DEFAULT}.
effective_port() {
  port=$(value_of "$1")
  [ -n "$port" ] || port=$2
  printf '%s' "$port"
}

DOCKER_OK=0
DOCKER_OS=""
DOCKER_ROOT=""
DOCKER_MEMORY=""
ENGINE_VERSION=""
COMPOSE_VERSION=""
PROJECT=""
if [ "$NO_START" -eq 0 ]; then
  command -v docker >/dev/null 2>&1 || die "docker is not installed; install Docker with Compose v$COMPOSE_MIN or later and run ./setup.sh again"
  context=$(docker context show 2>/dev/null || true)
  info=$(docker info --format '{{.ServerVersion}}|{{.OperatingSystem}}|{{.MemTotal}}|{{.DockerRootDir}}' 2>/dev/null) ||
    die "Docker is not running, or this user cannot reach it (Docker context ${context:-default}); start Docker and run ./setup.sh again"
  ENGINE_VERSION=${info%%|*}
  info=${info#*|}
  DOCKER_OS=${info%%|*}
  info=${info#*|}
  DOCKER_MEMORY=${info%%|*}
  DOCKER_ROOT=${info#*|}
  DOCKER_OK=1
  COMPOSE_VERSION=$(docker compose version --short 2>/dev/null) ||
    die "Docker Compose v2 (the docker compose command) is missing; install Compose v$COMPOSE_MIN or later and run ./setup.sh again"
  if ! version_at_least "$COMPOSE_VERSION" "$COMPOSE_MIN"; then
    die "Docker Compose $COMPOSE_VERSION is too old: setup.sh needs Compose $COMPOSE_MIN or later. Update Docker and run ./setup.sh again"
  fi
  say "Docker: engine $ENGINE_VERSION on $DOCKER_OS (context ${context:-default}), Compose $COMPOSE_VERSION."

  PROJECT=$(compose_project)
  # The ports Compose publishes. This installation's own running containers hold theirs already.
  web_port=$(effective_port GOSTLY_WEB_PORT 3000)
  proxy_port=$(effective_port GOSTLY_PROXY_PORT 8080)
  ports=""
  if [ -z "$(running_container ghost-web)" ]; then
    ports="$web_port:GOSTLY_WEB_PORT 8000:API"
  fi
  if [ -z "$(running_container ghost-proxy)" ]; then
    ports="$ports $proxy_port:GOSTLY_PROXY_PORT"
  fi
  if ! command -v curl >/dev/null 2>&1; then
    say "Ports: not checked (curl is not installed)."
  else
    busy=""
    for entry in $ports; do
      if port_in_use "${entry%%:*}"; then
        busy="$busy, port ${entry%%:*} (${entry#*:})"
      fi
    done
    if [ -n "$busy" ]; then
      die "another program is using${busy#,}. Stop it, or choose other ports with GOSTLY_WEB_PORT and GOSTLY_PROXY_PORT in .env (port 8000 must stay free; see A port is in use in README.md), and run ./setup.sh again"
    fi
  fi
fi

# missing_images [--no-interpolate]: the images of the configured stack not on this machine.
# Before .env is complete, Compose can only render the files without interpolation, and then
# config --images fails on the ${GOSTLY_WEB_PORT:-3000}:3000 port strings, so the image lines of
# the rendered files are read instead (the images are pinned literally, never interpolated).
missing_images() {
  if [ "${1:-}" = --no-interpolate ]; then
    listed=$(docker compose config --no-interpolate | sed -n 's/^[[:space:]]*image:[[:space:]]*//p') || return 1
  else
    listed=$(docker compose config --images) || return 1
  fi
  for image in $listed; do
    docker image inspect "$image" >/dev/null 2>&1 || printf '%s\n' "$image"
  done
}

# ── 3. Lite or Full ───────────────────────────────────────────────────────────
if [ -z "$(value_of COMPOSE_FILE)" ] && [ -f "$FULL_FILE" ] && [ "$INTERACTIVE" -eq 1 ]; then
  say "Lite runs the proxy, the dashboard and PostgreSQL: record traffic and replay it as mocks."
  say "Full adds the AI services that generate mocks: a much larger download, and Docker memory for"
  say "their limits (about 20 GB). See Lite or Full in README.md."
  ask "Lite or Full? [lite]: "
  choice=$(trim "$ANSWER" | tr '[:upper:]' '[:lower:]')
  [ -n "$choice" ] || choice=lite
  case "$choice" in
    full | f) chosen_file=$FULL_FILE ;;
    lite | l) chosen_file=$LITE_FILE ;;
    *) die "answer lite or full" ;;
  esac
  # The choice is written either way, so a later run never asks again or switches silently.
  # Setting COMPOSE_FILE turns off the automatic docker-compose.override.yaml, so keep it listed.
  for override in docker-compose.override.yaml docker-compose.override.yml; do
    if [ -f "$override" ]; then
      chosen_file="$chosen_file:$override"
      break
    fi
  done
  SU_V_COMPOSE_FILE=$chosen_file
  write_env COMPOSE_FILE
  say "COMPOSE_FILE=$chosen_file written to .env."
fi

if [ "$DOCKER_OK" -eq 1 ]; then
  case ":$(value_of COMPOSE_FILE):" in
    *":$FULL_FILE:"*) stack=full ;;
    *) stack=lite ;;
  esac
  if [ "$stack" = full ]; then
    if ! version_at_least "$COMPOSE_VERSION" "$FULL_COMPOSE_MIN" || ! version_at_least "$ENGINE_VERSION" "$FULL_ENGINE_MIN"; then
      die "the Full stack needs Docker Compose $FULL_COMPOSE_MIN or later and Docker Engine $FULL_ENGINE_MIN or later (this machine has Compose $COMPOSE_VERSION, Engine $ENGINE_VERSION). Update Docker, or set COMPOSE_FILE=$LITE_FILE in .env for Lite, and run ./setup.sh again"
    fi
    case "$DOCKER_MEMORY" in
      "" | *[!0-9]*) ;;
      *)
        if [ "$DOCKER_MEMORY" -lt "$FULL_MEMORY" ]; then
          say "Warning: Docker has $((DOCKER_MEMORY / 1000000000)) GB of memory; the Full stack's AI containers may not start with less than about $((FULL_MEMORY / 1000000000)) GB. See The Full stack fails to start for memory in README.md."
        fi
        ;;
    esac
  fi
  # Disk: only a native engine's data directory can be measured from here.
  if [ -n "$(missing_images --no-interpolate 2>/dev/null || true)" ]; then
    need_gb=$LITE_DISK_GB
    [ "$stack" = lite ] || need_gb=$FULL_DISK_GB
    case "$DOCKER_OS" in
      "Docker Desktop"*) free_kb="" ;;
      *) free_kb=$(df -Pk "$DOCKER_ROOT" 2>/dev/null | awk 'NR == 2 { print $4 }') ;;
    esac
    case "$free_kb" in
      "" | *[!0-9]*)
        say "Disk: not checked (Docker keeps its images where this script cannot measure; the $stack images take about $need_gb GB)."
        ;;
      *)
        if [ "$free_kb" -lt $((need_gb * 1000000)) ]; then
          say "Warning: only $((free_kb / 1000000)) GB free under $DOCKER_ROOT; the $stack images take about $need_gb GB."
        fi
        ;;
    esac
  fi
fi

# ── 4. Local secrets ──────────────────────────────────────────────────────────
random_hex() {
  od -An -tx1 -N32 /dev/urandom | tr -d ' \n'
}
# Same shape as the platform's generated key: gsk_svc_ plus 43 URL-safe characters.
random_service_key() {
  printf 'gsk_svc_%s' "$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr '+/' '-_' | tr -d '=\n')"
}

FILL=""
for key in $SECRETS; do
  if ! has_line "$key"; then
    say "$key: no line in .env, left alone"
  elif [ -n "$(value_of "$key")" ]; then
    say "$key: already set, kept"
  else
    FILL="$FILL $key"
  fi
done
if [ -n "$FILL" ]; then
  SU_V_POSTGRES_PASSWORD=$(random_hex)
  SU_V_GOSTLY_APP_DB_PASSWORD=$(random_hex)
  SU_V_GOSTLY_SERVICE_DB_PASSWORD=$(random_hex)
  SU_V_GHOST_API_KEY=$(random_service_key)
  for value in "$SU_V_POSTGRES_PASSWORD" "$SU_V_GOSTLY_APP_DB_PASSWORD" "$SU_V_GOSTLY_SERVICE_DB_PASSWORD"; do
    case "$value" in
      *[!0-9a-f]* | "") die "could not read 32 random bytes from /dev/urandom; nothing was changed" ;;
    esac
    [ "${#value}" -eq 64 ] || die "could not read 32 random bytes from /dev/urandom; nothing was changed"
  done
  case "${SU_V_GHOST_API_KEY#gsk_svc_}" in
    *[!A-Za-z0-9_-]* | "") die "could not generate GHOST_API_KEY; nothing was changed" ;;
  esac
  [ "${#SU_V_GHOST_API_KEY}" -eq 51 ] || die "could not generate GHOST_API_KEY; nothing was changed"
  # shellcheck disable=SC2086 # FILL is a list of key names
  write_env $FILL
  for key in $FILL; do
    say "$key: generated"
  done
fi

# ── 5. Account values ─────────────────────────────────────────────────────────
# Collected first and written together once the key is accepted, so a refused key leaves no
# generated password behind that was never shown.
MISSING=""
UPDATE=""

ADMIN_EMAIL=$(value_of GOSTLY_ADMIN_EMAIL)
if [ -z "$ADMIN_EMAIL" ]; then
  if [ "$INTERACTIVE" -eq 1 ]; then
    suggested=""
    if command -v git >/dev/null 2>&1; then
      suggested=$(git config user.email 2>/dev/null || true)
    fi
    if [ -n "$suggested" ]; then
      ask "Admin email for the local dashboard [$suggested]: "
    else
      ask "Admin email for the local dashboard: "
    fi
    ADMIN_EMAIL=$(trim "$ANSWER")
    [ -n "$ADMIN_EMAIL" ] || ADMIN_EMAIL=$suggested
    case "$ADMIN_EMAIL" in
      "") die "an admin email is required; run ./setup.sh again" ;;
      *[[:space:]\'\"\$\#\\]* | *@*@* | @* | *@) die "that does not look like an email address: $ADMIN_EMAIL" ;;
      *@*) ;;
      *) die "that does not look like an email address: $ADMIN_EMAIL" ;;
    esac
    SU_V_GOSTLY_ADMIN_EMAIL=$ADMIN_EMAIL
    UPDATE="$UPDATE GOSTLY_ADMIN_EMAIL"
  else
    MISSING="$MISSING GOSTLY_ADMIN_EMAIL"
  fi
fi

GENERATED_PASSWORD=""
if [ -z "$(value_of GOSTLY_ADMIN_PASSWORD)" ]; then
  chosen=""
  if [ "$INTERACTIVE" -eq 1 ]; then
    ask_hidden "Admin password, 12 to 72 characters (leave empty to generate one): "
    chosen=$ANSWER
  fi
  if [ -n "$chosen" ]; then
    bytes=$(printf '%s' "$chosen" | wc -c | tr -d ' ')
    if [ "$bytes" -lt 12 ] || [ "$bytes" -gt 72 ]; then
      die "the password must be 12 to 72 characters; nothing was written. Run ./setup.sh again"
    fi
    case "$chosen" in
      *\'*) die "use a password without a single quote ('), or leave it empty to generate one" ;;
    esac
    ask_hidden "Type it again: "
    [ "$ANSWER" = "$chosen" ] || die "the two passwords differ; nothing was written. Run ./setup.sh again"
    case "$chosen" in
      # Single quotes make Compose read $, #, spaces and backslashes literally.
      *[!A-Za-z0-9._%+=@^*~!-]*) SU_V_GOSTLY_ADMIN_PASSWORD="'$chosen'" ;;
      *) SU_V_GOSTLY_ADMIN_PASSWORD=$chosen ;;
    esac
  else
    # 24 characters with no $, #, quote, backslash or space, so the .env line needs no quoting.
    GENERATED_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9._%+=@^*~!-' </dev/urandom | fold -w 24 | head -n 1)
    [ "${#GENERATED_PASSWORD}" -eq 24 ] || die "could not generate a password from /dev/urandom; nothing was written"
    SU_V_GOSTLY_ADMIN_PASSWORD=$GENERATED_PASSWORD
  fi
  UPDATE="$UPDATE GOSTLY_ADMIN_PASSWORD"
fi

LICENSE_KEY=$(value_of GOSTLY_LICENSE_KEY)
KEY_FROM_PROMPT=0
if [ -z "$LICENSE_KEY" ]; then
  if [ "$INTERACTIVE" -eq 1 ]; then
    ask_hidden "License key (SPK_..., from $DASHBOARD_URL; it is not shown as you paste): "
    LICENSE_KEY=$(printf '%s' "$ANSWER" | tr -d '[:space:]')
    KEY_FROM_PROMPT=1
  fi
  if [ -z "$LICENSE_KEY" ] && [ "$SKIP_KEY_CHECK" -eq 0 ]; then
    if [ "$INTERACTIVE" -eq 1 ]; then
      die "a license key is required: create one at $DASHBOARD_URL and run ./setup.sh again"
    fi
    MISSING="$MISSING GOSTLY_LICENSE_KEY"
  fi
fi
if [ -n "$LICENSE_KEY" ]; then
  case "$LICENSE_KEY" in
    SPK_*) ;;
    *) die "a Gostly license key starts with SPK_; copy it again from $DASHBOARD_URL" ;;
  esac
  case "${LICENSE_KEY#SPK_}" in
    "" | *[!A-Za-z0-9_-]*) die "that license key has characters a Gostly key never has; copy it again from $DASHBOARD_URL" ;;
  esac
fi

if [ -n "$MISSING" ]; then
  die "still empty in .env:$MISSING. Set them, or run ./setup.sh in a terminal to be asked"
fi

# ── 6. Key check ──────────────────────────────────────────────────────────────
# POST /v1/license/features takes the key in a JSON body and records no seat. 200 with an org_id
# is a recognised key; 200 with org_id null is an unknown or revoked key; 402 is a lapsed trial or
# subscription; the route allows 60 calls a minute per address. It runs on every run, so a key
# replaced in .env since the last run is checked before anything starts.
TENANT=$(value_of GOSTLY_TENANT_ID)

# existing_data: sets DATA_STATE to found (this project's database volume exists), none (Docker
# listed this project's volumes and that one is not among them), or unknown (Docker could not be
# asked, or the listing failed), DATA_UNKNOWN to why, and DATA_VOLUME to the volume's name. Only a
# listing that succeeded can be none: a failed one is never read as a directory without data.
existing_data() {
  DATA_STATE=unknown
  DATA_UNKNOWN="Docker cannot be reached"
  DATA_VOLUME=""
  command -v docker >/dev/null 2>&1 || return 0
  if [ "$DOCKER_OK" -eq 0 ]; then
    docker info >/dev/null 2>&1 || return 0
    PROJECT=$(compose_project)
  fi
  DATA_UNKNOWN="docker compose could not name this directory's project"
  [ -n "$PROJECT" ] || return 0
  # Docker's exit status is kept before the output is trimmed: in a pipeline it would be head's.
  DATA_UNKNOWN="docker volume ls failed"
  volumes=$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.volume=$DATA_VOLUME_NAME" 2>/dev/null) || return 0
  DATA_UNKNOWN=""
  DATA_VOLUME=$(printf '%s\n' "$volumes" | sed -n 1p)
  if [ -n "$DATA_VOLUME" ]; then DATA_STATE=found; else DATA_STATE=none; fi
}

# sha256_16: the first 16 hex characters of the SHA-256 of standard input.
sha256_16() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -r
  fi | cut -c1-16
}

# resolved_tenant: the tenant an installation without GOSTLY_TENANT_ID keeps its data under.
# A running ghost-web answers for itself (the command in Gostly's license key rotation runbook);
# otherwise the API's own rule applies: the key in .env, as sha256(key)[:16], or "default" for
# an installation that had no key. Prints nothing when docker ps fails: a running ghost-web
# that would answer otherwise cannot be ruled out, so no fallback is guessed.
resolved_tenant() {
  container=$(running_container ghost-web) || return 0
  if [ -n "$container" ]; then
    # A docker exec that fails answers nothing, whatever it printed: its status is kept, not tail's.
    answer=$(docker exec -w /app/api "$container" python3 -c \
      'from deps import _resolve_tenant_id; print(_resolve_tenant_id())' 2>/dev/null) || answer=""
    answer=$(printf '%s\n' "$answer" | tail -n 1)
    case "$answer" in
      "" | [!A-Za-z0-9]* | *[!A-Za-z0-9._:@/-]*) ;;
      *)
        printf '%s' "$answer"
        return 0
        ;;
    esac
  fi
  if [ "$KEY_FROM_PROMPT" -eq 1 ]; then
    printf 'default'
    return 0
  fi
  hash=$(printf '%s' "$LICENSE_KEY" | sha256_16)
  case "$hash" in
    *[!0-9a-f]*) return 0 ;;
  esac
  [ "${#hash}" -eq 16 ] && printf '%s' "$hash"
}

remove_key() {
  # Only a key that a fresh install was just given: an installed .env keeps its key line, for the
  # person to replace.
  if [ "$KEY_FROM_PROMPT" -eq 0 ] && [ -z "$TENANT" ]; then
    SU_V_GOSTLY_LICENSE_KEY=""
    write_env GOSTLY_LICENSE_KEY
  fi
}
if [ -n "$LICENSE_KEY" ] && [ "$KEY_FROM_PROMPT" -eq 1 ]; then
  SU_V_GOSTLY_LICENSE_KEY=$LICENSE_KEY
  UPDATE="$UPDATE GOSTLY_LICENSE_KEY"
fi
if [ -z "$LICENSE_KEY" ]; then
  say "No license key: the stack runs unlicensed until you add one and run ./setup.sh again."
elif [ "$SKIP_KEY_CHECK" -eq 1 ]; then
  say "License key: not checked (--skip-key-check)."
else
  command -v curl >/dev/null 2>&1 || die "curl is needed to check the key; install it, or run ./setup.sh --skip-key-check"
  body=$(mktemp "${TMPDIR:-/tmp}/gostly-setup.XXXXXX")
  TMP_FILES="$TMP_FILES $body"
  # The key reaches curl on its standard input (printf is a shell builtin), never its arguments.
  status=$(printf '{"key": "%s"}' "$LICENSE_KEY" | curl -sS --connect-timeout 10 --max-time 30 \
    -o "$body" -w '%{http_code}' -H 'Content-Type: application/json' --data-binary @- \
    "$PLATFORM_URL/v1/license/features") || status="000"
  replace_hint="create or rotate one at $DASHBOARD_URL"
  [ -z "$TENANT" ] || replace_hint="put a key from $DASHBOARD_URL in GOSTLY_LICENSE_KEY in .env (keep GOSTLY_TENANT_ID) and run ./setup.sh again"
  case "$status" in
    200)
      org_id=$(tr -d '\n' <"$body" | sed -n 's/.*"org_id"[[:space:]]*:[[:space:]]*"\([0-9A-Za-z-]*\)".*/\1/p')
      if [ -z "$org_id" ]; then
        remove_key
        die "gostly.ai does not recognise this key (mistyped, revoked, expired, or from another account); $replace_hint"
      fi
      if [ -n "$TENANT" ]; then
        if [ "$TENANT" = "$org_id" ]; then
          say "License key: accepted."
        else
          say "License key: accepted, but this key belongs to workspace $org_id and this installation keeps its data under GOSTLY_TENANT_ID $TENANT, which stays as it is. If the key is from another account by mistake, replace it with one from that account."
        fi
      else
        existing_data
        case "$DATA_STATE" in
          none)
            SU_V_GOSTLY_TENANT_ID=$org_id
            UPDATE="$UPDATE GOSTLY_TENANT_ID"
            say "License key: accepted. Workspace ID $org_id written to GOSTLY_TENANT_ID."
            ;;
          found)
            kept=$(resolved_tenant)
            if [ -z "$kept" ]; then
              die "this directory already has Gostly data (Docker volume $DATA_VOLUME) but no GOSTLY_TENANT_ID, and setup.sh could not tell which tenant that data is under. Nothing more was written to .env: GOSTLY_TENANT_ID and this run's license key and account values are not saved. Start the stack as it is (docker compose up -d), then run ./setup.sh again; or follow Existing data and GOSTLY_TENANT_ID in README.md"
            fi
            SU_V_GOSTLY_TENANT_ID=$kept
            UPDATE="$UPDATE GOSTLY_TENANT_ID"
            say "License key: accepted. This directory already has Gostly data (Docker volume $DATA_VOLUME) from before GOSTLY_TENANT_ID was set, so GOSTLY_TENANT_ID is set to the tenant that data is under, $kept, not to the key's Workspace ID $org_id. Your existing data stays visible."
            ;;
          *)
            say "License key: accepted. GOSTLY_TENANT_ID left empty: setup.sh could not list this directory's Docker volumes ($DATA_UNKNOWN), so it cannot tell whether this directory already has Gostly data, and it never picks a tenant for data it cannot see. Run ./setup.sh again once Docker answers (docker volume ls) to fill it."
            ;;
        esac
      fi
      ;;
    402) die "this key's trial or subscription has ended; renew at https://gostly.ai, or run ./setup.sh --skip-key-check to start without the check" ;;
    429) die "rate limited, try again in a minute" ;;
    *)
      die "could not check the key (HTTP $status from $PLATFORM_URL); check the connection, or run ./setup.sh --skip-key-check"
      ;;
  esac
fi

if [ -n "$UPDATE" ]; then
  # shellcheck disable=SC2086 # UPDATE is a list of key names
  write_env $UPDATE
  for key in $UPDATE; do
    say "$key: written to .env"
  done
  [ -z "$GENERATED_PASSWORD" ] || PASSWORD_UNSHOWN=1
fi
ADMIN_EMAIL=$(value_of GOSTLY_ADMIN_EMAIL)
# How the last line names the password: printed when generated in this run, never when chosen.
case "$UPDATE" in
  *GOSTLY_ADMIN_PASSWORD*)
    if [ -n "$GENERATED_PASSWORD" ]; then
      SIGN_IN_PASSWORD="with the password: $GENERATED_PASSWORD (it is saved in .env as GOSTLY_ADMIN_PASSWORD)"
    else
      SIGN_IN_PASSWORD="with the password you chose (it is saved in .env as GOSTLY_ADMIN_PASSWORD)"
    fi
    ;;
  *) SIGN_IN_PASSWORD="with the password in .env (GOSTLY_ADMIN_PASSWORD)" ;;
esac
# The values just written are the ones Compose must use too.
check_shell_values

if [ "$NO_START" -eq 1 ]; then
  say ".env is complete. Run ./setup.sh again to start Gostly."
  if [ "$PASSWORD_UNSHOWN" -eq 1 ]; then
    PASSWORD_UNSHOWN=0
    say "Sign in as $ADMIN_EMAIL $SIGN_IN_PASSWORD"
  fi
  exit 0
fi

# registry_login_with_key: sign in to the private registry with a 12-hour token that gostly.ai
# issues for the license key (GET /v1/license/registry-credentials). The key reaches curl in a
# config read from its standard input (-K -), and the token reaches docker login on its standard
# input, so neither is ever in a process argument list or a file. Sets logged_in=1 on success.
# A refused key, a lapsed trial or a second rate limit stops the script; any other answer falls
# back to the registry login command from the dashboard, with one line saying why.
registry_login_with_key() {
  if [ -z "$LICENSE_KEY" ]; then
    say "No license key in .env, so the registry sign-in cannot be fetched from gostly.ai."
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    say "curl is not installed, so the registry sign-in cannot be fetched from gostly.ai."
    return 0
  fi
  attempt=1
  while :; do
    # -q first: a ~/.curlrc never adds an output file or other options to this call.
    reply=$(printf 'header = "X-License-Key: %s"\n' "$LICENSE_KEY" |
      curl -q -sS -K - --connect-timeout 10 --max-time 30 -w '\n%{http_code}' \
        "$PLATFORM_URL/v1/license/registry-credentials") || reply="
000"
    status=${reply##*"$NL"}
    body=${reply%"$NL"*}
    reply=""
    case "$status" in
      429)
        if [ "$attempt" -eq 1 ]; then
          say "gostly.ai is rate limiting registry sign-ins; trying once more in ${RETRY_SECONDS} s."
          attempt=2
          sleep "$RETRY_SECONDS"
          continue
        fi
        die "gostly.ai is still rate limiting registry sign-ins for this address or this license key; wait a few minutes and run ./setup.sh again"
        ;;
    esac
    break
  done
  case "$status" in
    200)
      flat=$(printf '%s' "$body" | tr -d '\n')
      body=""
      token=$(printf '%s' "$flat" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9+/=._-]*\)".*/\1/p')
      login_registry=$(printf '%s' "$flat" | sed -n 's/.*"registry"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9.-]*\(:[0-9]*\)\{0,1\}\)".*/\1/p')
      flat=""
      if [ -z "$token" ] || [ -z "$login_registry" ]; then
        token=""
        say "gostly.ai answered without a usable registry sign-in."
        return 0
      fi
      if [ -n "$registry" ] && [ "$login_registry" != "$registry" ]; then
        say "Warning: gostly.ai signs in to $login_registry, but the Compose files pull from $registry."
      fi
      # printf is a shell builtin: the token goes through the pipe, never an argument list.
      if ! printf '%s' "$token" | docker login --username AWS --password-stdin "$login_registry"; then
        token=""
        die "docker login to $login_registry failed with the sign-in from gostly.ai; see the message above and run ./setup.sh again"
      fi
      token=""
      logged_in=1
      say "Registry: signed in to $login_registry with your license key (valid for 12 hours)."
      ;;
    401)
      body=""
      die "gostly.ai did not accept this license key for the image registry (mistyped, revoked, expired, or from another account). Create or rotate a key at $DASHBOARD_URL, replace GOSTLY_LICENSE_KEY in .env (keep GOSTLY_TENANT_ID) and run ./setup.sh again"
      ;;
    402)
      body=""
      die "this key's trial or subscription has ended; renew at https://gostly.ai"
      ;;
    *)
      body=""
      say "Could not get a registry sign-in from gostly.ai (HTTP $status)."
      ;;
  esac
}
NL='
'

# ── 7. Images ─────────────────────────────────────────────────────────────────
missing=$(missing_images) || die "docker compose could not read the Compose file and .env (the message above names the problem)"
registry=""
for image in $(docker compose config --images); do
  case "$image" in
    */gostlyai/*) registry=${image%%/*} ;;
  esac
done

if [ -z "$missing" ]; then
  say "Images: all present, no download needed."
else
  needs_login=0
  for image in $missing; do
    case "$image" in
      */gostlyai/*) needs_login=1 ;;
    esac
  done
  logged_in=0
  if [ "$needs_login" -eq 1 ]; then
    registry_login_with_key
  fi
  if [ "$needs_login" -eq 1 ] && [ "$logged_in" -eq 0 ] && [ "$INTERACTIVE" -eq 1 ]; then
    ask_hidden "Paste the registry login command from $DASHBOARD_URL (Installing by hand, Copy registry login) and press Enter, or press Enter if you are signed in already: " long
    pasted=$(trim "$ANSWER")
    if [ -n "$pasted" ]; then
      host_pattern=$(printf '%s' "$registry" | sed 's/[.]/\\./g')
      # Only the dashboard's exact command is accepted: printf of one token, piped to docker login
      # for the registry this Compose file uses. Nothing else in the pasted text is ever run.
      shape="^printf[[:space:]]+'%s'[[:space:]]+'[A-Za-z0-9+/=._-]+'[[:space:]]*[|][[:space:]]*docker[[:space:]]+login[[:space:]]+--username[[:space:]]+('AWS'|AWS)[[:space:]]+--password-stdin[[:space:]]+('$host_pattern'|$host_pattern)\$"
      if [ -z "$registry" ] || ! printf '%s\n' "$pasted" | grep -Eq "$shape"; then
        die "that is not the registry login command from $DASHBOARD_URL; nothing was run. Copy it again (Installing by hand, Copy registry login)"
      fi
      token=$(printf '%s\n' "$pasted" | sed -n "s/^printf[[:space:]]*'%s'[[:space:]]*'\([A-Za-z0-9+/=._-]*\)'.*/\1/p")
      # The same command, run with the token on docker's standard input; nothing is stored here.
      printf '%s' "$token" | docker login --username AWS --password-stdin "$registry" ||
        die "docker login failed; registry logins last 12 hours, so copy a fresh one from $DASHBOARD_URL"
      token=""
      pasted=""
      ANSWER=""
      logged_in=1
    fi
  fi
  say "Downloading the missing images..."
  if ! docker compose pull --policy missing; then
    if [ "$needs_login" -eq 1 ] && [ "$logged_in" -eq 0 ]; then
      die "the download failed. Sign in to the registry with the command from $DASHBOARD_URL (Installing by hand, Copy registry login; it lasts 12 hours) and run ./setup.sh again"
    fi
    die "the download failed; see the message above and run ./setup.sh again"
  fi
fi

# ── 8. Start and wait ─────────────────────────────────────────────────────────
expected=$(docker compose config --services) || die "docker compose could not list the services (the message above names the problem)"
docker compose up -d || die "docker compose up failed; see the message above, then docker compose ps -a and docker compose logs"

# One line per container: service|state|health|exit code. A Go template, not JSON: the JSON rows
# carry arrays (Publishers) that a line-oriented shell cannot split safely, and "|" is not
# whitespace, so an empty health field stays a field. Every enabled service must have a row:
# a one-shot service must have exited 0, every other one must be running (and healthy when it
# has a health check). A serving container that stopped, even with exit code 0, is a failure.
PS_FORMAT='{{.Service}}|{{.State}}|{{.Health}}|{{.ExitCode}}'
waited=0
while :; do
  total=0
  ready=0
  waiting=""
  rows=$(docker compose ps -a --format "$PS_FORMAT" 2>/dev/null) || rows=""
  for service in $expected; do
    total=$((total + 1))
    row=$(printf '%s\n' "$rows" | grep "^$service|" | tail -n 1 || true)
    if [ -z "$row" ]; then
      waiting="$waiting $service (not created)"
      continue
    fi
    row=${row#*|}
    state=${row%%|*}
    row=${row#*|}
    health=${row%%|*}
    exit_code=${row#*|}
    one_shot=0
    case " $ONE_SHOT " in *" $service "*) one_shot=1 ;; esac
    case "$one_shot:$state:$health" in
      0:running: | 0:running:healthy) ready=$((ready + 1)) ;;
      1:exited:*)
        [ "$exit_code" = 0 ] || die "$service exited with code $exit_code; see docker compose logs $service"
        ready=$((ready + 1))
        ;;
      0:exited:* | 0:dead:*)
        die "$service stopped (exit code $exit_code); see docker compose logs $service, then run ./setup.sh again"
        ;;
      *) waiting="$waiting $service ($state${health:+, $health})" ;;
    esac
  done
  if [ "$total" -gt 0 ] && [ "$ready" -eq "$total" ]; then
    break
  fi
  if [ "$waited" -ge "$WAIT_SECONDS" ]; then
    die "the stack was not healthy after ${WAIT_SECONDS} s; still waiting on:$waiting. See docker compose ps -a and docker compose logs"
  fi
  say "Waiting for the containers: $ready of $total ready (${waited} s)"
  sleep "$POLL_SECONDS"
  waited=$((waited + POLL_SECONDS))
done

published_port() {
  port=$(docker compose port "$1" "$2" 2>/dev/null | tail -n 1 || true)
  port=${port##*:}
  case "$port" in
    "" | *[!0-9]*) printf '%s' "$3" ;;
    *) printf '%s' "$port" ;;
  esac
}
web_default=$(value_of GOSTLY_WEB_PORT)
proxy_default=$(value_of GOSTLY_PROXY_PORT)
web_port=$(published_port ghost-web 3000 "${web_default:-3000}")
proxy_port=$(published_port ghost-proxy 8080 "${proxy_default:-8080}")
PASSWORD_UNSHOWN=0
say "Gostly is running at http://localhost:$web_port. Sign in as $ADMIN_EMAIL $SIGN_IN_PASSWORD"
case ",$(value_of COMPOSE_PROFILES)," in
  *,demo,*) say "Try the demo upstream: curl http://localhost:$proxy_port/gostly-demo/get" ;;
esac
