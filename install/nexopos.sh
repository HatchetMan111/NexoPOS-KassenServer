#!/bin/bash
# =============================================================================
# NexoPOS Proxmox LXC Installer (Community-Scripts-Stil)
#
# Repo:        https://github.com/HatchetMan111/NexoPOS-KassenServer
# Upstream:    https://github.com/Blair2004/NexoPOS  (GPL-3.0, Core 6.3.0)
# App:         NexoPOS – Laravel-12-Kassensystem (POS, Inventar, Kunden,
#              Buchhaltung, Reports) mit Vue.js-Frontend
# Stack:       PHP 8.4 (FPM) + MariaDB 10.11 + Nginx, In-Container-Build
#              (Composer + Node 24) – kein Node im Laufzeitbetrieb
# Web-UI:      http://<CT-IP>:8080
#
# Einzeiler:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/NexoPOS-KassenServer/main/install/nexopos.sh)"
#
# Modi:
#   (keine)        Neu-Installation (nächste freie CT-ID)
#   --update       App-Code + Assets aktualisieren, Dienste neu starten
#   --uninstall    Container entfernen
#   --status       Service-/HTTP-Status des bestehenden Containers
#   --id <N>       Explizite CT-ID (für --update/--uninstall/--status)
#   --ram <MB>     RAM in MB (Standard 2048)
#   --disk <GB>    Disk in GB (Standard 10)
#   --cores <N>    vCPU (Standard 2)
#   --hostname X   CT-Hostname (Standard: nexopos)
#   --port <N>     Web-Port im CT (Standard 8080)
#   --admin-user X Admin-Benutzername (Standard: admin)
#   --admin-email X Admin-E-Mail (Standard: admin@nexopos.local)
#   --admin-pass X Admin-Passwort (Standard: generiert, wird ausgegeben)
#   --reset-pass   Setzt das Admin-Passwort auch bei bestehender Installation
#                  (sonst legt ns:setup den Benutzer nur beim ersten Mal an)
#   --store-name X Name des Ladens (Standard: NexoPOS)
#   --yes          Keine Rückfrage (für Automatisierung)
#
# set -Eeuo pipefail + ERR-Trap: vollständige Fehlerkette (Stacktrace, Logs,
# Exit-Codes). Bei Fehler wird ein `bash -x`-Log angeboten.
# =============================================================================

set -Eeuo pipefail

# ---------- Variablen (oben, Community-Scripts-Konform) ----------------------
APP_NAME="nexopos"
APP_TITLE="NexoPOS"
# App-Metadaten (Doku oben; identische Werte im In-Container-Script gesetzt)
# shellcheck disable=SC2034
APP_REPO="https://github.com/Blair2004/NexoPOS.git"   # Doku/ONE_LINER
APP_PORT="${NX_PORT:-8080}"

CTID=""
CT_HOSTNAME="nexopos"
CT_RAM=2048
CT_DISK=10
CT_CORES=2
CT_BRIDGE="vmbr0"
CT_STORAGE="local-lvm"
CT_TEMPLATE=""
CT_UNPRIVILEGED=1
CT_ONBOOT=1
ASSUME_YES=0
RESET_PASS=0
MODE="install"
# Roh-URL des Installers (für Reinstall-Hinweise in der Fehlerkette)
ONE_LINER="https://raw.githubusercontent.com/HatchetMan111/NexoPOS-KassenServer/main/install/nexopos.sh"

# Admin-/Store-Defaults (Konsistenz mit Inner-Script)
ADMIN_USER="admin"
ADMIN_EMAIL="admin@nexopos.local"
ADMIN_PASS=""
STORE_NAME="NexoPOS"

# Farben / Helper
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info()  { echo -e "${BLUE}ℹ${NC} $*"; }
ok()    { echo -e "${GREEN}✔${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
err()   { echo -e "${RED}✗${NC} $*" >&2; }
header(){ echo -e "\n${BOLD}=== $* ===${NC}"; }
die()   { err "$*"; exit 1; }

# Fehlerkette: vollständiger Kontext + bash -x-Angebot
on_error() {
  local ec=$1 line=$2
  echo -e "\n${RED}${BOLD}████████  INSTALLATION FEHLGESCHLAGEN  ████████${NC}" >&2
  err "Exit-Code : $ec"
  err "Befehl/Zeile: Zeile $line"
  err "Modus      : $MODE"
  [ -n "${CTID:-}" ] && err "CT-ID      : $CTID"
  echo -e "\n${YELLOW}--- Letzte 40 Zeilen Setup-Log (falls vorhanden) ---${NC}" >&2
  if [ -n "${SETUP_LOG:-}" ] && [ -f "${SETUP_LOG}" ]; then
    tail -n 40 "${SETUP_LOG}" >&2 || true
  else
    echo "(kein Setup-Log vorhanden)" >&2
  fi
  echo -e "\n${YELLOW}--- Diagnose-Hinweise ---${NC}" >&2
  echo "• Vollständiges Log mit Zeilennummern erneut erzeugen:" >&2
  echo "    bash -x \"\$0\" $* 2>&1 | tee /tmp/nexopos-install-debug.log" >&2
  echo "• Container-Status:  pct status ${CTID:-<id>} ; pct config ${CTID:-<id>}" >&2
  echo "• In-Container-Logs: pct exec ${CTID:-<id>} -- journalctl -u ${APP_NAME} -n 80 --no-pager" >&2
  echo "${RED}████████████████████████████████████████████${NC}" >&2
}
trap 'on_error $? $LINENO' ERR

# ---------- Argumente --------------------------------------------------------
# Grube: bash -c "$(wget -qLO - URL)" belegt $0 mit dem ersten Arg → Fallback
if [[ "${0}" == -* ]]; then set -- "${0}" "$@"; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update)     MODE="update"; shift ;;
    --uninstall)  MODE="uninstall"; shift ;;
    --status)     MODE="status"; shift ;;
    --id)         CTID="$2"; shift 2 ;;
    --ram)        CT_RAM="$2"; shift 2 ;;
    --disk)       CT_DISK="$2"; shift 2 ;;
    --cores)      CT_CORES="$2"; shift 2 ;;
    --hostname)   CT_HOSTNAME="$2"; shift 2 ;;
    --port)       APP_PORT="$2"; shift 2 ;;
    --bridge)     CT_BRIDGE="$2"; shift 2 ;;
    --storage)    CT_STORAGE="$2"; shift 2 ;;
    --admin-user)  ADMIN_USER="$2"; shift 2 ;;
    --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-pass)  ADMIN_PASS="$2"; shift 2 ;;
    --store-name)  STORE_NAME="$2"; shift 2 ;;
    --reset-pass) RESET_PASS=1; shift ;;   # Admin-Passwort auf --admin-pass setzen
    --yes|-y)     ASSUME_YES=1; shift ;;
    --)           shift ;;   # Standard-Trenner: "bash -c ... -- --update" belegt $0 mit "--"
    -h|--help)    sed -n '2,42p' "$0"; exit 0 ;;
    *)            die "Unbekannte Option: $1 (siehe --help)" ;;
  esac
