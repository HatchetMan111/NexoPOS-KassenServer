#!/usr/bin/env bash
# =============================================================================
#  🧪 NexoPOS-Proxmox – Mock-Harness
#  Testet install/nexopos.sh End-to-End gegen gemockte Proxmox-Umgebung:
#   - `unshare -rm` mappt den Harness-User auf root (EUID-Prüfung des Scripts)
#   - pct/pveam/wget/curl/sleep als Host-Mocks (Fakebin)
#   - Inner-Mocks: apt-get, systemctl, mariadb, php, composer, node/npm, git,
#     nginx … (Inner-Script läuft ECHT, Pfade auf Mock-Root umgeschrieben)
#  Usage: bash harness/run.sh [-v]   (Exit 0 = alle Cases grün)
# =============================================================================
set -u
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install/nexopos.sh"
[[ -f "$SCRIPT" ]] || { echo "✘ Installer nicht gefunden: $SCRIPT"; exit 1; }

MK=$(mktemp -d /tmp/nexopos-harness.XXXXXX)
chmod 755 "$MK"   # uid 0 im unshare-Namespace braucht Schreibrecht auf MK
KEEP="${HARNESS_KEEP:-0}"
trap 'if [[ "$KEEP" == "1" ]]; then echo "(Behalten: $MK)"; else rm -rf "$MK"; fi' EXIT
HS="$MK/state"
HOSTBIN="$MK/bin-host"
INNERBIN="$MK/bin-inner"
CASES="$MK/cases"; mkdir -p "$HS" "$HOSTBIN" "$INNERBIN" "$CASES" \
    "$MK/etc" "$MK/opt" "$MK/root" "$MK/var/log" "$MK/tmp"
CT_IP="10.120.5.88"

PASSED=0; FAILED=0; CUR_NAME=""; CUR_DIR=""

pass() { PASSED=$((PASSED+1)); echo "  ✔ $CUR_NAME – $1"; }
fail() { FAILED=$((FAILED+1)); echo "  ✘ $CUR_NAME – $1"; [[ -n "${2:-}" ]] && echo "      ↳ $2"; }
t()    { CUR_NAME="$1"; CUR_DIR=$(mktemp -d "$CASES/case.XXXXXX"); }

assert_exit() {
    local want="$1" got="$2"
    if [[ "$got" == "$want" ]]; then pass "exit=$got (erwartet $want)"
    else fail "exit=$got, erwartet $want"; fi
}
assert_out() {
    if /bin/grep -qF -- "$1" "$CUR_DIR/out.log" 2>/dev/null; then pass "Ausgabe enthält: $1"
    else fail "Ausgabe enthält NICHT: $1"; fi
}
assert_no_out() {
    if /bin/grep -qF -- "$1" "$CUR_DIR/out.log" 2>/dev/null; then fail "Ausgabe enthält (sollte nicht): $1"
    else pass "Ausgabe enthält nicht: $1"; fi
}
assert_file() {
    if [[ -e "$1" ]]; then pass "existiert: ${1#"$MK"/}"
    else fail "fehlt: ${1#"$MK"/}"; fi
}
assert_no_file() {
    if [[ -e "$1" ]]; then fail "Datei existiert (sollte nicht): ${1#"$MK"/}"
    else pass "Datei fehlt (korrekt): ${1#"$MK"/}"; fi
}
assert_fcontains() {
    if [[ -f "$1" ]] && /bin/grep -qF -- "$2" "$1"; then pass "${1#"$MK"/} enthält: $2"
    else fail "${1#"$MK"/} enthält NICHT: $2"; fi
}
assert_fregex() {
    if [[ -f "$1" ]] && /bin/grep -qE -- "$2" "$1"; then pass "${1#"$MK"/} matcht: $2"
    else fail "${1#"$MK"/} matcht NICHT: $2"; fi
}
assert_calls() { # ≥COUNT needle im Mock-Calls-Log
    local want="$1" needle="$2" got
    got=$(/bin/grep -cF -- "$needle" "$HS/calls.log" 2>/dev/null || true)
    if [[ "$got" -ge "$want" ]]; then pass "Calls ≥$want: $needle (ist $got)"
    else fail "Calls <$want: $needle (ist $got)"; fi
}
assert_no_calls() {
    if /bin/grep -qF -- "$1" "$HS/calls.log" 2>/dev/null; then fail "Unerwarteter Call: $1"
    else pass "Kein Call: $1"; fi
}
dump_case() {
    echo "---- out.log ($CUR_NAME) ----"; tail -n 60 "$CUR_DIR/out.log" 2>/dev/null
    echo "---- calls.log ----"; tail -n 30 "$HS/calls.log" 2>/dev/null
}

# ── Mock-Umgebung bauen (env -i: Profil-Funktionen wie grep→ugrep meiden) ──
realbin() { env -i /bin/sh -c "command -v $1" || { echo "✘ real binary fehlt: $1"; exit 1; }; }
link_real() {
    local dest="$1"; shift
    local b
    for b in "$@"; do ln -sf "$(realbin "$b")" "$dest/$b"; done
}
link_real "$HOSTBIN" bash sh env awk sed grep cut head tail tr od mktemp tee openssl \
    seq cat mv cp rm mkdir chmod dirname basename sort uniq readlink date printf ls touch \
    stat id du find tar hostname
