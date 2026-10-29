#!/bin/bash
# On-warm for posthog: bring a fresh Starfolk box to a state where work can start.
#
# Runs before anyone is assigned, as `agent`, in a login shell, with this
# environment's secrets in the environment. Keep it idempotent: a re-run on the
# same box reuses what is already installed and leaves a running stack alone.
#
# The box image has no flox, so this follows the same flox-free recipe as
# products/tasks/backend/sandbox/images/bake-posthog-dev-stack.sh: pin the
# toolchain that .flox/env/manifest.toml provides on laptops, sync Python and
# Node dependencies, build phrocs, then start the default dev stack detached.
set -euo pipefail

log() { echo "[on-warm] $(date -u +%H:%M:%S) $*"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Same pins as bake-posthog-dev-stack.sh and .github/actions/setup-protoc.
PROTOC_VERSION=28.3
PROTOC_SHA256_AMD64=0ad949f04a6a174da83cdcbdb36dee0a4925272a5b6d83f79a6bf9852076d53f
PROTOC_SHA256_ARM64=1de522032a8b194002fe35cab86d747848238b5e4de4f99648372079f5b46f9a
SQLX_CLI_VERSION=0.8.3
# pyproject.toml requires uv >= 0.13.4. The image's uv is older.
UV_VERSION=0.13.6
STACK_TIMEOUT_SECONDS="${POSTHOG_ON_WARM_STACK_TIMEOUT:-600}"

export POSTHOG_TELEMETRY_OPT_OUT=1
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
# bin/start kills "orphaned" processes whose cwd is in this repo, which on a
# Starfolk box includes the platform's own repo backfill. Nothing is orphaned
# on a box that is warming, and a running stack is never restarted below.
export HOGLI_SKIP_ZOMBIE_CHECK=1

# The image routes rustc through a shared sccache server. A server that another
# user started writes build outputs this user cannot overwrite, and cargo then
# fails with "Permission denied" on its .d files. Use a server this user owns.
if [[ "${RUSTC_WRAPPER:-}" == "sccache" ]]; then
    other_owners="$(ps -o user= -C sccache 2> /dev/null | sort -u | grep -vx "$(id -un)" || true)"
    if [[ -n "$other_owners" ]]; then
        log "sccache server runs as ${other_owners//$'\n'/,}, restarting it as $(id -un)"
        sudo pkill -x sccache || true
    fi
    if ! sccache --start-server > /dev/null 2>&1 && ! sccache --show-stats > /dev/null 2>&1; then
        log "sccache server did not start, building without the shared cache"
        unset RUSTC_WRAPPER
    fi
fi

log "pinning node and uv"
NODE_VERSION="$(tr -d 'v[:space:]' < .nvmrc)"
mise use -g "node@${NODE_VERSION}" "uv@${UV_VERSION}"
# pnpm comes from corepack at the version package.json pins. A mise-managed
# pnpm would shadow it.
if mise ls --current pnpm 2> /dev/null | grep -q pnpm; then
    mise unuse -g pnpm
fi
eval "$(mise env -s bash)"
corepack enable
hash -r
log "node $(node --version), pnpm $(pnpm --version), uv $(uv --version | cut -d' ' -f2)"

log "installing system packages"
# brotli: bin/download-mmdb decompresses the GeoLite database with it.
if ! command -v brotli > /dev/null; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o DPkg::Lock::Timeout=120 brotli > /dev/null
fi
# protoc: the personhog services generate gRPC code at build time.
if [[ "$(protoc --version 2> /dev/null)" != "libprotoc ${PROTOC_VERSION}" ]]; then
    case "$(uname -m)" in
        x86_64) PROTOC_ARCH=x86_64 PROTOC_SHA256="$PROTOC_SHA256_AMD64" ;;
        aarch64) PROTOC_ARCH=aarch_64 PROTOC_SHA256="$PROTOC_SHA256_ARM64" ;;
        *) echo "unsupported architecture: $(uname -m)" >&2 && exit 1 ;;
    esac
    PROTOC_ZIP="$(mktemp --suffix=.zip)"
    curl -fsSL -o "$PROTOC_ZIP" "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-${PROTOC_ARCH}.zip"
    echo "${PROTOC_SHA256}  ${PROTOC_ZIP}" | sha256sum -c - > /dev/null
    sudo unzip -oq "$PROTOC_ZIP" -d /usr/local bin/protoc 'include/*'
    sudo chmod 0755 /usr/local/bin/protoc
    rm -f "$PROTOC_ZIP"
fi
log "$(protoc --version)"