done

# ---------- Root-Prüfung -----------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  die "Dieses Script muss als root auf dem Proxmox-Host laufen (sudo -i)."
fi
command -v pct >/dev/null 2>&1 || die "pct nicht gefunden – läuft das hier auf einem Proxmox-Host?"
command -v wget >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq wget ca-certificates; }

# ns:setup wird INTERAKTIV (ask()), wenn ein Pflichtwert fehlt – im pct exec ohne
# TTY endet das still als "installation aborted". Daher immer ein Passwort setzen.
if [ -z "${ADMIN_PASS:-}" ]; then
  ADMIN_PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16)"
  GENERATED_PASS=1
else
  GENERATED_PASS=0
fi

SETUP_LOG="/tmp/${APP_NAME}-setup.log"

# ---------- CT-Helfer --------------------------------------------------------
find_free_id() {
  local id
  id="$(pvesh get /cluster/nextid 2>/dev/null | tr -d '[:space:]')"
  if [[ "$id" =~ ^[0-9]+$ ]]; then echo "$id"; return 0; fi
  # Fallback: höchste ID + 1
  local max=100
  while read -r v _; do [[ "$v" =~ ^[0-9]+$ ]] && (( v > max )) && max=$v; done < <(pct list)
  echo $((max + 1))
}

# Grube 13/27: Name ist IMMER das letzte Feld; Fallback über pct config
find_ct_id_by_hostname() {
  local name="$1" id
  if [[ -n "${CTID:-}" ]]; then echo "$CTID"; return 0; fi
  while read -r id _; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    if pct config "$id" 2>/dev/null | grep -q "^hostname: ${name}$"; then echo "$id"; return 0; fi
  done < <(pct list)
  return 1
}

# Host-Arch → Template-Arch (Grube 31a: arm64-vor-amd64-Falle)
host_arch() {
  local a; a="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "$a" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo "$a" ;;
  esac
}

# Arch-bewusste Template-Wahl + Download (Grube 31a/31)
prepare_template() {
  local arch; arch="$(host_arch)"
  info "Host-Architektur: $arch"
  # Vorhandene Templates im lokalen Speicher
  local avail; avail="$(pveam list local 2>/dev/null | awk '{print $1}' | sed 's|.*/||' || true)"
  CT_TEMPLATE="$(echo "$avail" | grep -oE "debian-1[23]-standard[^\ ]*_${arch}\.tar\.(zst|gz)" | sort -rV | head -1 || true)"
  if [ -z "$CT_TEMPLATE" ]; then
    info "Kein passendes Debian-Template lokal – lade debian-12-standard (${arch}) ..."
    pveam update >/dev/null 2>&1 || true
    local avail_list; avail_list="$(pveam available 2>/dev/null | awk '{print $2}' | sed 's|.*/||' || true)"
    # Glob: Versionsteile zwischen "debian-12-standard" und "_<arch>" erlauben
    CT_TEMPLATE="$(echo "$avail_list" | grep -oE "debian-12-standard[^\ ]*_${arch}\.tar\.(zst|gz)" | sort -rV | head -1 || true)"
    [ -n "$CT_TEMPLATE" ] || die "Kein debian-12-standard-Template (${arch}) in pveam available gefunden."
    pveam download local "$CT_TEMPLATE" >/dev/null 2>&1 || die "Template-Download fehlgeschlagen: $CT_TEMPLATE"
  fi
  # Auf Template-Existenz prüfen (pct create akzeptiert fehlende ISOs still – Grube 5)
  local avail2; avail2="$(pveam list local 2>/dev/null | awk '{print $1}' | sed 's|.*/||' || true)"
  echo "$avail2" | grep -qF "$CT_TEMPLATE" || die "Template $CT_TEMPLATE nicht im lokalen Speicher."
  ok "Template: $CT_TEMPLATE"
}

wait_ct_network() {
  local id="$1" tries=60 ip
  for ((i=1; i<=tries; i++)); do
    ip="$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$ip" != 127.* ]]; then
      echo "$ip"; return 0
    fi
    sleep 2
  done
  return 1
}

# Grube 11/11a: DNS separat prüfen, 3 konsekutive Erfolge
verify_ct_dns() {
  local id="$1" host="${2:-deb.debian.org}" ok_count=0 i
  for i in 1 2 3 4 5 6; do
    if pct exec "$id" -- getent hosts "$host" >/dev/null 2>&1; then
      ok_count=$((ok_count + 1))
      [ "$ok_count" -ge 3 ] && return 0
    else
      ok_count=0
    fi
    sleep 2
  done
  warn "DNS im CT flaky – schreibe Fallback-Nameserver."
  local ns; ns="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)"
  pct exec "$id" -- bash -c "printf 'nameserver %s\nnameserver 1.1.1.1\nnameserver 8.8.8.8\n' '${ns:-192.168.178.1}' > /etc/resolv.conf" || true
  pct exec "$id" -- getent hosts "$host" >/dev/null 2>&1 || die "DNS im CT bleibt defekt (siehe Diagnose)."
  ok "DNS-Fallback aktiv."
}