ln -sf "$MK/mock-uname"  "$HOSTBIN/uname"
ln -sf "$MK/mock-wget"   "$HOSTBIN/wget"
ln -sf "$MK/mock-pct"    "$HOSTBIN/pct"
ln -sf "$MK/mock-pveam"  "$HOSTBIN/pveam"
ln -sf "$MK/mock-pvesh"  "$HOSTBIN/pvesh"
ln -sf "$MK/mock-sleep"  "$HOSTBIN/sleep"
ln -sf "$MK/mock-sleep"  "$INNERBIN/sleep"

# Inner-Fakebin: nacktes Debian simulieren (KEIN curl, KEIN node, KEIN php)
link_real "$INNERBIN" bash sh env awk sed grep cut head tail tr od seq cat mv cp rm \
    mkdir chmod dirname basename sort uniq printf ls touch readlink stat uname \
    tee openssl wc ln du find tar xargs gzip gunzip date install dpkg
ln -sf "$MK/mock-aptget"    "$INNERBIN/apt-get"
ln -sf "$MK/mock-systemctl" "$INNERBIN/systemctl"
ln -sf "$MK/mock-getent"    "$INNERBIN/getent"
ln -sf "$MK/mock-hostname"  "$INNERBIN/hostname"
ln -sf "$MK/mock-mariadb"   "$INNERBIN/mariadb"
ln -sf "$MK/mock-nginx"     "$INNERBIN/nginx"
ln -sf "$MK/mock-journalctl" "$INNERBIN/journalctl"

seed_inner_tools() { # simuliert bereits installierte Tools (Update-Pfad)
    ln -sf "$MK/mock-curl"     "$INNERBIN/curl"
    ln -sf "$MK/mock-php"      "$INNERBIN/php"
    ln -sf "$MK/mock-composer" "$INNERBIN/composer"
    ln -sf "$MK/mock-node"     "$INNERBIN/node"
    ln -sf "$MK/mock-npm"      "$INNERBIN/npm"
    ln -sf "$MK/mock-git"      "$INNERBIN/git"
    ln -sf "$MK/mock-id"       "$INNERBIN/id"
    ln -sf "$MK/mock-chown"    "$INNERBIN/chown"
    ln -sf "$MK/mock-useradd"  "$INNERBIN/useradd"
}
unseed_inner_tools() {
    rm -f "$INNERBIN/curl" "$INNERBIN/php" "$INNERBIN/composer" \
          "$INNERBIN/node" "$INNERBIN/npm" "$INNERBIN/npx" "$INNERBIN/git" \
          "$INNERBIN/id" "$INNERBIN/chown" "$INNERBIN/useradd"
}

# ══════════════════════════ Fixtures ══════════════════════════════════════
mk_fixtures() {
    local src="$MK/fixture-repo"
    rm -rf "$src"
    mkdir -p "$src/public" "$src/database/migrations" "$src/resources/js"
    printf '{\n  "name": "nexopos-fixture",\n  "scripts": {"build": "vite build"}\n}\n' > "$src/package.json"
    printf 'APP_NAME="NexoPOS"\nAPP_ENV=local\nAPP_KEY=\nAPP_DEBUG=true\nDB_CONNECTION=mysql\nDB_HOST=127.0.0.1\nDB_DATABASE=laravel\nDB_USERNAME=root\nDB_PASSWORD=\n' > "$src/.env.example"
    printf '<?php\n// fixture artisan\n' > "$src/artisan"
    printf 'body{}\n' > "$src/resources/js/app.js"
    printf '<?php\n// fixture migration\n' > "$src/database/migrations/2024_01_01_000000_create_nexopos_options.php"
}
mk_fixtures

# ══════════════════════════ Mock-Binaries ══════════════════════════════════
cat > "$MK/mock-sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$MK/mock-uname" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
arch="x86_64"
[[ -f "$HS/host_arch" ]] && arch=$(/bin/sed -n 's/^//p' "$HS/host_arch")
if [[ "${1:-}" == "-m" ]]; then echo "$arch"; exit 0; fi
echo "Linux harness 6.8.0 mock ${arch} GNU/Linux"
exit 0
EOF

cat > "$MK/mock-wget" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
echo "wget $*" >> "$HS/calls.log"
url="${*: -1}"
case "$url" in
    *install/nexopos.sh) /bin/cat "$HS/installer_src" 2>/dev/null || true ;;
    *) : ;;
esac
exit 0
EOF

cat > "$MK/mock-pvesh" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
echo "pvesh $*" >> "$HS/calls.log"
nid=$(cat "$HS/nextid" 2>/dev/null || echo 150)
echo "$nid"
exit 0
EOF

cat > "$MK/mock-pct" <<'EOF'
#!/usr/bin/env bash
# pct-Mock: State in $HARNESS_STATE, Mock-Root = dirname davon
set -u
HS="${HARNESS_STATE:?HARNESS_STATE fehlt}"
MK="${HS%/*}"
echo "pct $*" >> "$HS/calls.log"
cmd="${1:-}"
id="${2:-}"

