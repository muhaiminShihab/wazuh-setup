#!/bin/bash
#
# Wazuh 4.14.9 on Docker Desktop for an Apple silicon Mac, plus the Wazuh agent
# for this Mac.
#
# What it does:
#   1. Checks Docker Desktop is installed, running and has enough memory.
#   2. Downloads Wazuh's official Docker setup (wazuh-docker v4.14.9) to ~/wazuh-docker.
#   3. Hardens it for a laptop before the first start:
#        - every port listens on this Mac only (127.0.0.1), never on your network
#        - every default password is replaced with a random one
#   4. Generates the TLS certificates and starts the server (manager, indexer, dashboard).
#   5. Installs the Wazuh agent for macOS and connects it to that server.
#   6. Prints the dashboard address and admin password.
#
# Usage:
#   bash setup-wazuh-docker-mac.sh
#
# Your Mac password is asked once, for installing the agent.
# Safe to re-run: on a second run it just starts the server and checks the agent.
# Optional: WAZUH_DIR=/some/other/folder bash setup-wazuh-docker-mac.sh

set -euo pipefail

WAZUH_VERSION="4.14.9"
INSTALL_DIR="${WAZUH_DIR:-$HOME/wazuh-docker}"
STACK_DIR="$INSTALL_DIR/single-node"
CRED_FILE="$STACK_DIR/.wazuh-credentials"
REPO_TARBALL="https://github.com/wazuh/wazuh-docker/archive/refs/tags/v${WAZUH_VERSION}.tar.gz"
AGENT_PKG_URL="https://packages.wazuh.com/4.x/macos/wazuh-agent-${WAZUH_VERSION}-1.arm64.pkg"
INDEXER_IMAGE="wazuh/wazuh-indexer:${WAZUH_VERSION}"
OSSEC_DIR="/Library/Ossec"

# Defaults shipped in wazuh-docker; all of them are replaced before first start.
DEFAULT_ADMIN_PW="SecretPassword"
DEFAULT_KIBANASERVER_PW="kibanaserver"
DEFAULT_API_PW='MyS3cr37P450r.*-'

say()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mStopped:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

check_mac() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This script is for macOS."
  [[ "$(uname -m)" == "arm64" ]] || die "This script is for Apple silicon Macs (M1 or later)."
  local tool
  for tool in curl tar perl openssl nc; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' is missing from this Mac."
  done
}

check_docker() {
  say "Checking Docker Desktop"
  command -v docker >/dev/null 2>&1 || die "Docker Desktop isn't installed.
  Install it from https://www.docker.com/products/docker-desktop/ (choose Apple silicon),
  open it once, then run this script again."
  docker info >/dev/null 2>&1 || die "Docker Desktop isn't running.
  Open Docker Desktop, wait until it shows 'Engine running', then run this script again."
  docker compose version >/dev/null 2>&1 || die "'docker compose' isn't available. Update Docker Desktop and try again."
  ok "Docker Desktop is running"

  # Wazuh recommends 8 GB of RAM for the Docker host.
  local mem_bytes mem_gib10
  mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
  mem_gib10=$(( mem_bytes * 10 / 1073741824 ))   # GiB x10, so 7.6 GiB -> 76
  if (( mem_gib10 < 35 )); then
    die "Docker Desktop only has $((mem_gib10 / 10)).$((mem_gib10 % 10)) GB of memory; Wazuh needs at least 4 GB (8 GB recommended).
  In Docker Desktop: Settings > Resources > Memory, set it to 8 GB, click 'Apply & restart', then run this script again."
  elif (( mem_gib10 < 70 )); then
    warn "Docker Desktop has $((mem_gib10 / 10)).$((mem_gib10 % 10)) GB of memory. Wazuh recommends 8 GB (Settings > Resources > Memory)."
    warn "Continuing; the dashboard may be slow."
  else
    ok "Docker Desktop has $((mem_gib10 / 10)).$((mem_gib10 % 10)) GB of memory"
  fi

  # The Wazuh indexer needs vm.max_map_count >= 262144 inside Docker's Linux VM.
  local cur
  cur="$(docker run --rm alpine:3 sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
  if (( cur < 262144 )); then
    docker run --rm --privileged alpine:3 sysctl -w vm.max_map_count=262144 >/dev/null \
      || die "Couldn't set vm.max_map_count in Docker's VM."
    ok "Set vm.max_map_count to 262144"
    warn "Docker Desktop may reset this when it restarts. If the dashboard stops working after a restart, run this script again."
  else
    ok "vm.max_map_count is $cur"
  fi
}

