#!/bin/sh
# new-secrets.sh: fill the empty generated-secret lines of .env, once.
#
#   cp .template.env .env
#   ./new-secrets.sh            # or: sh new-secrets.sh [path/to/.env]
#
# It writes the three database passwords and GHOST_API_KEY on this machine, so
# they never pass through a browser, a download or the clipboard. Only a line
# that is present and empty is filled. A value that is already set is never
# replaced, so a second run changes nothing and exits 0: regenerating a database
# password would lock the stack out of its existing database volume.
# A missing line is left missing (delete the GHOST_API_KEY line on purpose to
# let the dashboard manage that key). No value is ever printed.
set -eu

ENV_FILE=${1:-.env}
SECRETS="POSTGRES_PASSWORD GOSTLY_APP_DB_PASSWORD GOSTLY_SERVICE_DB_PASSWORD GHOST_API_KEY"
# Values a person sets by hand (see README.md, Required environment variable updates).
REQUIRED="GOSTLY_ADMIN_EMAIL GOSTLY_ADMIN_PASSWORD GOSTLY_LICENSE_KEY GOSTLY_TENANT_ID"

die() {
  printf 'new-secrets.sh: %s\n' "$*" >&2
  exit 1
}

if [ -L "$ENV_FILE" ]; then
  die "$ENV_FILE is a symbolic link; run it on the real file"
fi
if [ ! -f "$ENV_FILE" ]; then
  die "$ENV_FILE not found. Create it first: cp .template.env .env"
fi

# value_of KEY: the value of the single active KEY= line, with a trailing CR and
# one pair of surrounding quotes removed.
value_of() {
  sed -n "s/^$1=//p" "$ENV_FILE" | tr -d '\r' | sed -e "s/^'\(.*\)'\$/\1/" -e 's/^"\(.*\)"$/\1/'
}

random_hex() {
  od -An -tx1 -N32 /dev/urandom | tr -d ' \n'
}

# Same shape as the platform's generated key: gsk_svc_ plus 43 URL-safe characters.
random_service_key() {
  printf 'gsk_svc_%s' "$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr '+/' '-_' | tr -d '=\n')"
}

FILL=""
for key in $SECRETS; do
  count=$(grep -c "^$key=" "$ENV_FILE" || true)
  if [ "$count" -gt 1 ]; then
    die "$ENV_FILE has $count $key= lines; keep exactly one (Compose uses the last) and run again"
  fi
  if [ "$count" -eq 0 ]; then
    printf '%s: no line in %s, left alone\n' "$key" "$ENV_FILE"
  elif [ -n "$(value_of "$key")" ]; then
    printf '%s: already set, kept\n' "$key"
  else
    FILL="$FILL $key"
  fi
done

if [ -n "$FILL" ]; then
  NS_POSTGRES_PASSWORD=$(random_hex)
  NS_GOSTLY_APP_DB_PASSWORD=$(random_hex)
  NS_GOSTLY_SERVICE_DB_PASSWORD=$(random_hex)
  NS_GHOST_API_KEY=$(random_service_key)
  for value in "$NS_POSTGRES_PASSWORD" "$NS_GOSTLY_APP_DB_PASSWORD" "$NS_GOSTLY_SERVICE_DB_PASSWORD"; do
    case "$value" in
      *[!0-9a-f]* | "") die "could not read 32 random bytes from /dev/urandom; nothing was changed" ;;
    esac
    [ "${#value}" -eq 64 ] || die "could not read 32 random bytes from /dev/urandom; nothing was changed"
  done
  case "${NS_GHOST_API_KEY#gsk_svc_}" in
    *[!A-Za-z0-9_-]* | "") die "could not generate GHOST_API_KEY; nothing was changed" ;;
  esac
  [ "${#NS_GHOST_API_KEY}" -eq 51 ] || die "could not generate GHOST_API_KEY; nothing was changed"
  export NS_POSTGRES_PASSWORD NS_GOSTLY_APP_DB_PASSWORD NS_GOSTLY_SERVICE_DB_PASSWORD NS_GHOST_API_KEY

  # Write a private copy beside .env, then move it into place in one step.
  tmp="$ENV_FILE.new-secrets.$$"
  trap 'rm -f "$tmp"' EXIT
  (umask 077 && : >"$tmp")
  # The values reach awk through its environment, never its argument list.
  NS_FILL="$FILL" awk '
    BEGIN { n = split(ENVIRON["NS_FILL"], keys, " "); for (i = 1; i <= n; i++) fill[keys[i]] = 1 }
    {
      line = $0
      sub(/\r$/, "", line)
      eq = index(line, "=")
      key = eq ? substr(line, 1, eq - 1) : ""
      rest = eq ? substr(line, eq + 1) : ""
      if (key in fill && (rest == "" || rest == "\047\047" || rest == "\"\"")) {
        print key "=" ENVIRON["NS_" key]
        delete fill[key]
        next
      }
      print $0
    }
  ' "$ENV_FILE" >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
  trap - EXIT
  for key in $FILL; do
    printf '%s: generated\n' "$key"
  done
fi

MISSING=""
for key in $REQUIRED; do
  if [ -z "$(value_of "$key")" ]; then
    MISSING="$MISSING $key"
  fi
done
if [ -n "$MISSING" ]; then
  printf 'Still empty in %s; set these before docker compose up:%s\n' "$ENV_FILE" "$MISSING"
fi