verify_ct_started() {
  local id="$1" i
  for i in $(seq 1 15); do
    [ "$(pct status "$id" 2>/dev/null | awk '{print $2}')" = "running" ] && return 0
    sleep 2
  done
  err "CT $id ist nach 30 s nicht 'running' (Status: $(pct status "$id" 2>/dev/null))."
  err "Häufige Ursache: Template-Arch ≠ Host-Arch. Erzwinge Neu-Install:"
  echo "    pct destroy $id --purge && bash -c \"\$(wget -qLO - $ONE_LINER)\"" >&2
  die "verify_ct_started fehlgeschlagen."
}

# ---------- In-Container Setup-Script ----------------------------------------
render_inner_script() {
cat <<'INNEREOF'
#!/bin/bash
# NexoPOS In-Container Setup (wird via pct exec env ... bash /root/nx-inner.sh ausgeführt)
set -Eeuo pipefail
log(){ echo "[$(date '+%H:%M:%S')] $*"; }
err(){ echo "[FEHLER] $*" >&2; }
warn_inner(){ echo "[WARNUNG] $*" >&2; }
# apt mit hartem Zeitlimit: im Live-Lauf hing `apt-get install composer` stumm
# (zähes DNS im CT, kein Fortschritt sichtbar). Jetzt: Logdatei, Timeout,
# Lock-Timeout und bei Fehlschlag die letzten Zeilen im Klartext.
APT_LOG="/var/log/nexopos-apt.log"
: > "$APT_LOG" 2>/dev/null || true
apt_install() {
  local tag="$1"; shift
  log "apt: installiere ${tag} ..."
  if ! timeout 900 apt-get install -y -qq --no-install-recommends \
      -o DPkg::Lock::Timeout=120 \
      -o Acquire::http::Timeout=25 -o Acquire::https::Timeout=25 \
      -o Acquire::Retries=2 \
      "$@" >>"$APT_LOG" 2>&1; then
    warn_inner "apt-Install (${tag}) fehlgeschlagen oder Timeout – letzte Logzeilen:"
    tail -n 6 "$APT_LOG" >&2 || true
    return 1
  fi
  return 0
}
trap 'echo "[FEHLER] Exit $? in Zeile $LINENO" >&2' ERR

PORT="${PORT:-8080}"
APP_DIR="/opt/nexopos"
APP_NAME="${APP_NAME:-nexopos}"
APP_REPO="${APP_REPO:-https://github.com/Blair2004/NexoPOS.git}"
APP_BRANCH="${APP_BRANCH:-master}"
DB_NAME="nexopos"
DB_USER="nexopos"
DB_PASS="$(openssl rand -hex 16)"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@nexopos.local}"
ADMIN_PASS="${ADMIN_PASS:-}"
STORE_NAME="${STORE_NAME:-NexoPOS}"
RESET_PASS="${RESET_PASS:-0}"

log "=== Basis-Pakete ==="
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8 LC_ALL=C.UTF-8
# Live-Grube: der PATH von `pct exec` enthält /usr/local/bin nicht zwangsläufig –
# dadurch waren node/composer nach dem Symlink dorthin "command not found".
# PATH nur ERGÄNZEN (nie überschreiben): vorhandene Einträge bleiben vorn stehen.
for _p in /usr/local/sbin /usr/local/bin; do
  case ":${PATH:-}:" in
    *":$_p:"*) ;;
    *) export PATH="${PATH:-}${PATH:+:}$_p" ;;
  esac
done
log "apt: update ..."
timeout 300 apt-get update -qq \
  -o Acquire::http::Timeout=25 -o Acquire::https::Timeout=25 \
  -o Acquire::Retries=2 >>"$APT_LOG" 2>&1 || warn_inner "apt-get update mit Problemen (weiter)"
apt_install "basis-pakete" \
  curl wget ca-certificates gnupg lsb-release openssl \
  php-fpm php-cli php-mysql php-mbstring php-intl \
  php-curl php-gd php-zip php-bcmath php-xml \
  mariadb-server mariadb-client nginx \
  git unzip || { err "Basis-Pakete fehlen – Setup nicht möglich."; exit 1; }

log "=== Node.js (einmaliger Asset-Build) ==="
# Nur für den Vite-Build nötig, kein Laufzeitbedarf der App.
# Asset-Build verlangt Node >= 20.19 (Vite 6 / Tailwind 4).
# apt-first: das Debian-Paket ist baseline-kompatibel zur Host-CPU. Das
# nodejs.org-Binary setzt x86-64-v2 voraus und crasht auf älteren CPUs
# still (genau das passierte im Live-Lauf: /usr/local/bin/node vorhanden,
# `node -v` liefert nichts).
node_major() {
  command -v node >/dev/null 2>&1 || { echo 0; return 0; }
  node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1 | grep -E '^[0-9]+$' || echo 0
}
NODE_OK=0
[ "$(node_major)" -ge 20 ] && NODE_OK=1
if [ "$NODE_OK" -eq 0 ]; then
  apt_install "nodejs+npm" nodejs npm || true
  [ "$(node_major)" -ge 20 ] && NODE_OK=1