# /etc/hosts: the compose service names resolve to this box, as on laptops.
POSTHOG_HOSTS="127.0.0.1 db redis7 kafka clickhouse clickhouse-coordinator objectstorage seaweedfs temporal # posthog"
if ! grep -qF "$POSTHOG_HOSTS" /etc/hosts; then
    echo "$POSTHOG_HOSTS" | sudo tee -a /etc/hosts > /dev/null
fi

log "installing dependencies (uv, pnpm, phrocs, sqlx-cli) in parallel"
# These are independent, so the wall clock is the slowest one, not the sum.
LOG_DIR="$(mktemp -d)"
pids=()
names=()
run_bg() {
    local name="$1"
    shift
    ("$@") > "$LOG_DIR/$name.log" 2>&1 &
    pids+=($!)
    names+=("$name")
}
run_bg uv uv sync --frozen
run_bg pnpm pnpm install --frozen-lockfile --prefer-offline
run_bg phrocs make -C tools/phrocs build
if [[ "$(sqlx --version 2> /dev/null)" != "sqlx-cli ${SQLX_CLI_VERSION}" ]]; then
    # The rust/bin migrators shell out to sqlx. sccache makes this a cache hit on later boxes.
    run_bg sqlx cargo install sqlx-cli --version "$SQLX_CLI_VERSION" --locked --no-default-features --features native-tls,postgres
fi
failed=0
for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then
        log "  ${names[$i]} done"
    else
        echo "[on-warm] ${names[$i]} failed:" >&2
        tail -n 40 "$LOG_DIR/${names[$i]}.log" >&2
        failed=1
    fi
done
rm -rf "$LOG_DIR"
[[ "$failed" -eq 0 ]] || exit 1

# flox links these into its venv. hogli and bin/start look for them on PATH.
ln -sf "$REPO_ROOT/tools/phrocs/dist/phrocs" .venv/bin/phrocs
ln -sf "$REPO_ROOT/bin/hogli" .venv/bin/hogli
# shellcheck disable=SC1091
source .venv/bin/activate

log "writing box settings to .env.local"
# bin/start reads .env.local (gitignored), so these survive the branch switch at
# assignment. Starfolk serves each port as https://<box>.proxy.starfolk.<tld>:<port>,
# and that hostname is only known per request. So everything is served from
# :8010: Caddy answers for any Host and routes the Vite paths, and an empty
# JS_URL keeps the page's script and asset URLs relative to that origin.
BEGIN_MARK="# >>> starfolk on-warm >>>"
END_MARK="# <<< starfolk on-warm <<<"
touch .env.local
chmod 600 .env.local
sed -i "/^${BEGIN_MARK}\$/,/^${END_MARK}\$/d" .env.local
cat >> .env.local << EOF
${BEGIN_MARK}
JS_URL=
CADDY_HOST=:8000
VITE_ALLOWED_HOSTS=localhost,.proxy.starfolk.ai,.proxy.starfolk.io,.proxy.starfolk.dev
EXTRA_CSRF_TRUSTED_ORIGINS=https://*.proxy.starfolk.ai:8010,https://*.proxy.starfolk.io:8010,https://*.proxy.starfolk.dev:8010
POSTHOG_DEBUGPY=0
${END_MARK}
EOF

if phrocs wait --timeout 1 > /dev/null 2>&1; then
    log "dev stack already running and ready, leaving it alone"
    log "ready"
    exit 0
fi
# A previous run left a stack that is not ready. `hogli down` stops phrocs, but the
# backend and Vite can outlive it and hold their ports. The zombie check that
# normally clears them is off (see above), so free the ports here.
hogli down -y > /dev/null 2>&1 || true
fuser -k -TERM 8000/tcp 8234/tcp 5678/tcp > /dev/null 2>&1 || true

log "prebuilding the Rust services the stack starts"
# bin/start runs each Rust service with `cargo run` and CARGO_BUILD_JOBS=1, so a
# cold workspace compiles one crate at a time. One parallel build first makes
# those `cargo run`s start from a fresh target dir.
hogli dev:generate > /dev/null
mapfile -t RUST_BINS < <(python - << 'PY'
import re
from pathlib import Path

import yaml

procs = yaml.safe_load(Path(".posthog/.generated/mprocs.yaml").read_text())["procs"]
script = Path("bin/start-rust-service").read_text()
bins = set()
for proc in procs.values():
    if not proc.get("autostart", True):
        continue
    for svc in re.findall(r"start-rust-service ([a-z0-9-]+)", proc.get("shell", "")):
        # Some services run another binary in a different mode (DEV_RUST_SVC_OVERRIDE).
        case = re.search(rf"^\s*{re.escape(svc)}\)(.*?);;", script, re.M | re.S)
        override = re.search(r"DEV_RUST_SVC_OVERRIDE=([a-z0-9-]+)", case.group(1)) if case else None
        bins.add(override.group(1) if override else svc)
print("\n".join(sorted(bins)))
PY
)
# One binary per build, like each service's own `cargo run --bin`: a multi-bin build
# unifies features across them, and the services would then rebuild the shared crates.
for bin in "${RUST_BINS[@]}"; do
    log "  cargo build --bin $bin"
    (cd rust && cargo build --quiet --bin "$bin")