case "$cmd" in
    list)
        printf 'VMID       Status     Lock Name\n'
        [[ -s "$HS/ct_list" ]] && cat "$HS/ct_list"
        exit 0 ;;
    status)
        f="$HS/ct_${id}.status"
        [[ -f "$f" ]] || exit 2
        echo "status: $(cat "$f")"; exit 0 ;;
    create)
        echo "pct create $*" >> "$HS/calls.log"
        if [[ -f "$HS/create_fail" ]]; then echo "mock: create fehlgeschlagen" >&2; exit 255; fi
        local_id="${2:-}"
        tmpl="${3:-}"
        tmpl_base="${tmpl##*/}"
        if [[ ! -f "$HS/templates/$tmpl_base" ]]; then
            echo "mock: Template $tmpl nicht vorhanden" >&2; exit 2
        fi
        { echo "TEMPLATE=$tmpl"; echo "ARGS=$*"; } > "$HS/ct_${local_id}.create"
        hostname="ct-$local_id"
        prev=""
        for a in "${@:4}"; do
            if [[ "$prev" == "--hostname" ]]; then hostname="$a"; fi
            prev="$a"
        done
        echo "$hostname" > "$HS/ct_${local_id}.hostname"
        if [[ -f "$HS/create_start_fail" ]]; then
            echo "$local_id stopped $hostname" >> "$HS/ct_list"
            echo "stopped" > "$HS/ct_${local_id}.status"
            exit 0
        fi
        echo "$local_id running $hostname" >> "$HS/ct_list"
        echo "running" > "$HS/ct_${local_id}.status"
        exit 0 ;;
    start)
        if [[ -f "$HS/start_fail" ]]; then echo "mock: Start fehlgeschlagen" >&2; exit 255; fi
        if [[ -f "$HS/create_start_fail" ]]; then
            echo "stopped" > "$HS/ct_${id}.status"
            /bin/sed -i "s|^$id .*|$id stopped $(cat "$HS/ct_${id}.hostname" 2>/dev/null || echo ct-$id)|" "$HS/ct_list"
            exit 0
        fi
        [[ -f "$HS/ct_${id}.status" ]] || { echo "mock: CT $id unbekannt" >&2; exit 2; }
        echo "running" > "$HS/ct_${id}.status"
        /bin/sed -i "s|^$id .*|$id running $(cat "$HS/ct_${id}.hostname" 2>/dev/null || echo ct-$id)|" "$HS/ct_list"
        exit 0 ;;
    stop)
        [[ -f "$HS/ct_${id}.status" ]] || { echo "mock: CT $id unbekannt" >&2; exit 2; }
        echo "stopped" > "$HS/ct_${id}.status"
        /bin/sed -i "s|^$id .*|$id stopped $(cat "$HS/ct_${id}.hostname" 2>/dev/null || echo ct-$id)|" "$HS/ct_list"
        exit 0 ;;
    destroy)
        /bin/sed -i "/^$id /d" "$HS/ct_list"
        rm -f "$HS/ct_${id}".status "$HS/ct_${id}".create "$HS/ct_${id}.hostname"
        exit 0 ;;
    push)
        src="${3:-}"; dst="${4:-}"
        mkdir -p "$MK$(dirname "$dst")"
        /bin/sed -e "s|/tmp/|$MK/tmp/|g" -e "s|/etc/|$MK/etc/|g" \
            -e "s|/usr/share|$MK/usr/share|g" -e "s|/usr/local|$MK/usr/local|g" \
            -e "s|/opt/nexopos|$MK/opt/nexopos|g" -e "s|/opt/node24|$MK/opt/node24|g" \
            -e "s|/var/log|$MK/var/log|g" -e "s|/run/php|$MK/run/php|g" \
            "$src" > "$MK$dst"
        chmod 755 "$MK$dst" 2>/dev/null || true
        echo "pct push $id $src $dst" >> "$HS/calls.log"
        exit 0 ;;
    exec)
        args=("${@:3}")
        if [[ "${args[0]:-}" == "--" ]]; then args=("${args[@]:1}"); fi
        envs=()
        if [[ "${args[0]:-}" == "env" ]]; then
            args=("${args[@]:1}")
            while [[ "${args[0]:-}" == *=* ]]; do envs+=("${args[0]}"); args=("${args[@]:1}"); done
        fi
        if [[ "${args[0]:-}" == "bash" && "${args[1]:-}" == "-c" ]]; then
            if [[ -f "$HS/exec_fail" ]]; then echo "mock: exec erzwingt Fehler" >&2; exit 255; fi
            if [[ ! -f "$HS/ct_${id}.status" || "$(cat "$HS/ct_${id}.status" 2>/dev/null)" != "running" ]]; then
                echo "mock: CT $id läuft nicht" >&2; exit 255
            fi
            INNERBIN="$MK/bin-inner"
            inner_cmd="${args[2]:-}"
            inner_cmd="${inner_cmd//\/usr\/share/$MK/usr/share}"
            inner_cmd="${inner_cmd//\/usr\/local/$MK/usr/local}"
            inner_cmd="${inner_cmd//\/root\//$MK/root/}"
            inner_cmd="${inner_cmd//\/var\/log/$MK/var/log}"
            inner_cmd="${inner_cmd//\/etc\//$MK/etc/}"
            inner_cmd="${inner_cmd//\/opt\/nexopos/$MK/opt/nexopos}"
            # /opt/node24 (Binary-Entpacken) → Mock-Root; /tmp → Mock-Root (Grube: /tmp zuerst)
            inner_cmd="${inner_cmd//\/opt\/node24/$MK/opt/node24}"
            echo "pct exec $id bash -c (inner)" >> "$HS/calls.log"
            exec env -i PATH="$INNERBIN:$MK/usr/local/bin:/usr/bin:/bin" \
                HARNESS_STATE="$HS" MKROOT="$MK" \
                HOME=/root TERM=dumb LANG=C.UTF-8 \
                ${envs[@]+"${envs[@]}"} \
                bash -c "$inner_cmd"
        fi
        if [[ -f "$HS/exec_fail" ]]; then echo "mock: exec erzwingt Fehler" >&2; exit 255; fi
        if [[ ! -f "$HS/ct_${id}.status" || "$(cat "$HS/ct_${id}.status" 2>/dev/null)" != "running" ]]; then
            echo "mock: CT $id läuft nicht" >&2
            echo "pct exec $id (ABGELEHNT – CT gestoppt)" >> "$HS/calls.log"
            exit 255
        fi
        INNERBIN="$MK/bin-inner"
        rewrite_path() {
            local a="$1"
            a="${a//\/opt\/nexopos/$MK/opt/nexopos}"
            a="${a//\/usr\/share/$MK/usr/share}"
            a="${a//\/usr\/local/$MK/usr/local}"
            a="${a//\/root\//$MK/root/}"
            a="${a//\/var\/log/$MK/var/log}"
            a="${a//\/etc\//$MK/etc/}"
            printf '%s' "$a"
        }
        newargs=()
        for a in "${args[@]}"; do newargs+=("$(rewrite_path "$a")"); done
        newenvs=()
        for a in ${envs[@]+"${envs[@]}"}; do newenvs+=("$(rewrite_path "$a")"); done
        exec env -i PATH="$INNERBIN:$MK/usr/local/bin:/usr/bin:/bin" \
            HARNESS_STATE="$HS" MKROOT="$MK" \
            HOME=/root TERM=dumb LANG=C.UTF-8 \
            ${newenvs[@]+"${newenvs[@]}"} \
            "${newargs[@]}"
        ;;
    config)
        if [[ ! -f "$HS/ct_${id}.hostname" ]]; then echo "mock: CT $id unbekannt" >&2; exit 2; fi
        printf 'arch: amd64\ncores: 2\nhostname: %s\nonboot: 1\nunprivileged: 1\nfeatures: nesting=1\n' "$(cat "$HS/ct_${id}.hostname")"
        exit 0 ;;
    set) exit 0 ;;
    enter|rollback|clone|resume|suspend|reboot|snapshot|delvolume|mount|resize|move|reindex)
        exit 0 ;;
    *)
        echo "mock-pct: unbekannter Befehl $cmd" >&2; exit 1 ;;