fi
if [ "$NODE_OK" -eq 0 ]; then
  log "apt-Node unbrauchbar – lade offizielles Binary v24.11.1 als Fallback ..."
  ARCH="$(dpkg --print-architecture)"
  case "$ARCH" in amd64) NARCH=x64;; arm64) NARCH=arm64;; *) NARCH=x64;; esac
  mkdir -p /opt/node24
  curl -fsSL --retry 3 --retry-delay 3 \
    --connect-timeout 20 --max-time 600 \
    "https://nodejs.org/dist/v24.11.1/node-v24.11.1-linux-${NARCH}.tar.xz" -o /tmp/node.tar.xz
  tar -xJf /tmp/node.tar.xz -C /opt/node24 --strip-components=1
  for b in node npm npx; do ln -sf "/opt/node24/bin/$b" "/usr/local/bin/$b"; done
  [ "$(node_major)" -ge 20 ] && NODE_OK=1
fi
if [ "$NODE_OK" -eq 0 ]; then
  err "Node.js ist nicht lauffähig (apt und Binary-Fallback scheiterten)."
  err "Diagnose: apt-get install -y nodejs npm ; node -v ; /opt/node24/bin/node -v"
  err "Auf alten CPUs crasht das offizielle Node-Binary (kein x86-64-v2)."
  exit 1
fi
log "node: $(node -v)  npm: $(npm -v 2>/dev/null || echo fehlt)"

log "=== PHP-FPM ==="
# Debian 12 liefert PHP 8.2, Debian 13 liefert 8.4 – Laravel 12 verlangt >= 8.2,
# beide genügen. Deshalb Meta-Pakete + dynamischer Dienst-/Socket-Name
# (kein Sury-Repo nötig; php8.4-* existiert auf Debian 12 NICHT).
php -v 2>/dev/null | head -1 || true
FPM_SVC="$(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}' | head -1 || true)"
[ -n "$FPM_SVC" ] || FPM_SVC="php-fpm"
systemctl enable "$FPM_SVC" >/dev/null 2>&1 || true
systemctl start "$FPM_SVC" || true
PHP_SOCK=""
for _i in $(seq 1 15); do
  PHP_SOCK="$(ls /run/php/php*-fpm.sock 2>/dev/null | head -1 || true)"
  [ -n "$PHP_SOCK" ] && break
  sleep 1
done
if [ -z "$PHP_SOCK" ]; then
  PHP_SOCK="/run/php/php$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo 8.2)-fpm.sock"
fi
log "PHP-FPM: ${FPM_SVC}  Socket: ${PHP_SOCK}"

log "=== MariaDB ==="
# Live-Grube 5: ein bei JEDEM Lauf neu generiertes DB_PASS wird per ALTER USER
# gesetzt, muss aber auch in der .env landen – schlägt das Schreiben fehl, ist der
# Zugriff sofort tot ("Access denied for user ''"). Daher: bestehendes Passwort
# aus der .env übernehmen, damit Updates idempotent sind.
if [ -f "$APP_DIR/.env" ]; then
  _existing_pass="$(sed -n 's/^DB_PASSWORD=//p' "$APP_DIR/.env" | head -1 | sed 's/^["'"'"']//; s/["'"'"']$//')"
  if [ -n "${_existing_pass:-}" ]; then
    DB_PASS="$_existing_pass"
    log "DB-Passwort aus bestehender .env übernommen (stabil bei Updates)."
  fi
fi
systemctl enable mariadb >/dev/null 2>&1 || true
systemctl start mariadb || true
# DB + Rolle anlegen (idempotent). Läuft als root im CT → kein sudo nötig.
mariadb -N -B -e "SELECT 1 FROM mysql.user WHERE user='${DB_USER}'" | grep -q 1 \
  || mariadb -e "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}'" >/dev/null
mariadb -N -B -e "SELECT 1 FROM information_schema.schemata WHERE schema_name='${DB_NAME}'" | grep -q 1 \
  || mariadb -e "CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci" >/dev/null
mariadb -e "ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}'; GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES" >/dev/null
log "MariaDB bereit (DB ${DB_NAME})."

log "=== App-Code klonen (${APP_REPO}) ==="
mkdir -p "$(dirname "$APP_DIR")"
if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" fetch --depth 1 origin "$APP_BRANCH" >/dev/null 2>&1 || true
  git -C "$APP_DIR" reset --hard "origin/$APP_BRANCH" >/dev/null 2>&1 || true
else
  rm -rf "$APP_DIR"
  git clone --depth 1 -b "$APP_BRANCH" "$APP_REPO" "$APP_DIR" >/dev/null
fi
log "App bei $(git -C "$APP_DIR" rev-parse --short HEAD)"

log "=== Composer ==="
# Live-Grube 4: `composer --version` HÄNGT als root stumm — Composer fragt
# "Continue as root/super user?", die Frage geht nach stderr (unterdrückt) und
# stdout ist von $(…) geschluckt → unsichtbares Warten auf Eingabe.
# Daher: ALLE composer-Aufrufe mit COMPOSER_ALLOW_SUPERUSER=1, --no-interaction
# und timeout; unbrauchbare Installationen werden erkannt und ersetzt.
composer_ok() {
  timeout 60 env COMPOSER_ALLOW_SUPERUSER=1 composer --version \
    --no-interaction >/dev/null 2>&1
}
if command -v composer >/dev/null 2>&1 && ! composer_ok; then
  warn_inner "vorhandener Composer unbrauchbar: $(command -v composer) – wird ersetzt."
  rm -f "$(command -v composer)" 2>/dev/null || true
fi
if ! command -v composer >/dev/null 2>&1; then
  apt_install "composer+unzip" composer unzip || true