# ---------------------------------------------------------------------------
# Passwords
# ---------------------------------------------------------------------------

# 25 characters with upper, lower, digit and symbol, which the Wazuh API
# requires. Only letters, digits, '.' and '-' so it is safe in YAML, JSON,
# docker-compose and shell.
gen_password() {
  local r
  r="$(openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-20)"
  [[ ${#r} -eq 20 ]] || die "Couldn't generate a random password."
  printf '%s-%s.Wz9' "${r:0:10}" "${r:10:10}"
}

# Prints a bcrypt hash of $1 for the indexer's internal_users.yml.
bcrypt_hash() {
  local pw="$1" h=""
  if command -v htpasswd >/dev/null 2>&1; then
    h="$(printf '%s' "$pw" | htpasswd -n -i -B -C 12 wazuh 2>/dev/null | sed -n '1s/^wazuh://p')" || h=""
  fi
  if [[ "$h" != \$2* ]]; then
    # Fall back to Wazuh's own tool inside the indexer image.
    # shellcheck disable=SC2016  # $WZ_PW and the hash prefix are meant literally here
    h="$(WZ_PW="$pw" docker run --rm -e WZ_PW "$INDEXER_IMAGE" \
          bash -c '/usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh -p "$WZ_PW"' 2>/dev/null \
          | grep -E '^\$2[aby]\$' | tail -n 1)" || h=""
  fi
  [[ "$h" =~ ^\$2[aby]\$[0-9]{2}\$.{53}$ ]] || die "Couldn't generate a password hash."
  printf '%s' "$h"
}

# Replaces the hash of one user in internal_users.yml.
set_user_hash() {   # file user hash
  [[ "$3" =~ ^\$2[aby]\$[0-9]{2}\$.{53}$ ]] || die "Invalid password hash for user '$2'."
  WZ_USER="$2" WZ_HASH="$3" perl -0pi -e \
    's/(^\Q$ENV{WZ_USER}\E:\n  hash: )"[^"]*"/$1"$ENV{WZ_HASH}"/m or die "user $ENV{WZ_USER} not found\n"' "$1"
}

# ---------------------------------------------------------------------------
# Configure a fresh copy of wazuh-docker (runs before the first start)
# ---------------------------------------------------------------------------

# Binds every published port to 127.0.0.1 and replaces default passwords.
# Expects ADMIN_PASSWORD, KIBANASERVER_PASSWORD, API_PASSWORD, DASH_PORT.
harden_config() {   # stack_dir
  local dir="$1"
  local compose="$dir/docker-compose.yml"
  local users="$dir/config/wazuh_indexer/internal_users.yml"
  local wazuh_yml="$dir/config/wazuh_dashboard/wazuh.yml"

  WZ_ADMIN="$ADMIN_PASSWORD" WZ_KS="$KIBANASERVER_PASSWORD" WZ_API="$API_PASSWORD" \
  WZ_DPORT="$DASH_PORT" WZ_D_ADMIN="$DEFAULT_ADMIN_PW" WZ_D_KS="$DEFAULT_KIBANASERVER_PW" \
  WZ_D_API="$DEFAULT_API_PW" perl -0pi -e '
    s/^(\s+- )"?443:5601"?[ \t]*$/$1"127.0.0.1:$ENV{WZ_DPORT}:5601"/mg;
    s{^(\s+- )"(\d+:\d+(?:/udp)?)"[ \t]*$}{$1"127.0.0.1:$2"}mg;
    s/INDEXER_PASSWORD=\Q$ENV{WZ_D_ADMIN}\E$/INDEXER_PASSWORD=$ENV{WZ_ADMIN}/mg;
    s/DASHBOARD_PASSWORD=\Q$ENV{WZ_D_KS}\E$/DASHBOARD_PASSWORD=$ENV{WZ_KS}/mg;
    s/API_PASSWORD=\Q$ENV{WZ_D_API}\E$/API_PASSWORD=$ENV{WZ_API}/mg;
  ' "$compose"

  WZ_API="$API_PASSWORD" WZ_D_API="$DEFAULT_API_PW" perl -pi -e \
    's/^(\s+password: )"\Q$ENV{WZ_D_API}\E"/$1"$ENV{WZ_API}"/' "$wazuh_yml"

  # admin and kibanaserver get the saved passwords. The other demo users
  # (kibanaro, logstash, readall, snapshotrestore) ship with public passwords,
  # so they get random ones that are never saved.
  # (Hashes go into variables first so a failed hash stops the script.)
  local h u
  h="$(bcrypt_hash "$ADMIN_PASSWORD")";        set_user_hash "$users" admin "$h"
  h="$(bcrypt_hash "$KIBANASERVER_PASSWORD")"; set_user_hash "$users" kibanaserver "$h"
  for u in kibanaro logstash readall snapshotrestore; do
    if grep -q "^$u:" "$users"; then
      h="$(gen_password)"; h="$(bcrypt_hash "$h")"; set_user_hash "$users" "$u" "$h"
    fi
  done

  verify_config "$dir"
}

# Fails if any default password or network-wide port is left.
verify_config() {   # stack_dir
  local dir="$1"
  local compose="$dir/docker-compose.yml"
  local users="$dir/config/wazuh_indexer/internal_users.yml"
  local wazuh_yml="$dir/config/wazuh_dashboard/wazuh.yml"

  if grep -nE "PASSWORD=($DEFAULT_ADMIN_PW|$DEFAULT_KIBANASERVER_PW)$" "$compose" \
     || grep -nF "$DEFAULT_API_PW" "$compose" "$wazuh_yml"; then
    die "A default password is still in the config (see above)."
  fi
  if grep -nE '^[[:space:]]+- "?[0-9]+:[0-9]+(/udp)?"?[[:space:]]*$' "$compose"; then
    die "A port is still open to the network (see above)."
  fi
  local p
  for p in 1514 1515 9200 55000; do
    grep -q "\"127.0.0.1:$p:$p\"" "$compose" || die "Port $p isn't bound to 127.0.0.1."
  done
  grep -q "\"127.0.0.1:$DASH_PORT:5601\"" "$compose" || die "The dashboard port isn't bound to 127.0.0.1."
  for p in K/SpwjtB 4AcgAt3x JJSXNfTo u1ShR4l4 ae4ycwzw DpwmetHK; do
    if grep -q "$p" "$users"; then die "A default user hash is still in internal_users.yml."; fi
  done
  ok "All ports bound to 127.0.0.1; all default passwords replaced"
}

pick_dashboard_port() {
  local p
  for p in 443 8443 9443; do
    if ! nc -z 127.0.0.1 "$p" >/dev/null 2>&1; then
      DASH_PORT="$p"
      return
    fi
  done
  die "Ports 443, 8443 and 9443 are all in use on this Mac; free one and try again."
}

fresh_setup() {
  say "Setting up Wazuh $WAZUH_VERSION in $INSTALL_DIR"
  [[ -e "$INSTALL_DIR" ]] && die "$INSTALL_DIR already exists but wasn't set up by this script.
  Move or rename it, or choose another folder: WAZUH_DIR=~/some-folder bash $0"
  local vols
  vols="$(docker volume ls -q)"
  if grep -qx 'single-node_wazuh-indexer-data' <<<"$vols"; then
    die "Data from an earlier Wazuh Docker install is still in Docker.
  If you don't need it, remove it with:
    docker volume ls -q | grep '^single-node_' | xargs docker volume rm
  then run this script again."
  fi

  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL "$REPO_TARBALL" -o "$tmp/wazuh-docker.tar.gz" || die "Couldn't download $REPO_TARBALL"
  tar -xzf "$tmp/wazuh-docker.tar.gz" -C "$tmp"
  [[ -f "$tmp/wazuh-docker-$WAZUH_VERSION/single-node/docker-compose.yml" ]] || die "The download didn't contain the expected files."
  mv "$tmp/wazuh-docker-$WAZUH_VERSION" "$INSTALL_DIR"
  rm -rf "$tmp"
  ok "Downloaded wazuh-docker v$WAZUH_VERSION"

  pick_dashboard_port
  ADMIN_PASSWORD="$(gen_password)"
  KIBANASERVER_PASSWORD="$(gen_password)"
  API_PASSWORD="$(gen_password)"

  say "Hardening the configuration"
  harden_config "$STACK_DIR"

  ( umask 077
    cat > "$CRED_FILE" <<EOF
# Wazuh credentials created by setup-wazuh-docker-mac.sh on $(date '+%Y-%m-%d %H:%M')
# Dashboard login: admin / ADMIN_PASSWORD
DASH_PORT='$DASH_PORT'
ADMIN_PASSWORD='$ADMIN_PASSWORD'
KIBANASERVER_PASSWORD='$KIBANASERVER_PASSWORD'
API_PASSWORD='$API_PASSWORD'
EOF
  )
  ok "Passwords saved to $CRED_FILE (readable only by you)"

  say "Generating TLS certificates"
  ( cd "$STACK_DIR" && docker compose -f generate-indexer-certs.yml run --rm generator ) >/dev/null \
    || die "Certificate generation failed (see the messages above)."
  [[ -f "$STACK_DIR/config/wazuh_indexer_ssl_certs/root-ca.pem" ]] || die "Certificate generation failed."
  ok "Certificates created"
}

load_existing() {
  say "Found an existing setup in $STACK_DIR"
  # shellcheck disable=SC1090
  source "$CRED_FILE"
  : "${DASH_PORT:?missing in $CRED_FILE}" "${ADMIN_PASSWORD:?missing in $CRED_FILE}"
  verify_config "$STACK_DIR"
}

# ---------------------------------------------------------------------------
# Start the server
# ---------------------------------------------------------------------------

start_stack() {
  say "Starting the Wazuh server (the first start downloads about 3 GB of images)"
  ( cd "$STACK_DIR" && docker compose up -d ) \
    || die "Docker couldn't start the Wazuh containers (see the messages above).
  If it says a port is already allocated, another program is using 1514, 1515, 514, 9200 or 55000."

  say "Waiting for Wazuh to be ready (usually 1-3 minutes)"
  local code
  for _ in $(seq 1 72); do
    code="$(curl -sk -o /dev/null -w '%{http_code}' -u "admin:$ADMIN_PASSWORD" https://127.0.0.1:9200/ || true)"
    [[ "$code" == "200" ]] && break
    sleep 5
  done
  [[ "$code" == "200" ]] || die "The Wazuh indexer didn't come up with the new admin password (last HTTP status: $code).
  See what went wrong with:  cd $STACK_DIR && docker compose logs wazuh.indexer | tail -50"
  ok "Indexer is up and accepts the new admin password"

  for _ in $(seq 1 60); do
    code="$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:$DASH_PORT/app/login" || true)"
    [[ "$code" == "200" ]] && break
    sleep 5
  done
  [[ "$code" == "200" ]] || die "The dashboard didn't start (last HTTP status: $code).
  See what went wrong with:  cd $STACK_DIR && docker compose logs wazuh.dashboard | tail -50"
  ok "Dashboard is up"

  code="$(curl -sk -u "admin:$DEFAULT_ADMIN_PW" -o /dev/null -w '%{http_code}' https://127.0.0.1:9200/ || true)"
  if [[ "$code" == "200" ]]; then
    die "The default admin password still works; the hardening didn't apply. Please report this."
  fi
  ok "Default admin password is rejected"
}

# ---------------------------------------------------------------------------
# Agent for this Mac
# ---------------------------------------------------------------------------

install_agent() {
  say "Installing the Wazuh agent for this Mac"
  echo "    Your Mac password is needed to install the agent (it's typed into macOS, not saved anywhere)."
  sudo -v || die "The agent install needs your Mac password."

  if [[ -d "$OSSEC_DIR" ]]; then
    ok "Agent already installed"
    local addr
    addr="$(sudo sed -n 's:.*<address>\(.*\)</address>.*:\1:p' "$OSSEC_DIR/etc/ossec.conf")"
    addr="${addr%%$'\n'*}"
    if [[ "$addr" != "127.0.0.1" ]]; then
      warn "The agent pointed at '$addr'; switching it to this Mac's Wazuh server."
      sudo sed -i '' -e 's:<address>[^<]*</address>:<address>127.0.0.1</address>:' "$OSSEC_DIR/etc/ossec.conf"
      sudo cp "$OSSEC_DIR/etc/client.keys" "$OSSEC_DIR/etc/client.keys.bak" 2>/dev/null || true
      sudo sh -c ": > '$OSSEC_DIR/etc/client.keys'"
    fi
  else
    local tmp pkg sig
    tmp="$(mktemp -d)"
    pkg="$tmp/wazuh-agent-$WAZUH_VERSION-1.arm64.pkg"
    curl -fSL --progress-bar "$AGENT_PKG_URL" -o "$pkg" || die "Couldn't download $AGENT_PKG_URL"
    sig="$(pkgutil --check-signature "$pkg" 2>&1)" || die "The agent package isn't signed:
$sig"
    grep -qi 'wazuh' <<<"$sig" || die "The agent package isn't signed by Wazuh:
$sig"
    ok "Package signature checked (signed by Wazuh)"
    echo "WAZUH_MANAGER='127.0.0.1'" | sudo tee /tmp/wazuh_envs >/dev/null
    sudo installer -pkg "$pkg" -target / >/dev/null || die "The agent installer failed."
    rm -rf "$tmp"
    ok "Agent installed"
  fi

  sudo launchctl bootstrap system /Library/LaunchDaemons/com.wazuh.agent.plist 2>/dev/null \
    || sudo "$OSSEC_DIR/bin/wazuh-control" restart >/dev/null 2>&1 || true

  say "Waiting for the agent to connect"
  local agents
  for _ in $(seq 1 36); do
    agents="$( cd "$STACK_DIR" && docker compose exec -T wazuh.manager /var/ossec/bin/agent_control -l 2>/dev/null || true )"
    # ID 000 is the manager itself; any other Active ID is this Mac.
    if grep -qE 'ID: 0*[1-9][0-9]*,.*Active' <<<"$agents"; then
      ok "This Mac's agent is connected and Active"
      return
    fi
    sleep 5
  done
  warn "The agent hasn't shown up as Active yet. Check its log with:"
  warn "  sudo tail -30 $OSSEC_DIR/logs/ossec.log"
}

# ---------------------------------------------------------------------------

summary() {
  local url="https://localhost"
  [[ "$DASH_PORT" != "443" ]] && url="https://localhost:$DASH_PORT"
  cat <<EOF

$(printf '\033[1;32m')Wazuh is running.$(printf '\033[0m')

  Dashboard:  $url
              (your browser will warn about the certificate; it's self-signed, so that's expected)
  Username:   admin
  Password:   $ADMIN_PASSWORD

  Put that password in your password manager. All passwords are also in:
    $CRED_FILE

  Everything listens on this Mac only (127.0.0.1). Nothing is reachable from your network.

  Stop the server:   cd $STACK_DIR && docker compose stop
  Start it again:    cd $STACK_DIR && docker compose start   (or re-run this script)
  The agent keeps watching this Mac and catches up when the server is back.
EOF
}

main() {
  check_mac
  check_docker
  if [[ -f "$CRED_FILE" ]]; then
    load_existing
  else
    fresh_setup
  fi
  start_stack
  install_agent
  summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