esac
EOF

cat > "$MK/mock-pveam" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
echo "pveam $*" >> "$HS/calls.log"
TMPL="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
TMPL_ARM="local:vztmpl/debian-12-standard_12.7-1_arm64.tar.zst"
have_arm() { [[ -f "$HS/arm64_only" || -f "$HS/arm64_too" ]]; }
case "${1:-}" in
    list)
        if [[ -f "$HS/template_downloaded" && ! -f "$HS/pveam_empty" ]]; then
            if [[ -f "$HS/arm64_only" ]]; then echo "$TMPL_ARM  999"; else echo "$TMPL  123456789"; fi
            have_arm && [[ ! -f "$HS/arm64_only" ]] && echo "$TMPL_ARM  999"
        fi
        exit 0 ;;
    available)
        if [[ ! -f "$HS/pveam_empty" ]]; then
            if [[ -f "$HS/arm64_only" ]]; then echo "system          $TMPL_ARM  999"; else echo "system          $TMPL  123456789"; fi
            have_arm && [[ ! -f "$HS/arm64_only" ]] && echo "system          $TMPL_ARM  999"
        fi
        exit 0 ;;
    update)   exit 0 ;;
    download)
        mkdir -p "$HS/templates"
        tname="${3##*/}"
        touch "$HS/templates/$tname"
        touch "$HS/template_downloaded"
        exit 0 ;;
esac
exit 0
EOF

cat > "$MK/mock-curl" <<'EOF'
#!/usr/bin/env bash
# curl-Mock: Download-Endpunkte → Erfolg; Health → 200/000 je nach Lever
set -u
HS="${HARNESS_STATE:?}"
url=""; prev=""
for a in "$@"; do
    case "$a" in http://*|https://*) url="$a" ;; esac
    prev="$a"
done
echo "curl $*" >> "$HS/calls.log" 2>/dev/null || true

case "$url" in
    http://127.0.0.1:*/*|http://localhost:*/*)
        code="200"
        if [[ -f "$HS/fail_health" ]]; then code="000"; fi
        echo "$code"; [[ "$code" == "200" ]] && exit 0 || exit 7 ;;
    */health*|*/up*)
        code="200"
        if [[ -f "$HS/fail_health" ]]; then code="000"; fi
        echo "$code"; [[ "$code" == "200" ]] && exit 0 || exit 7 ;;
esac
exit 0
EOF