fi
if ! composer_ok; then
  log "apt-Composer nicht verfügbar – nutze offiziellen Installer ..."
  EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");' 2>/dev/null || true)"
  php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" 2>/dev/null || true
  if [ -f composer-setup.php ]; then
    ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');" 2>/dev/null || true)"
    if [ -n "$EXPECTED_CHECKSUM" ] && [ -n "$ACTUAL_CHECKSUM" ] && [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
      err "Composer-Installer-Checksumme ungültig – verwerfe Download."
      rm -f composer-setup.php
    else
      [ -n "$EXPECTED_CHECKSUM" ] || warn_inner "Signatur nicht abrufbar – prüfe Installer-Hash nicht."
      php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet || true
      rm -f composer-setup.php
    fi
  fi
fi
if ! composer_ok; then
  log "Letzter Fallback: composer-stable.phar direkt ..."
  curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 20 --max-time 300 \
    https://getcomposer.org/composer-stable.phar -o /usr/local/bin/composer.phar
  printf '#!/bin/sh\nCOMPOSER_ALLOW_SUPERUSER=1 exec php /usr/local/bin/composer.phar --no-interaction "$@"\n' > /usr/local/bin/composer
  chmod +x /usr/local/bin/composer /usr/local/bin/composer.phar
fi
if ! composer_ok; then
  err "Composer ist nicht lauffähig (apt, Installer und phar-Fallback scheiterten)."
  err "Diagnose: COMPOSER_ALLOW_SUPERUSER=1 composer --version ; php -v"
  exit 1
fi
log "composer: $(timeout 60 env COMPOSER_ALLOW_SUPERUSER=1 composer --version --no-interaction 2>/dev/null | head -1 || true)"
cd "$APP_DIR"
log "composer install (kann einige Minuten dauern) ..."
if ! timeout 1800 env COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_PROCESS_TIMEOUT=600 \
    composer install --no-dev --prefer-dist --no-interaction --no-progress \
    >>"$APT_LOG" 2>&1; then
  err "composer install fehlgeschlagen oder Timeout – letzte Logzeilen:"
  tail -n 15 "$APT_LOG" >&2 || true
  tail -n 15 "$APP_DIR/storage/logs/laravel.log" >&2 2>/dev/null || true
  exit 1
fi
log "composer install fertig."

log "=== .env schreiben ==="
if [ ! -f "$APP_DIR/.env" ]; then
  cp "$APP_DIR/.env.example" "$APP_DIR/.env"
fi
# Kernwerte setzen (idempotent, KEY bleibt bei Updates erhalten).
# Wichtig: die Werte werden als echte Env-Variablen übergeben – getenv() sieht
# Shell-Variablen sonst NICHT (Live-Grube: DB_USERNAME/DB_PASSWORD blieben leer).
NX_DB_NAME="$DB_NAME" NX_DB_USER="$DB_USER" NX_DB_PASS="$DB_PASS" \
NX_APP_URL="http://$(hostname -I 2>/dev/null | awk '{print $1}'):${PORT}" \
php -r '
$env = file_get_contents(".env");
$vals = [
  "APP_ENV" => "production",
  "APP_DEBUG" => "false",
  "APP_URL" => getenv("NX_APP_URL") ?: "http://127.0.0.1",
  "DB_CONNECTION" => "mysql",
  "DB_HOST" => "127.0.0.1",
  "DB_PORT" => "3306",
  "DB_DATABASE" => getenv("NX_DB_NAME"),
  "DB_USERNAME" => getenv("NX_DB_USER"),
  "DB_PASSWORD" => getenv("NX_DB_PASS"),
  // Upstream-Defaults (.env.example): file-Cache/Sessions, sync-Queue.
  // Treiber "database" erzeugt 500er ("Table sessions not found"), weil NexoPOS
  // diese Framework-Tabellen nicht migriert. Achtung: Apostrophe sind hier
  // verboten, sie beenden die Shell-Single-Quote-Kette von php -r.
  "QUEUE_CONNECTION" => "sync",
  "CACHE_STORE" => "file",
  "SESSION_DRIVER" => "file",
  "BROADCAST_CONNECTION" => "log",
];
foreach ($vals as $k => $v) {
  if ($v === "" || $v === false) continue;
  $line = $k . "=" . $v;
  if (preg_match("/^" . preg_quote($k, "/") . "=/m", $env)) {
    $env = preg_replace("/^" . preg_quote($k, "/") . "=.*$/m", $line, $env);
  } else {
    $env .= PHP_EOL . $line;
  }
}
file_put_contents(".env", $env);
'
# Harte Prüfung: ohne die drei DB-Werte ist jeder artisan-Aufruf ein Access-Denied.
for _k in DB_DATABASE DB_USERNAME DB_PASSWORD; do
  _v="$(sed -n "s/^${_k}=//p" "$APP_DIR/.env" | head -1)"
  if [ -z "$_v" ]; then
    err ".env unvollständig: ${_k} ist leer (DB-Zugriff würde scheitern)."
    err "Zeilen: $(grep -cE '^DB_' "$APP_DIR/.env" 2>/dev/null || echo 0) DB_-Einträge, cwd=$(pwd)"
    exit 1
  fi
done
log ".env geschrieben (DB-Zugang gesetzt)."
php artisan key:generate --force >/dev/null
php artisan storage:link >/dev/null 2>&1 || true
php artisan config:clear >/dev/null 2>&1 || true

log "=== Frontend-Assets bauen ==="
log "npm install (Registry-Zugriff, kann dauern) ..."
if ! timeout 1800 npm install --no-audit --no-fund --fetch-timeout=60000 --fetch-retries=3 \
    >>"$APT_LOG" 2>&1; then
  warn_inner "npm install im ersten Versuch fehlgeschlagen – Wiederholung ohne Cache:"
  timeout 1800 npm install --no-audit --no-fund --fetch-timeout=60000 --fetch-retries=3 || {
    err "npm install fehlgeschlagen – letzte Logzeilen:"; tail -n 15 "$APT_LOG" >&2 || true; exit 1; }
fi
log "npm run build ..."
if ! timeout 900 npm run build >>"$APT_LOG" 2>&1; then
  err "npm run build fehlgeschlagen – letzte Logzeilen:"; tail -n 20 "$APT_LOG" >&2 || true; exit 1
fi
log "Assets gebaut: $(ls public/build 2>/dev/null | wc -l) Einträge"
if [ ! -f "public/build/manifest.json" ]; then
  err "Vite-Manifest fehlt (public/build/manifest.json) – Laravel würde mit 500 antworten."
  err "Inhalt von public/build: $(ls -A public/build 2>/dev/null | tr '\n' ' ')"
  exit 1
fi

log "=== NexoPOS Setup (CLI, headless) ==="
# ns:setup ist idempotent (Helper::installed() prüft nexopos_options-Tabelle).
# Ausgabe in eine Logdatei statt /dev/null: bei Fehlschlag sieht man die Ursache.
SETUP_CLI_LOG="/var/log/nexopos-setup-cli.log"
if ! timeout 1800 php artisan ns:setup \
    --store_name="$STORE_NAME" \
    --admin_username="$ADMIN_USER" \
    --admin_email="$ADMIN_EMAIL" \
    --admin_password="$ADMIN_PASS" \
    --language=de >>"$SETUP_CLI_LOG" 2>&1; then
  warn_inner "ns:setup im ersten Versuch fehlgeschlagen – wiederhole (Migrationen)."
  if ! timeout 1800 php artisan ns:setup \
      --store_name="$STORE_NAME" \
      --admin_username="$ADMIN_USER" \
      --admin_email="$ADMIN_EMAIL" \
      --admin_password="$ADMIN_PASS" \
      --language=de >>"$SETUP_CLI_LOG" 2>&1; then
    err "ns:setup fehlgeschlagen – letzte Zeilen:"
    tail -n 25 "$SETUP_CLI_LOG" >&2 || true
    exit 1
  fi
fi
# Harte Verifikation: existiert die Options-Tabelle? Sonst war ns:setup ein
# stiller No-Op (fehlende Pflichtwerte / interaktiver Abbruch) und die UI
# würde nur den Setup-Wizard zeigen.
if ! mariadb -N -B -e "SHOW TABLES FROM ${DB_NAME} LIKE 'nexopos_options'" 2>/dev/null | grep -q nexopos_options; then
  err "NexoPOS-Setup hat die Datenbank nicht initialisiert (Tabelle nexopos_options fehlt)."
  err "Diagnose: php artisan ns:setup --store_name=... --admin_username=... --admin_email=... --admin_password=..."
  exit 1
fi
log "Datenbank initialisiert (nexopos_options vorhanden)."

# ns:setup legt den Admin NUR beim ersten Lauf an. Bricht ein Lauf danach ab, ist
# das generierte Passwort verloren – daher zusätzlich im CT ablegen (root, 0600).
printf '%s\n' "$ADMIN_PASS" > /root/nexopos-admin-pass.txt 2>/dev/null || true
chmod 600 /root/nexopos-admin-pass.txt 2>/dev/null || true

# --reset-pass: Passwort auch bei bestehender Installation setzen.
if [ "$RESET_PASS" = "1" ]; then
  log "Setze Admin-Passwort fuer '${ADMIN_USER}' zurueck ..."
  _out="$(timeout 300 php artisan tinker --execute="\$u = App\\Models\\User::where('username', '${ADMIN_USER}')->first(); if (! \$u) { echo 'NO_USER'; exit(3); } \$u->password = Illuminate\\Support\\Facades\\Hash::make('${ADMIN_PASS}'); \$u->save(); echo 'PASS_SET';" 2>&1 || true)"
  if printf '%s' "$_out" | grep -q PASS_SET; then
    log "Admin-Passwort gesetzt."
  elif printf '%s' "$_out" | grep -q NO_USER; then
    err "Admin-Benutzer '${ADMIN_USER}' existiert nicht – nutze --admin-user."
    err "Ausgabe: $(printf '%s' "$_out" | tail -3)"
    exit 1
  else
    err "Passwort-Reset fehlgeschlagen. Ausgabe:"
    printf '%s\n' "$_out" | tail -8 >&2
    exit 1
  fi
fi

# Store-Namen setzt ns:setup NICHT (Bekannt: Option nur Default) → nachziehen
php artisan tinker --execute="ns()->option->set('ns_store_name', '${STORE_NAME}');" >/dev/null 2>&1 || true
php artisan config:clear >/dev/null 2>&1 || true

log "=== Verzeichnisse + Rechte ==="
id www-data >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin www-data
chown -R www-data:www-data "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" 2>/dev/null || true
chmod -R ug+rwX "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" 2>/dev/null || true

log "=== Nginx ==="
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
cat > /etc/nginx/sites-available/nexopos <<NGINXEOF
server {
    listen ${PORT} default_server;
    listen [::]:${PORT} default_server;
    server_name _;
    root ${APP_DIR}/public;
    index index.php;

    client_max_body_size 64M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
NGINXEOF
ln -sf /etc/nginx/sites-available/nexopos /etc/nginx/sites-enabled/nexopos
rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx

log "=== systemd: Scheduler (Cron) + Queue-Worker ==="
cat > "/etc/systemd/system/${APP_NAME}-scheduler.service" <<UNITEOF
[Unit]
Description=NexoPOS Scheduler (Laravel Cron)
After=network-online.target mariadb.service
Wants=network-online.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/php ${APP_DIR}/artisan schedule:work
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF
cat > "/etc/systemd/system/${APP_NAME}-queue.service" <<UNITEOF
[Unit]
Description=NexoPOS Queue Worker
After=network-online.target mariadb.service
Wants=network-online.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/php ${APP_DIR}/artisan queue:work --tries=3 --sleep=3
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF
systemctl daemon-reload
systemctl enable "${APP_NAME}-scheduler" >/dev/null 2>&1 || true
systemctl enable "${APP_NAME}-queue" >/dev/null 2>&1 || true
systemctl restart "${APP_NAME}-scheduler" "${APP_NAME}-queue" || true

log "=== Health-Poll ==="
for i in $(seq 1 45); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -L "http://127.0.0.1:${PORT}/" || true)"
  if [ "$code" = "200" ] || [ "$code" = "302" ]; then log "HTTP / = ${code}"; break; fi
  if [ "$i" = "45" ]; then
    err "App wurde nicht erreichbar (letzter Code: ${code:-000})"
    echo "--- Laravel-Log (letzte 30 Zeilen) ---" >&2
    tail -n 30 "$APP_DIR/storage/logs/laravel.log" >&2 2>/dev/null || echo "(kein laravel.log)" >&2
    echo "--- Rechte storage/bootstrap-cache ---" >&2
    ls -ld "$APP_DIR/storage" "$APP_DIR/storage/logs" "$APP_DIR/bootstrap/cache" >&2 2>/dev/null || true
    echo "--- nginx error.log ---" >&2; tail -n 15 /var/log/nginx/error.log >&2 2>/dev/null || true
    exit 1
  fi
  sleep 2
done
log "=== Setup abgeschlossen (Port ${PORT}) ==="
INNEREOF
}