done

log "starting datastores"
# Same compose project and files as the stack's docker-compose unit, so `hogli up` reuses these containers.
docker compose -p posthog -f docker-compose.dev.yml -f docker-compose.profiles.yml \
    up -d --quiet-pull db redis7 zookeeper kafka clickhouse objectstorage
bin/wait-for-docker

log "running migrations"
# Run them here, in order, rather than in the stack's parallel migrate-* units, so each
# is timed in this log. Same env precedence as bin/start: shell, .env.local, then the
# committed defaults. This mirrors bake-posthog-dev-stack.sh.
load_env_defaults() {
    local name value
    while IFS='=' read -r name value; do
        [[ -z "$name" || "$name" == \#* || "$value" == *op://* ]] && continue
        if [[ -z "${!name:-}" ]]; then
            export "$name=$value"
        fi
    done < "$1"
}
(
    load_env_defaults .env.local
    load_env_defaults .env.development
    load_env_defaults .env.services
    export PERSONS_DB_WRITER_URL="${PERSONS_DB_WRITER_URL:-postgres://posthog:posthog@db:5432/posthog_persons}"
    export CYCLOTRON_NODE_DATABASE_URL="${CYCLOTRON_NODE_DATABASE_URL:-postgres://posthog:posthog@db:5432/cyclotron_node}"
    export BEHAVIORAL_COHORTS_DATABASE_URL="${BEHAVIORAL_COHORTS_DATABASE_URL:-postgres://posthog:posthog@db:5432/behavioral_cohorts}"
    export FLAGS_READ_STORE_DATABASE_URL="${FLAGS_READ_STORE_DATABASE_URL:-postgres://posthog:posthog@db:5432/flags_read_store}"
    # On an empty database, load the schema snapshot first, as the stack's migrate-postgres
    # unit does. Replaying the full migration history takes far longer than on-warm allows.
    bin/hogli db:restore-schema-if-fresh
    log "  schema snapshot step done"
    # ClickHouse migrations need the instance settings table that the Postgres migrations create.
    bin/migrate --scope=postgres --scope=persons
    log "  postgres and persons done"
    bin/migrate --scope=clickhouse
    log "  clickhouse done"
    # The default intent does not run these scopes, and the nodejs workers need cyclotron's tables.
    bin/migrate --scope=cyclotron --scope=behavioral-cohorts --scope=flags-read-store
    log "  cyclotron, behavioral-cohorts and flags-read-store done"
) > "$REPO_ROOT/.posthog/on-warm-migrate.log" 2>&1 || {
    echo "[on-warm] migrations failed:" >&2
    tail -n 40 "$REPO_ROOT/.posthog/on-warm-migrate.log" >&2
    exit 1
}
grep "\[on-warm\]" "$REPO_ROOT/.posthog/on-warm-migrate.log" || true

log "starting the dev stack"
hogli up -d -y

log "waiting for the stack to be ready (up to ${STACK_TIMEOUT_SECONDS}s)"
# `phrocs wait` returns on the first crash, but phrocs restarts a crashed unit by
# itself. A unit can crash once while a cold box is still busy, so wait again
# until the deadline. Exit code 1 is a crash; 2 is a timeout.
deadline=$((SECONDS + STACK_TIMEOUT_SECONDS))
crashes=0
until phrocs wait --timeout "$((deadline > SECONDS ? deadline - SECONDS : 1))"; do
    rc=$?
    crashes=$((crashes + 1))
    if [[ "$rc" -ne 1 || "$crashes" -ge 5 || "$SECONDS" -ge "$deadline" ]]; then
        echo "[on-warm] the dev stack did not become ready. Logs: $REPO_ROOT/.posthog/.generated/logs/" >&2
        # phrocs prints only the tail of a crashed unit. Show where each panic starts.
        grep -m1 -H -B2 -A12 -iE "fatal error|panic:|out of memory" .posthog/.generated/logs/*.log >&2 || true
        exit 1
    fi
    log "a unit crashed and phrocs restarts it, waiting again (${crashes})"
    sleep 10
done
curl -sf -o /dev/null --max-time 10 http://localhost:8010/_health

log "ready: PostHog on :8010"