cat > "$MK/mock-systemctl" <<'EOF'
#!/usr/bin/env bash
# systemctl-Mock (inner): nginx/scheduler/queue mit Active-Markern
set -u
HS="${HARNESS_STATE:?}"
MK="${HS%/*}"
echo "systemctl $*" >> "$HS/calls.log"
unitdir="$MK/etc/systemd/system"
case "${1:-}" in
    daemon-reload) exit 0 ;;
    list-unit-files)
        # php*-fpm.service-Ermittlung im Inner-Script
        echo "php8.4-fpm.service enabled"
        echo "nginx.service enabled"
        echo "mariadb.service enabled"
        exit 0 ;;
    enable) mkdir -p "$unitdir"; echo "${2:-}" >> "$HS/enabled_units"; exit 0 ;;
    start|restart)
        for u in "${@:2}"; do
            case "$u" in
                nginx|nexopos-scheduler|nexopos-queue|php8.4-fpm|mariadb)
                    [[ -f "$unitdir/$u.service" ]] || { echo "mock: unit $u fehlt" >&2; exit 1; }
                    touch "$HS/${u}_active" ;;
            esac
        done
        exit 0 ;;
    stop) for u in "${@:2}"; do rm -f "$HS/${u}_active"; done; exit 0 ;;
    is-active)
        svc="${2:-}"
        if [[ -f "$HS/${svc}_active" ]]; then echo "active"; exit 0; fi
        echo "inactive"; exit 3 ;;
    status) echo "mock: ${2:-} active-ish"; exit 0 ;;
    *) exit 0 ;;
esac
EOF

cat > "$MK/mock-aptget" <<'EOF'
#!/usr/bin/env bash
# apt-Mock: installiert curl/node/php/composer/git real in die Inner-Fakebin
set -u
HS="${HARNESS_STATE:?}"
MK="${HS%/*}"
INNERBIN_DIR="$MK/bin-inner"
echo "apt-get $*" >> "$HS/calls.log"
if [[ "${1:-}" == "install" ]]; then
    for a in "$@"; do
        case "$a" in
            curl)
                [[ -e "$INNERBIN_DIR/curl" ]] || ln -sf "$MK/mock-curl" "$INNERBIN_DIR/curl" ;;
            nodejs)
                [[ -e "$INNERBIN_DIR/node" ]] || ln -sf "$MK/mock-node" "$INNERBIN_DIR/node"
                [[ -e "$INNERBIN_DIR/npm" ]] || ln -sf "$MK/mock-npm" "$INNERBIN_DIR/npm" ;;
            git)
                [[ -e "$INNERBIN_DIR/git" ]] || ln -sf "$MK/mock-git" "$INNERBIN_DIR/git" ;;
            composer)
                [[ -e "$INNERBIN_DIR/composer" ]] || ln -sf "$MK/mock-composer" "$INNERBIN_DIR/composer" ;;
            nodejs|npm)
                [[ -e "$INNERBIN_DIR/node" ]] || ln -sf "$MK/mock-node" "$INNERBIN_DIR/node"
                [[ -e "$INNERBIN_DIR/npm" ]] || ln -sf "$MK/mock-npm" "$INNERBIN_DIR/npm" ;;
            php*)
                # Debian-Pakete php-fpm/php-cli bringen /usr/bin/php; composer/node/
                # curl/git sind nach dem Basis-apt da (realistischer apt-Zustand)
                for t in php curl git id chown useradd; do
                    [[ -e "$INNERBIN_DIR/$t" ]] || ln -sf "$MK/mock-$t" "$INNERBIN_DIR/$t"
                done
                mkdir -p "$MK/usr/local/bin"
                unitdir="$MK/etc/systemd/system"
                mkdir -p "$unitdir" "$MK/run/php"
                for u in nginx php8.4-fpm mariadb; do
                    [[ -f "$unitdir/$u.service" ]] || printf '[Unit]\nDescription=mock %s\n' "$u" > "$unitdir/$u.service"
                done
                # FPM-Socket, wie ihn das echte Paket anlegt
                : > "$MK/run/php/php8.4-fpm.sock" ;;
        esac
    done
fi
exit 0
EOF

cat > "$MK/mock-node" <<'EOF'
#!/usr/bin/env bash
echo "v24.11.1"
exit 0
EOF

cat > "$MK/mock-npm" <<'EOF'
#!/usr/bin/env bash
# npm-Mock: run build → legt public/build an
set -u
HS="${HARNESS_STATE:?}"
echo "npm $*" >> "$HS/calls.log"
if [[ "${1:-}" == "run" && "${2:-}" == "build" ]]; then
    mkdir -p public/build/assets
    echo "body{}" > public/build/assets/app.css
    echo "//bundle" > public/build/assets/app.js
fi
exit 0
EOF

cat > "$MK/mock-git" <<'EOF'
#!/usr/bin/env bash
# git-Mock: clone/fetch/reset → Fixture-Repo an Zielpfad kopieren
set -u
HS="${HARNESS_STATE:?}"
MK="${HS%/*}"
echo "git $*" >> "$HS/calls.log"
case "${1:-}" in
    clone)
        # git clone --depth 1 -b <branch> <repo> <dir> → dir ist letztes Arg
        dst="${*: -1}"
        [[ -n "$dst" ]] || exit 1
        mkdir -p "$dst"
        cp -a "$MK/fixture-repo/." "$dst/" 2>/dev/null || true
        mkdir -p "$dst/.git"
        echo "ref: refs/heads/master" > "$dst/.git/HEAD"
        echo "abc123def456" > "$dst/.git/HEAD.sha"
        exit 0 ;;
    -C)
        if [[ "${3:-}" == "rev-parse" ]]; then echo "abc123"; exit 0; fi
        exit 0 ;;
    fetch|reset) exit 0 ;;