# ---------- Modi -------------------------------------------------------------
do_install() {
  header "NexoPOS – Neu-Installation"
  [ -z "$CTID" ] && CTID="$(find_free_id)"
  info "CT-ID: $CTID  Hostname: $CT_HOSTNAME  RAM: ${CT_RAM}MB  Disk: ${CT_DISK}GB  Cores: $CT_CORES"
  if [ "$ASSUME_YES" -eq 0 ]; then
    read -r -p "So fortfahren? [j/N] " ans; [[ "$ans" =~ ^[jJ]$ ]] || die "Abgebrochen."
  fi

  prepare_template

  header "Erstelle Container $CTID"
  pct create "$CTID" "local:vztmpl/${CT_TEMPLATE}" \
    --hostname "$CT_HOSTNAME" --cores "$CT_CORES" --memory "$CT_RAM" \
    --rootfs "${CT_STORAGE}:${CT_DISK}" --net0 "name=eth0,bridge=${CT_BRIDGE},ip=dhcp" \
    --unprivileged "$CT_UNPRIVILEGED" --features nesting=1 --onboot "$CT_ONBOOT" \
    --ostype debian --start 0
  pct start "$CTID" || die "pct start fehlgeschlagen (siehe pct config $CTID)."
  # Grube 31a: create/start kann Exit 0 trotz fehlgeschlagenem Spawn liefern → Status-Poll
  if ! verify_ct_started "$CTID"; then
    err "pct start meldete Erfolg, aber der Container läuft nicht (häufig: Template-Arch ≠ Host-Arch)."
    echo "    pct destroy $CTID --purge && bash -c \"\$(wget -qLO - $ONE_LINER)\"" >&2
    exit 1
  fi
  pct set "$CTID" --onboot "$CT_ONBOOT" >/dev/null 2>&1 || true
  ok "Container läuft."

  local ip; ip="$(wait_ct_network "$CTID")" || die "CT bekam keine IP (DHCP? Bridge $CT_BRIDGE?)."
  ok "CT-IP: $ip"
  if ! verify_ct_dns "$CTID"; then die "DNS im CT defekt (siehe Diagnose)."; fi

  header "In-Container Setup (dauert einige Minuten)"
  render_inner_script > /tmp/nx-inner.sh
  pct push "$CTID" /tmp/nx-inner.sh /root/nx-inner.sh >/dev/null
  # Grube 14: pipefail im Inner, damit pct exit-code nicht von tee verschluckt wird.
  # Wichtig: unter set -e bricht ein fehlgeschlagenes pct exec SOFORT ab (rc=$?
  # wäre toter Code) → if ! … dann klare Meldung + Log-Auszug.
  if ! pct exec "$CTID" -- env PORT="$APP_PORT" APP_NAME="$APP_NAME" APP_REPO="$APP_REPO" \
    APP_BRANCH="master" ADMIN_USER="$ADMIN_USER" ADMIN_EMAIL="$ADMIN_EMAIL" \
    ADMIN_PASS="$ADMIN_PASS" STORE_NAME="$STORE_NAME" RESET_PASS="$RESET_PASS" \
    bash -c 'set -o pipefail; bash /root/nx-inner.sh 2>&1 | tee /var/log/nexopos-setup.log'; then
    SETUP_LOG=/tmp/${APP_NAME}-ct-setup.log
    pct exec "$CTID" -- cat /var/log/nexopos-setup.log > "$SETUP_LOG" 2>/dev/null || true
    err "--- Letzte 30 Zeilen In-Container-Log ---"
    tail -n 30 "$SETUP_LOG" >&2 2>/dev/null || true
    die "In-Container Setup fehlgeschlagen."
  fi
  pct exec "$CTID" -- rm -f /root/nx-inner.sh >/dev/null 2>&1 || true

  header "Verifikation"
  local svc http
  svc="$(pct exec "$CTID" -- systemctl is-active nginx 2>/dev/null || true)"
  [ "$svc" = "active" ] && ok "systemctl is-active nginx: active" || die "nginx nicht active (Status: ${svc:-unbekannt})."
  http="$(pct exec "$CTID" -- curl -s -o /dev/null -w '%{http_code}' -L "http://127.0.0.1:${APP_PORT}/" || true)"
  { [ "$http" = "200" ] || [ "$http" = "302" ]; } && ok "HTTP / = $http" || die "Web-UI antwortet nicht (HTTP ${http:-000})."

  summary "$ip"
}