esac
exit 0
EOF

cat > "$MK/mock-mariadb" <<'EOF'
#!/usr/bin/env bash
# mariadb-Mock: SELECT 1 → "0" (Rolle/DB fehlt noch), DDL → ok
set -u
HS="${HARNESS_STATE:?}"
echo "mariadb $*" >> "$HS/calls.log"
for a in "$@"; do
    case "$a" in
        *nexopos_options*)
            [[ -f "$HS/db_init_fail" ]] && exit 0   # leer = nicht initialisiert
            echo "1"; exit 0 ;;
        "SELECT 1"*) echo "0"; exit 0 ;;
    esac
done
exit 0
EOF

cat > "$MK/mock-nginx" <<'EOF'
#!/usr/bin/env bash
# nginx-Mock: -t → ok
set -u
HS="${HARNESS_STATE:?}"
echo "nginx $*" >> "$HS/calls.log"
exit 0
EOF

cat > "$MK/mock-php" <<'EOF'
#!/usr/bin/env bash
# php-Mock:
#  -r  mit "installer.sig"  → Checksumme ausgeben (Composer-Installer)
#  -r  mit "hash_file"      → dieselbe Checksumme (Verify-Pfad)
#  -r  mit ".env"/putenv    → .env im cwd schreiben (wie das echte Snippet)
#  -r  mit "copy("          → Zieldatei anlegen (composer-setup.php)
#  composer-setup.php …     → composer-Symlink installieren
#  artisan …                → key:generate/ns:setup (Installations-Marker)
set -u
HS="${HARNESS_STATE:?}"
MK="${HS%/*}"
echo "php $*" >> "$HS/calls.log"
arg="${*: -1}"

if [[ "${1:-}" == "artisan" ]]; then
    case "${2:-}" in
        ns:setup)    touch "$HS/ns_installed"; echo "NexoPOS setup done" ;;
        key:generate|storage:link|config:clear|tinker) : ;;
    esac
    exit 0
fi

if [[ "${1:-}" == "-r" || "${1:-}" == "-d" ]]; then
    case "$arg" in
        *installer.sig*)  echo "f00dfeedcafe" ;;
        *hash_file*)      echo "f00dfeedcafe" ;;
        *"putenv"*|*".env"*)
            # .env-Werte wie vom Installer-Snippet gesetzt
            {
              echo "APP_NAME=\"NexoPOS\""
              echo "APP_ENV=production"
              echo "APP_DEBUG=false"
              echo "APP_URL=http://127.0.0.1"
              echo "APP_KEY=base64:mockkey"
              echo "DB_CONNECTION=mysql"
              echo "DB_HOST=127.0.0.1"
              echo "DB_PORT=3306"
              echo "DB_DATABASE=nexopos"
              echo "DB_USERNAME=nexopos"
              echo "DB_PASSWORD=mockpass"
              echo "QUEUE_CONNECTION=database"
              echo "SESSION_DRIVER=database"
            } > .env
            ;;
        *"copy("*)  : > composer-setup.php ;;
    esac
    exit 0
fi

if [[ "${1:-}" == "-v" ]]; then echo "PHP 8.4.11 (cli) (mock)"; exit 0; fi

if [[ "${1:-}" == "composer-setup.php" ]]; then
    # --install-dir/--filename überspringen: composer in die Fakebin legen
    [[ -e "$MK/bin-inner/composer" ]] || ln -sf "$MK/mock-composer" "$MK/bin-inner/composer"
    exit 0
fi
exit 0
EOF

cat > "$MK/mock-composer" <<'EOF'
#!/usr/bin/env bash
# composer-Mock: install → ok
set -u
HS="${HARNESS_STATE:?}"
echo "composer $*" >> "$HS/calls.log"
exit 0
EOF

cat > "$MK/mock-getent" <<'EOF'
#!/usr/bin/env bash
# DNS-Mock: ok | fail | flaky | fail_then_ok
set -u
HS="${HARNESS_STATE:?}"
MK="${HS%/*}"
if [[ -f "$MK/etc/resolv.conf" ]] && /bin/grep -q 'nameserver 1.1.1.1' "$MK/etc/resolv.conf"; then
    exit 0
fi
mode="ok"
[[ -f "$HS/getent_mode" ]] && mode=$(/bin/sed -n 's/^getent_mode=//p' "$HS/getent_mode")
case "$mode" in
    ok) exit 0 ;;
    fail) exit 2 ;;
    flaky)
        n=$(cat "$HS/getent_count" 2>/dev/null || echo 0)
        n=$((n+1)); echo "$n" > "$HS/getent_count"
        if [[ $((n % 3)) -eq 0 ]]; then exit 2; fi
        exit 0 ;;
    fail_then_ok)
        n=$(cat "$HS/getent_count" 2>/dev/null || echo 0)
        n=$((n+1)); echo "$n" > "$HS/getent_count"
        [[ "$n" -le 6 ]] && exit 2
        exit 0 ;;