do_update() {
  header "NexoPOS – Update"
  local id; id="$(find_ct_id_by_hostname "$CT_HOSTNAME")" || die "Kein laufender CT '$CT_HOSTNAME' gefunden. Nutze --id <N>."
  CTID="$id"
  ensure_ct_running "$CTID"
  local ip; ip="$(get_ct_ip "$CTID")" || die "Keine IP für CT $CTID."
  verify_ct_dns "$CTID" || true
  info "Update auf CT $CTID ($ip) ..."
  # Bestimmtes Admin-Passwort beim Update nicht überschreiben (ns:setup ist
  # idempotent, aber wir wollen das gesetzte Passwort nicht ändern) → leer lassen
  render_inner_script > /tmp/nx-inner.sh
  pct push "$CTID" /tmp/nx-inner.sh /root/nx-inner.sh >/dev/null
  if ! pct exec "$CTID" -- env PORT="$APP_PORT" APP_NAME="$APP_NAME" APP_REPO="$APP_REPO" \
    APP_BRANCH="master" ADMIN_USER="$ADMIN_USER" ADMIN_EMAIL="$ADMIN_EMAIL" \
    ADMIN_PASS="${ADMIN_PASS:-}" STORE_NAME="$STORE_NAME" RESET_PASS="$RESET_PASS" \
    bash -c 'set -o pipefail; bash /root/nx-inner.sh 2>&1 | tee /var/log/nexopos-setup.log'; then
    SETUP_LOG=/tmp/${APP_NAME}-ct-setup.log
    pct exec "$CTID" -- cat /var/log/nexopos-setup.log > "$SETUP_LOG" 2>/dev/null || true
    err "--- Letzte 30 Zeilen In-Container-Log ---"
    tail -n 30 "$SETUP_LOG" >&2 2>/dev/null || true
    die "In-Container Setup (Update) fehlgeschlagen."
  fi
  pct exec "$CTID" -- rm -f /root/nx-inner.sh >/dev/null 2>&1 || true
  local svc; svc="$(pct exec "$CTID" -- systemctl is-active nginx 2>/dev/null || true)"
  [ "$svc" = "active" ] && ok "nginx active" || die "nginx nach Update nicht active."
  summary "$ip"
}