esac
exit 0
EOF

cat > "$MK/mock-hostname" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
if [[ -f "$HS/no_ip" ]]; then exit 0; fi
IP=$(cat "$HS/ct_ip" 2>/dev/null || echo "10.120.5.88")
if [[ "${1:-}" == "-I" ]]; then printf '%s 2601:db8::1 \n' "$IP"; exit 0; fi
echo "nexopos"; exit 0
EOF

cat > "$MK/mock-id" <<'EOF'
#!/usr/bin/env bash
# id-Mock: www-data existiert immer (id-Check im Inner)
if [[ "${1:-}" == "www-data" ]]; then echo "uid=33(www-data)"; exit 0; fi
exit 0
EOF

cat > "$MK/mock-chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$MK/mock-useradd" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$MK/mock-journalctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$MK"/mock-* "$MK"/bin-host/* "$MK"/bin-inner/* 2>/dev/null

# ── Runner ─────────────────────────────────────────────────────────────────
reset_state() {
    rm -rf "$HS" "${MK:?}/opt" "${MK:?}/etc" "${MK:?}/root" "${MK:?}/var/log" "${MK:?}/tmp" \
        "${MK:?}/usr" "${MK:?}/run"
    mkdir -p "$HS" "$HS/templates" "$MK/etc/systemd/system" "$MK/opt" "$MK/root" \
        "$MK/var/log" "$MK/tmp" "$MK/usr/share" "$MK/usr/local/bin" "$MK/run/php" \
        "$MK/etc/nginx/sites-available" "$MK/etc/nginx/sites-enabled"
    echo "$CT_IP" > "$HS/ct_ip"
    echo "150" > "$HS/nextid"
    : > "$HS/ct_list"
    echo "getent_mode=ok" > "$HS/getent_mode"
    cp "$SCRIPT" "$HS/installer_src"
    unseed_inner_tools
}
run_installer() {
    ( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
# shellcheck disable=SC2120
run_installer_nonroot() {
    ( env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
seed_ct() { # laufender CT mit installiertem NexoPOS-Stack
    reset_state
    echo "150 running nexopos" > "$HS/ct_list"
    echo "running" > "$HS/ct_150.status"
    echo "nexopos" > "$HS/ct_150.hostname"
    mkdir -p "$MK/opt/nexopos" "$MK/etc/systemd/system" "$MK/var/log" "$MK/run/php"
    touch "$MK/etc/systemd/system/nginx.service" "$HS/nginx_active"
    touch "$MK/etc/systemd/system/nexopos-scheduler.service" "$HS/nexopos-scheduler_active"
    touch "$MK/etc/systemd/system/nexopos-queue.service" "$HS/nexopos-queue_active"
    touch "$HS/ns_installed"
    seed_inner_tools
}

# ══════════════════════════ Cases ═════════════════════════════════════════
echo "🧪 NexoPOS-Installer-Harness gegen $SCRIPT"
echo

# ── Argumente & Modi ───────────────────────────────────────────────────────
t "root-check schlägt fehl (EUID≠0)"
ec=$(run_installer_nonroot)
assert_exit 1 "$ec"
assert_out "als root"

t "--help zeigt Optionen und Einzeiler"
ec=$(run_installer --help)
assert_exit 0 "$ec"
assert_out "--id"
assert_out "nexopos.sh"
assert_out "--update"

t "unbekannte Option → die()"
ec=$(run_installer --falsch)
assert_exit 1 "$ec"
assert_out "Unbekannte Option"

# ── Install: Happy Path ────────────────────────────────────────────────────
t "Install: Happy Path (nächste freie ID, Arch amd64)"
reset_state
ec=$(run_installer --yes --admin-pass TestPass123)
dump_case
assert_exit 0 "$ec"
assert_out "CT-ID: 150"
assert_out "Host-Architektur: amd64"
assert_out "Template: debian-12-standard_12.7-1_amd64.tar.zst"
assert_out "CT-IP: 10.120.5.88"
assert_out "systemctl is-active nginx: active"
assert_out "HTTP / = 200"
assert_out "http://10.120.5.88:8080"
assert_out "NexoPOS ist installiert"
assert_out "Benutzer admin / Passwort TestPass123"
assert_calls 1 "pvesh get /cluster/nextid"
assert_calls 1 "pct create 150"
assert_file "$MK/etc/systemd/system/nexopos-scheduler.service"
assert_fcontains "$MK/etc/systemd/system/nexopos-scheduler.service" "schedule:work"
assert_file "$MK/etc/systemd/system/nexopos-queue.service"
assert_fcontains "$MK/etc/systemd/system/nexopos-queue.service" "queue:work"
assert_file "$MK/opt/nexopos/.env"
assert_fcontains "$MK/opt/nexopos/.env" "DB_DATABASE"
assert_fcontains "$MK/opt/nexopos/.env" "APP_ENV=production"
assert_file "$MK/opt/nexopos/public/build/assets/app.css"
assert_file "$MK/etc/nginx/sites-available/nexopos"
assert_fcontains "$MK/etc/nginx/sites-available/nexopos" "fastcgi_pass unix:"
assert_fregex "$MK/etc/nginx/sites-available/nexopos" "fastcgi_pass unix:/.*php.*-fpm\\.sock"

t "Install: node/composer kommen per apt-first (kein /usr/local-Fallstrick)"
assert_calls 1 "apt-get install -y -qq --no-install-recommends composer"
assert_calls 1 "apt-get install -y -qq --no-install-recommends nodejs npm"
assert_no_calls "nodejs.org/dist"

t "Install: pct create bekommt onboot/nesting/unprivileged"
assert_fregex "$HS/ct_150.create" "ARGS=.*--onboot 1"
assert_fregex "$HS/ct_150.create" "ARGS=.*--features nesting=1"
assert_fregex "$HS/ct_150.create" "ARGS=.*--unprivileged 1"

# ── Install: Arch-Falle ────────────────────────────────────────────────────
t "Install: arm64-Template wird auf amd64-Host NICHT gewählt (Grube 31a)"
reset_state
touch "$HS/arm64_too"
ec=$(run_installer --yes --admin-pass TestPass123)
assert_exit 0 "$ec"
assert_out "amd64"
assert_no_out "arm64"

t "Install: create_start_fail → verify_ct_started stirbt mit Reinstall-Hinweis"
reset_state
touch "$HS/create_start_fail"
ec=$(run_installer --yes --admin-pass TestPass123)
assert_exit 1 "$ec"
assert_out "nicht 'running'"
assert_out "pct destroy"

# ── Install: Fehlerpfade ───────────────────────────────────────────────────
t "Install: exec_fail → IP-Poll scheitert mit Diagnose"
reset_state
seed_inner_tools
touch "$HS/exec_fail"
ec=$(run_installer --yes --admin-pass TestPass123)
assert_exit 1 "$ec"
assert_out "keine IP"

t "Install: create_fail → Fehlerkette mit Exit-Code + bash -x-Angebot"
reset_state
touch "$HS/create_fail"
ec=$(run_installer --yes --admin-pass TestPass123)
assert_exit 255 "$ec"
assert_out "FEHLGESCHLAGEN"
assert_out "bash -x"

t "Install: fail_health → Inner-Health-Poll stirbt, Host meldet Setup-Fehler"
reset_state
seed_inner_tools
touch "$HS/fail_health"
ec=$(run_installer --yes --admin-pass TestPass123)
assert_exit 1 "$ec"
assert_out "In-Container Setup fehlgeschlagen"

t "Install: keine IP (DHCP tot) → die()"
reset_state
touch "$HS/no_ip"
ec=$(run_installer --yes --admin-pass TestPass123)
assert_exit 1 "$ec"
assert_out "keine IP"

# ── Update ─────────────────────────────────────────────────────────────────
t "Update: findet laufenden CT per Hostname, baut neu, nginx active"
seed_ct
ec=$(run_installer --update)
assert_exit 0 "$ec"
assert_out "Update auf CT 150"
assert_out "http://10.120.5.88:8080"
assert_out "Datenbank initialisiert"

t "Install: ns:setup ohne DB-Init → harter Abbruch (kein stiller No-Op)"
reset_state
echo "FAIL_DB_INIT" > "$HS/db_init_fail"
ec=$(run_installer --yes --admin-pass TestPass123)
assert_exit 1 "$ec"
assert_out "nexopos_options"

t "Update: --id erzwingt CT-ID"
seed_ct
ec=$(run_installer --update --id 150)
assert_exit 0 "$ec"

t "Update: kein CT → die() mit --id-Hinweis"
reset_state
ec=$(run_installer --update)
assert_exit 1 "$ec"
assert_out "Nutze --id"

t "Update: gestoppten CT starten (ensure_ct_running, Grube 10)"
seed_ct
echo "stopped" > "$HS/ct_150.status"
/bin/sed -i 's/^150 .*/150 stopped nexopos/' "$HS/ct_list"
ec=$(run_installer --update)
assert_exit 0 "$ec"
assert_calls 1 "pct start 150"
assert_out "http://10.120.5.88:8080"

# ── Status ─────────────────────────────────────────────────────────────────
t "Status: laufender CT → URL + http=200"
seed_ct
ec=$(run_installer --status)
assert_exit 0 "$ec"
assert_out "running"
assert_out "nginx=active"
assert_out "http=200"
assert_out "http://10.120.5.88:8080"

t "Status: kein CT → die()"
reset_state
ec=$(run_installer --status)
assert_exit 1 "$ec"
assert_out "Kein CT gefunden"

# ── Uninstall ──────────────────────────────────────────────────────────────
t "Uninstall: zerstört CT nach Bestätigung"
seed_ct
ec=$(run_installer --uninstall --yes)
assert_exit 0 "$ec"
assert_calls 1 "pct destroy 150"
assert_out "entfernt"

t "Uninstall: ohne CT → nichts zu tun"
reset_state
ec=$(run_installer --uninstall --yes)
assert_exit 0 "$ec"
assert_no_calls "pct destroy"

# ══════════════════════════ Ergebnis ══════════════════════════════════════
echo
echo "════════════════════════════════════════"
if [[ $FAILED -eq 0 ]]; then
    echo "✅ ALLE CASES GRÜN: $PASSED Assertions bestanden"
    exit 0
else
    echo "❌ $FAILED Assertions FEHLGESCHLAGEN ($PASSED bestanden)"
    echo "   (HARNESS_KEEP=1 bash harness/run.sh behält Mock-Root: $MK)"
    exit 1
fi