do_uninstall() {
  header "NexoPOS – Deinstallieren"
  local id; id="$(find_ct_id_by_hostname "$CT_HOSTNAME" || true)"
  [ -z "$id" ] && [ -n "${CTID:-}" ] && id="$CTID"
  [ -z "$id" ] && { warn "Kein CT '$CT_HOSTNAME' gefunden – nichts zu tun."; return 0; }
  warn "Container $id wird ZERSTÖRT (alle Daten gehen verloren)."
  if [ "$ASSUME_YES" -eq 0 ]; then read -r -p "Wirklich löschen? [j/N] " a; [[ "$a" =~ ^[jJ]$ ]] || die "Abgebrochen."; fi
  pct stop "$id" >/dev/null 2>&1 || true
  pct destroy "$id" || die "pct destroy fehlgeschlagen."
  ok "Container $id entfernt."
}

do_status() {
  local id; id="$(find_ct_id_by_hostname "$CT_HOSTNAME" || true)"
  [ -z "$id" ] && [ -n "${CTID:-}" ] && id="$CTID"
  [ -z "$id" ] && die "Kein CT gefunden. Nutze --id <N>."
  local st ip svc http
  st="$(pct status "$id" 2>/dev/null | awk '{print $2}')"
  ip="$(get_ct_ip "$id" || true)"
  echo "CT $id ($CT_HOSTNAME): ${st:-unbekannt}  IP: ${ip:-–}"
  if [ "$st" = "running" ]; then
    svc="$(pct exec "$id" -- systemctl is-active nginx 2>/dev/null || true)"
    http="$(pct exec "$id" -- curl -s -o /dev/null -w '%{http_code}' -L "http://127.0.0.1:${APP_PORT}/" 2>/dev/null || true)"
    echo "  nginx=${svc:-?}  http=${http:-?}"
    [ "${http:-000}" = "200" ] || [ "${http:-000}" = "302" ] && echo "  URL: http://${ip}:${APP_PORT}"
  fi
}

ensure_ct_running() {
  local id="$1"
  if [ "$(pct status "$id" 2>/dev/null | awk '{print $2}')" != "running" ]; then
    info "CT $id ist gestoppt – starte ihn."
    pct start "$id" || die "pct start $id fehlgeschlagen."
    wait_ct_network "$id" >/dev/null || die "CT $id bekam nach Start keine IP."
  fi
}

get_ct_ip() { wait_ct_network "$1"; }

summary() {
  local ip="$1"
  echo -e "\n${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║  ${APP_TITLE} ist installiert und läuft!                  ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
  echo -e "  🆔 CT-ID     : ${CTID}"
  echo -e "  🌐 URL       : ${BLUE}http://${ip}:${APP_PORT}${NC}"
  if [ "$MODE" = "install" ] || [ "${RESET_PASS:-0}" -eq 1 ]; then
    if [ "${GENERATED_PASS:-0}" -eq 1 ]; then
      echo -e "  🔑 Login     : Benutzer ${ADMIN_USER} / Passwort ${ADMIN_PASS}  (generiert)"
    else
      echo -e "  🔑 Login     : Benutzer ${ADMIN_USER} / Passwort ${ADMIN_PASS}"
    fi
    echo -e "     🌐 Dashboard : ${BLUE}http://${ip}:${APP_PORT}/dashboard${NC}"
  else
    echo -e "  🔑 Login     : Benutzer ${ADMIN_USER} (Passwort unverändert)"
    echo -e "     ↳ Passwort setzen: ... -- --update --reset-pass"
  fi
  echo -e "     📄 Passwort-Datei im CT: /root/nexopos-admin-pass.txt"
  echo -e "  📜 Logs      : pct exec ${CTID} -- journalctl -u ${APP_NAME}-queue -n 50 --no-pager"
  echo -e "  ♻️  Update    : bash -c \"\$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/NexoPOS-KassenServer/main/install/nexopos.sh)\" -- --update"
  echo -e "  🗑️  Deinstall: ... -- --uninstall"
  echo -e "  🔄 Reboot-Test: pct reboot ${CTID}  (danach ist die App via systemd wieder da)"
  echo ""
}

case "$MODE" in
  install)   do_install ;;
  update)    do_update ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
  *)         die "Unbekannter Modus: $MODE" ;;
esac