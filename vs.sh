#!/usr/bin/env bash
#
# vs.sh — VS Code over SSH
#
# Bootstrap a self-contained code-server onto a remote Linux host,
# tunnel it through SSH, and open it in the local browser.
#
# Default install path:
#
#   local curl/download
#        ↓
#   local cache
#        ↓
#      scp
#        ↓
#   remote tar install
#        ↓
#   code-server on remote Unix socket
#        ↓
#   existing SSH connection
#        ↓
#   http://127.0.0.1:8765
#
# Usage:
#
#   vs.sh HOST [REMOTE_DIR]
#
# Examples:
#
#   ./vs.sh gpu-box
#   ./vs.sh user@gpu-box ~/project
#
#   ./vs.sh --transfer=always gpu-box ~/project
#   ./vs.sh --transfer=auto   gpu-box ~/project
#   ./vs.sh --transfer=none   gpu-box ~/project
#
# Transfer modes:
#
#   always   Local download/cache -> scp -> remote install.
#            NEVER asks the remote host to access the Internet.
#            This is the default.
#
#   auto     Prefer local download/cache -> scp.
#            If that fails, try downloading on the remote host.
#
#   none     Never upload the archive from local.
#            Download directly on the remote host.
#
# Local requirements:
#
#   always: bash, ssh, scp, curl
#   auto:   bash, ssh; curl/scp strongly preferred
#   none:   bash, ssh
#
# Remote requirements:
#
#   always: bash, tar, normal Unix userland
#   auto:   same; curl only needed for fallback
#   none:   bash, tar, curl
#
# Supported remote:
#
#   Linux amd64/x86_64
#   Linux arm64/aarch64
#   glibc-based distributions
#

set -Eeuo pipefail


# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

VS_SH_VERSION="0.2.0"

# Keep bootstrap deterministic.
#
# Update this when publishing a new vs.sh, or override with:
#
#   --code-version 4.x.y
#   VS_CODE_SERVER_VERSION=4.x.y
#
DEFAULT_CODE_VERSION="4.136.2"

CODE_VERSION="${VS_CODE_SERVER_VERSION:-$DEFAULT_CODE_VERSION}"

TRANSFER_MODE="${VS_TRANSFER:-always}"

LOCAL_PORT="${VS_PORT:-}"

IDLE_TIMEOUT="${VS_IDLE_TIMEOUT:-900}"

NO_OPEN=0
KEEP_SERVER=0

# Mirrors can use the same layout as GitHub:
#
#   BASE/v4.136.2/code-server-4.136.2-linux-amd64.tar.gz
#
# Example:
#
#   VS_DOWNLOAD_BASE=https://your-oss.example/code-server/releases/download
#
DOWNLOAD_BASE="${VS_DOWNLOAD_BASE:-https://github.com/coder/code-server/releases/download}"

LOCAL_CACHE_ROOT="${VS_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/vs.sh}"
LOCAL_DOWNLOAD_DIR="$LOCAL_CACHE_ROOT/downloads"

SSH_ARGS=()
SCP_ARGS=()


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

die() {
    printf 'vs.sh: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '\033[1;34mvs.sh:\033[0m %s\n' "$*" >&2
}

warn() {
    printf '\033[1;33mvs.sh:\033[0m %s\n' "$*" >&2
}

usage() {
    cat <<'EOF'
vs.sh — VS Code over SSH

Usage:
  vs.sh [options] HOST [REMOTE_DIR]

Examples:
  vs.sh server
  vs.sh user@server ~/project

  vs.sh --transfer=always server
  vs.sh --transfer=auto server
  vs.sh --transfer=none server

Options:
  --transfer MODE
  --transfer=MODE
        Installation transfer policy:

        always   local download -> cache -> scp -> SSH install
                 remote Internet access is never required
                 DEFAULT

        auto     try local download/scp first;
                 fall back to remote download

        none     no local archive transfer;
                 remote downloads code-server itself

  --code-version VERSION
        code-server version to use.
        Default is pinned by this vs.sh release.

  --download-base URL
        Override artifact source.

        Expected layout:
          URL/v<VERSION>/code-server-<VERSION>-linux-<ARCH>.tar.gz

  --cache-dir DIR
        Local artifact cache.
        Default:
          ~/.cache/vs.sh

  -l, --local-port PORT
        Local browser port.
        Default: first available port in 8765..8799

  --idle SECONDS
        code-server idle shutdown timeout.
        Default: 900

  --no-open
        Do not automatically open a browser.

  --keep-server
        Leave remote code-server running after the interactive
        SSH shell exits. It can still terminate via idle timeout.

SSH options:
  -p, --ssh-port PORT
  -i, --identity FILE
  -J, --jump HOST
  -F, --ssh-config FILE
  -o, --ssh-option OPTION

Other:
  -h, --help
  --version

Environment:
  VS_TRANSFER
  VS_PORT
  VS_IDLE_TIMEOUT
  VS_CODE_SERVER_VERSION
  VS_DOWNLOAD_BASE
  VS_CACHE_DIR
EOF
}

require_arg() {
    [[ $# -ge 2 ]] || die "$1 requires an argument"
}

# Quote arbitrary text for a POSIX-compatible shell command.
#
# We cannot use printf %q here because the SSH server may invoke /bin/sh
# before bash receives the command.
shell_quote() {
    local s="${1-}"

    printf "'"

    while [[ "$s" == *"'"* ]]; do
        printf "%s'\\''" "${s%%\'*}"
        s="${s#*\'}"
    done

    printf "%s'" "$s"
}


# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

while (($#)); do
    case "$1" in

        --transfer=*)
            TRANSFER_MODE="${1#*=}"
            shift
            ;;

        --transfer)
            require_arg "$@"
            TRANSFER_MODE="$2"
            shift 2
            ;;

        --code-version)
            require_arg "$@"
            CODE_VERSION="${2#v}"
            shift 2
            ;;

        --download-base)
            require_arg "$@"
            DOWNLOAD_BASE="${2%/}"
            shift 2
            ;;

        --cache-dir)
            require_arg "$@"
            LOCAL_CACHE_ROOT="$2"
            LOCAL_DOWNLOAD_DIR="$LOCAL_CACHE_ROOT/downloads"
            shift 2
            ;;

        -l|--local-port)
            require_arg "$@"
            LOCAL_PORT="$2"
            shift 2
            ;;

        --idle)
            require_arg "$@"
            IDLE_TIMEOUT="$2"
            shift 2
            ;;

        --no-open)
            NO_OPEN=1
            shift
            ;;

        --keep-server)
            KEEP_SERVER=1
            shift
            ;;

        -p|--ssh-port)
            require_arg "$@"

            SSH_ARGS+=(-p "$2")
            SCP_ARGS+=(-P "$2")

            shift 2
            ;;

        -i|--identity)
            require_arg "$@"

            SSH_ARGS+=(-i "$2")
            SCP_ARGS+=(-i "$2")

            shift 2
            ;;

        -J|--jump)
            require_arg "$@"

            SSH_ARGS+=(-J "$2")
            SCP_ARGS+=(-J "$2")

            shift 2
            ;;

        -F|--ssh-config)
            require_arg "$@"

            SSH_ARGS+=(-F "$2")
            SCP_ARGS+=(-F "$2")

            shift 2
            ;;

        -o|--ssh-option)
            require_arg "$@"

            SSH_ARGS+=(-o "$2")
            SCP_ARGS+=(-o "$2")

            shift 2
            ;;

        --version)
            printf 'vs.sh %s\n' "$VS_SH_VERSION"
            exit 0
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        --)
            shift
            break
            ;;

        -*)
            die "unknown option: $1"
            ;;

        *)
            break
            ;;
    esac
done


HOST="${1:-}"

[[ -n "$HOST" ]] || {
    usage >&2
    exit 2
}

shift

REMOTE_DIR="${1:-~}"

# If the local shell expanded ~ or $HOME, normalize it back to ~ for the remote host
if [[ -n "${HOME:-}" ]]; then
    if [[ "$REMOTE_DIR" == "$HOME" ]]; then
        REMOTE_DIR="~"
    elif [[ "$REMOTE_DIR" == "$HOME/"* ]]; then
        REMOTE_DIR="~/${REMOTE_DIR#"$HOME/"}"
    fi
fi

[[ $# -le 1 ]] ||
    die "too many positional arguments"


# ---------------------------------------------------------------------------
# Validate configuration
# ---------------------------------------------------------------------------

case "$TRANSFER_MODE" in
    always|auto|none)
        ;;
    *)
        die "--transfer must be one of: always, auto, none"
        ;;
esac

[[ "$CODE_VERSION" =~ ^[0-9A-Za-z._-]+$ ]] ||
    die "invalid code-server version: $CODE_VERSION"

[[ "$IDLE_TIMEOUT" =~ ^[0-9]+$ ]] ||
    die "--idle must be an integer"

(( IDLE_TIMEOUT > 60 )) ||
    die "--idle must be greater than 60 seconds"

if [[ -n "$LOCAL_PORT" ]]; then

    [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] ||
        die "--local-port must be an integer"

    (( LOCAL_PORT >= 1 && LOCAL_PORT <= 65535 )) ||
        die "invalid local port: $LOCAL_PORT"

fi

command -v ssh >/dev/null 2>&1 ||
    die "OpenSSH client not found"


# ---------------------------------------------------------------------------
# ControlMaster
# ---------------------------------------------------------------------------

# Keep the socket path short. macOS has a relatively small sockaddr_un limit.

CONTROL_DIR="/tmp/vs.sh-${UID:-0}-$$-${RANDOM:-0}"
CONTROL_SOCKET="$CONTROL_DIR/ssh"

mkdir -m 700 "$CONTROL_DIR"

MASTER_STARTED=0
REMOTE_STARTED=0

REMOTE_SOCKET=""
REMOTE_PID=""
REMOTE_LOG=""
REMOTE_CONFIG=""


cleanup() {
    local rc=$?

    trap - EXIT INT TERM HUP

    if (( MASTER_STARTED )); then

        if (( REMOTE_STARTED )) && (( ! KEEP_SERVER )); then

            local cmd

            cmd="kill ${REMOTE_PID} >/dev/null 2>&1 || true; "
            cmd+="rm -f "
            cmd+="$(shell_quote "$REMOTE_SOCKET") "
            cmd+="$(shell_quote "$REMOTE_LOG") "
            cmd+="$(shell_quote "$REMOTE_CONFIG")"

            ssh \
                "${SSH_ARGS[@]}" \
                -S "$CONTROL_SOCKET" \
                "$HOST" \
                "$cmd" \
                >/dev/null 2>&1 || true

        fi

        ssh \
            "${SSH_ARGS[@]}" \
            -S "$CONTROL_SOCKET" \
            -O exit \
            "$HOST" \
            >/dev/null 2>&1 || true

    fi

    rm -rf "$CONTROL_DIR"

    exit "$rc"
}

trap cleanup EXIT INT TERM HUP


info "connecting to $HOST"

ssh \
    "${SSH_ARGS[@]}" \
    -M \
    -S "$CONTROL_SOCKET" \
    -fNT \
    -o ControlPersist=no \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    "$HOST" ||
    die "could not establish SSH connection"

MASTER_STARTED=1


# ---------------------------------------------------------------------------
# Probe remote
# ---------------------------------------------------------------------------

info "probing remote system"

PROBE="$(
    ssh \
        "${SSH_ARGS[@]}" \
        -S "$CONTROL_SOCKET" \
        "$HOST" \
        "bash -s -- $(shell_quote "$CODE_VERSION")" \
        <<'REMOTE_PROBE'
set -Eeuo pipefail

VERSION="$1"

die() {
    printf 'vs.sh(remote): %s\n' "$*" >&2
    exit 1
}

[[ "$(uname -s)" == "Linux" ]] ||
    die "only Linux remotes are currently supported"

case "$(uname -m)" in

    x86_64|amd64)
        ARCH="amd64"
        ;;

    aarch64|arm64)
        ARCH="arm64"
        ;;

    *)
        die "unsupported architecture: $(uname -m)"
        ;;
esac

# Official standalone code-server Linux builds expect glibc.
if [[ -f /etc/alpine-release ]]; then
    die "Alpine/musl is not supported by the standalone build"
fi

if command -v ldd >/dev/null 2>&1; then

    LDD_TEXT="$(ldd --version 2>&1 || true)"

    case "$LDD_TEXT" in
        *musl*|*Musl*)
            die "musl libc is not supported by the standalone build"
            ;;
    esac

fi

BASE="${XDG_CACHE_HOME:-$HOME/.cache}/vs.sh"
NAME="code-server-${VERSION}-linux-${ARCH}"
RELEASE="$BASE/releases/$NAME"

INSTALLED=0

if [[ -x "$RELEASE/bin/code-server" ]]; then
    INSTALLED=1
fi

printf 'PROBE\t%s\t%s\n' "$ARCH" "$INSTALLED"
REMOTE_PROBE
)" || die "remote probe failed"


IFS=$'\t' read -r \
    PROBE_MARKER \
    REMOTE_ARCH \
    REMOTE_INSTALLED \
    <<<"$PROBE"

[[ "$PROBE_MARKER" == "PROBE" ]] ||
    die "unexpected probe response: $PROBE"

case "$REMOTE_ARCH" in
    amd64|arm64)
        ;;
    *)
        die "invalid architecture returned by remote"
        ;;
esac

case "$REMOTE_INSTALLED" in
    0|1)
        ;;
    *)
        die "invalid install state returned by remote"
        ;;
esac


ARCHIVE_NAME="code-server-${CODE_VERSION}-linux-${REMOTE_ARCH}.tar.gz"

ARCHIVE_URL="${DOWNLOAD_BASE%/}/v${CODE_VERSION}/${ARCHIVE_NAME}"

LOCAL_ARCHIVE="$LOCAL_DOWNLOAD_DIR/$ARCHIVE_NAME"


# ---------------------------------------------------------------------------
# Local artifact acquisition
# ---------------------------------------------------------------------------

local_acquire_archive() {

    if [[ -s "$LOCAL_ARCHIVE" ]]; then
        info "using cached artifact: $LOCAL_ARCHIVE"
        return 0
    fi

    command -v curl >/dev/null 2>&1 || {
        warn "curl is not installed locally"
        return 1
    }

    mkdir -p "$LOCAL_DOWNLOAD_DIR" || return 1

    local tmp

    tmp="${LOCAL_ARCHIVE}.part.$$.$RANDOM"

    rm -f "$tmp"

    info "downloading code-server v$CODE_VERSION locally"
    info "source: $ARCHIVE_URL"

    if curl \
        -fL \
        --connect-timeout 10 \
        --retry 3 \
        --retry-delay 1 \
        -o "$tmp" \
        "$ARCHIVE_URL"
    then

        mv "$tmp" "$LOCAL_ARCHIVE"

        info "cached: $LOCAL_ARCHIVE"

        return 0

    fi

    rm -f "$tmp"

    warn "local download failed"

    return 1
}


# ---------------------------------------------------------------------------
# Remote installation
# ---------------------------------------------------------------------------

remote_install_from_upload() {

    local local_archive="$1"
    local remote_upload

    command -v scp >/dev/null 2>&1 || {
        warn "scp is not installed locally"
        return 1
    }

    remote_upload="$(
        ssh \
            "${SSH_ARGS[@]}" \
            -S "$CONTROL_SOCKET" \
            "$HOST" \
            'bash -s' \
            <<'REMOTE_TMP'
set -Eeuo pipefail

umask 077

BASE="${XDG_CACHE_HOME:-$HOME/.cache}/vs.sh"
TMP_DIR="$BASE/tmp"
mkdir -p "$TMP_DIR"

P="$TMP_DIR/upload.$$.$RANDOM.tar.gz"

: >"$P"

printf '%s\n' "$P"
REMOTE_TMP
    )" || {
        warn "could not allocate remote upload path"
        return 1
    }

    [[ "$remote_upload" == */upload.*.tar.gz ]] || {
        warn "remote returned invalid upload path"
        return 1
    }

    info "uploading archive with scp"

    if ! scp \
        "${SCP_ARGS[@]}" \
        -o "ControlPath=$CONTROL_SOCKET" \
        "$local_archive" \
        "$HOST:$remote_upload"
    then

        warn "scp upload failed"

        ssh \
            "${SSH_ARGS[@]}" \
            -S "$CONTROL_SOCKET" \
            "$HOST" \
            "rm -f $(shell_quote "$remote_upload")" \
            >/dev/null 2>&1 || true

        return 1

    fi

    info "installing uploaded archive on remote"

    if ssh \
        "${SSH_ARGS[@]}" \
        -S "$CONTROL_SOCKET" \
        "$HOST" \
        "bash -s -- \
            $(shell_quote "$CODE_VERSION") \
            $(shell_quote "$REMOTE_ARCH") \
            $(shell_quote "$remote_upload")" \
        <<'REMOTE_INSTALL_UPLOAD'
set -Eeuo pipefail

VERSION="$1"
ARCH="$2"
ARCHIVE="$3"

BASE="${XDG_CACHE_HOME:-$HOME/.cache}/vs.sh"
RELEASES="$BASE/releases"

NAME="code-server-${VERSION}-linux-${ARCH}"
RELEASE="$RELEASES/$NAME"

TMP="$BASE/.install.$$.$RANDOM"

cleanup() {
    rm -rf "$TMP"
    rm -f "$ARCHIVE"
}

trap cleanup EXIT

mkdir -p "$RELEASES"

# Another vs.sh invocation may have installed the same version while
# this archive was being uploaded.
if [[ -x "$RELEASE/bin/code-server" ]]; then
    exit 0
fi

mkdir -p "$TMP"

tar -xzf "$ARCHIVE" -C "$TMP"

EXTRACTED="$TMP/$NAME"

[[ -x "$EXTRACTED/bin/code-server" ]] || {
    printf 'vs.sh(remote): archive does not contain %s/bin/code-server\n' \
        "$NAME" >&2
    exit 1
}

if [[ ! -e "$RELEASE" ]]; then
    mv "$EXTRACTED" "$RELEASE"
fi

[[ -x "$RELEASE/bin/code-server" ]] || {
    printf 'vs.sh(remote): installation failed\n' >&2
    exit 1
}

"$RELEASE/bin/code-server" --version >/dev/null

printf 'vs.sh(remote): installed code-server %s\n' "$VERSION" >&2
REMOTE_INSTALL_UPLOAD
    then
        return 0
    fi

    warn "remote installation from uploaded archive failed"

    ssh \
        "${SSH_ARGS[@]}" \
        -S "$CONTROL_SOCKET" \
        "$HOST" \
        "rm -f $(shell_quote "$remote_upload")" \
        >/dev/null 2>&1 || true

    return 1
}


remote_install_by_download() {

    info "downloading code-server from the remote host"
    info "source: $ARCHIVE_URL"

    ssh \
        "${SSH_ARGS[@]}" \
        -S "$CONTROL_SOCKET" \
        "$HOST" \
        "bash -s -- \
            $(shell_quote "$CODE_VERSION") \
            $(shell_quote "$REMOTE_ARCH") \
            $(shell_quote "$DOWNLOAD_BASE")" \
        <<'REMOTE_INSTALL_DOWNLOAD'
set -Eeuo pipefail

VERSION="$1"
ARCH="$2"
DOWNLOAD_BASE="${3%/}"

BASE="${XDG_CACHE_HOME:-$HOME/.cache}/vs.sh"
RELEASES="$BASE/releases"

NAME="code-server-${VERSION}-linux-${ARCH}"
RELEASE="$RELEASES/$NAME"

URL="${DOWNLOAD_BASE}/v${VERSION}/${NAME}.tar.gz"

TMP="$BASE/.install.$$.$RANDOM"
ARCHIVE="$TMP/$NAME.tar.gz"

cleanup() {
    rm -rf "$TMP"
}

trap cleanup EXIT

mkdir -p "$RELEASES"

if [[ -x "$RELEASE/bin/code-server" ]]; then
    exit 0
fi

command -v curl >/dev/null 2>&1 || {
    printf 'vs.sh(remote): curl is required for --transfer=none/auto fallback\n' >&2
    exit 1
}

mkdir -p "$TMP"

printf 'vs.sh(remote): downloading %s\n' "$URL" >&2

curl \
    -fL \
    --connect-timeout 10 \
    --retry 3 \
    --retry-delay 1 \
    -o "$ARCHIVE" \
    "$URL"

tar -xzf "$ARCHIVE" -C "$TMP"

EXTRACTED="$TMP/$NAME"

[[ -x "$EXTRACTED/bin/code-server" ]] || {
    printf 'vs.sh(remote): downloaded archive is invalid\n' >&2
    exit 1
}

if [[ ! -e "$RELEASE" ]]; then
    mv "$EXTRACTED" "$RELEASE"
fi

[[ -x "$RELEASE/bin/code-server" ]] || {
    printf 'vs.sh(remote): installation failed\n' >&2
    exit 1
}

"$RELEASE/bin/code-server" --version >/dev/null

printf 'vs.sh(remote): installed code-server %s\n' "$VERSION" >&2
REMOTE_INSTALL_DOWNLOAD
}


# ---------------------------------------------------------------------------
# Select installation transport
# ---------------------------------------------------------------------------

if [[ "$REMOTE_INSTALLED" == "1" ]]; then

    info "code-server v$CODE_VERSION is already installed remotely"

else

    case "$TRANSFER_MODE" in

        always)

            info "transfer mode: always"

            local_acquire_archive ||
                die "local artifact download failed; remote download is disabled by --transfer=always"

            remote_install_from_upload "$LOCAL_ARCHIVE" ||
                die "local -> scp -> remote installation failed"

            ;;


        auto)

            info "transfer mode: auto"

            LOCAL_PATH_WORKED=0

            if local_acquire_archive; then

                if remote_install_from_upload "$LOCAL_ARCHIVE"; then
                    LOCAL_PATH_WORKED=1
                else
                    warn "local/scp installation failed; trying remote download"
                fi

            else
                warn "local download unavailable; trying remote download"
            fi

            if (( ! LOCAL_PATH_WORKED )); then

                remote_install_by_download ||
                    die "both local/scp and remote download installation paths failed"

            fi

            ;;


        none)

            info "transfer mode: none"

            remote_install_by_download ||
                die "remote download/install failed"

            ;;

    esac

fi


# ---------------------------------------------------------------------------
# Start code-server
# ---------------------------------------------------------------------------

info "starting remote VS Code server"

START_OUTPUT="$(
    ssh \
        "${SSH_ARGS[@]}" \
        -S "$CONTROL_SOCKET" \
        "$HOST" \
        "bash -s -- \
            $(shell_quote "$CODE_VERSION") \
            $(shell_quote "$REMOTE_ARCH") \
            $(shell_quote "$REMOTE_DIR") \
            $(shell_quote "$IDLE_TIMEOUT")" \
        <<'REMOTE_START'
set -Eeuo pipefail

VERSION="$1"
ARCH="$2"
VS_DIR="$3"
IDLE="$4"

die() {
    printf 'vs.sh(remote): %s\n' "$*" >&2
    exit 1
}

BASE="${XDG_CACHE_HOME:-$HOME/.cache}/vs.sh"
RUN_DIR="$BASE/run"

NAME="code-server-${VERSION}-linux-${ARCH}"
RELEASE="$BASE/releases/$NAME"

CODE_SERVER="$RELEASE/bin/code-server"

[[ -x "$CODE_SERVER" ]] ||
    die "code-server v$VERSION is not installed"

mkdir -p "$RUN_DIR"


# Expand the useful ~ forms because VS Code receives the path literally.

case "$VS_DIR" in

    "~")
        VS_DIR="$HOME"
        ;;

    "~/"*)
        VS_DIR="$HOME/${VS_DIR:2}"
        ;;

    /*)
        ;;

    *)
        VS_DIR="$HOME/$VS_DIR"
        ;;

esac

[[ -e "$VS_DIR" ]] ||
    die "workspace does not exist: $VS_DIR"


# Every session gets its own config, socket and log.

CONFIG="$RUN_DIR/config.$$.$RANDOM.yaml"

SOCKET="$RUN_DIR/vs.$$.$RANDOM.sock"

# Fall back to /tmp if socket path in RUN_DIR exceeds 100 bytes (Unix socket limit is 108)
# and /tmp is writable.
if (( ${#SOCKET} > 100 )) && [[ -w /tmp ]] && ( : >"/tmp/.vs_test.$$.$RANDOM" 2>/dev/null ); then
    rm -f "/tmp/.vs_test.$$.$RANDOM" 2>/dev/null || true
    SOCKET="/tmp/vs.${UID:-0}.$$.$RANDOM.sock"
fi

LOG="$RUN_DIR/server.$$.$RANDOM.log"

cat >"$CONFIG" <<'EOF'
auth: none
cert: false
EOF

chmod 600 "$CONFIG"

rm -f "$SOCKET"


nohup "$CODE_SERVER" \
    --config "$CONFIG" \
    --socket "$SOCKET" \
    --socket-mode 0600 \
    --disable-update-check \
    --disable-telemetry \
    --idle-timeout-seconds "$IDLE" \
    "$VS_DIR" \
    >"$LOG" 2>&1 </dev/null &

PID=$!


# Wait for the Unix socket and catch startup failures.

READY=0

for ((i = 0; i < 30; i++)); do

    if [[ -S "$SOCKET" ]]; then
        READY=1
        break
    fi

    if ! kill -0 "$PID" >/dev/null 2>&1; then

        printf '\nvs.sh(remote): code-server failed to start:\n' >&2
        cat "$LOG" >&2 || true

        rm -f "$SOCKET" "$CONFIG"

        exit 1

    fi

    sleep 1

done


if (( ! READY )); then

    kill "$PID" >/dev/null 2>&1 || true

    printf '\nvs.sh(remote): code-server did not become ready:\n' >&2
    cat "$LOG" >&2 || true

    rm -f "$SOCKET" "$CONFIG"

    exit 1

fi


VERSION_TEXT="$("$CODE_SERVER" --version 2>/dev/null || true)"
VERSION_TEXT="${VERSION_TEXT%%$'\n'*}"


# stdout is deliberately machine-readable.
# Diagnostics go to stderr.

printf 'READY\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$SOCKET" \
    "$PID" \
    "$LOG" \
    "$CONFIG" \
    "$VERSION_TEXT" \
    "$VS_DIR"
REMOTE_START
)" || die "could not start remote code-server"


IFS=$'\t' read -r \
    START_MARKER \
    REMOTE_SOCKET \
    REMOTE_PID \
    REMOTE_LOG \
    REMOTE_CONFIG \
    REMOTE_VERSION \
    REMOTE_WORKSPACE \
    <<<"$START_OUTPUT"


[[ "$START_MARKER" == "READY" ]] ||
    die "unexpected server response: $START_OUTPUT"

[[ "$REMOTE_PID" =~ ^[0-9]+$ ]] ||
    die "invalid remote PID"

[[ "$REMOTE_SOCKET" == /* ]] ||
    die "invalid remote socket"

REMOTE_STARTED=1


# ---------------------------------------------------------------------------
# Add forwarding to the existing SSH connection
# ---------------------------------------------------------------------------

add_forward() {

    local port="$1"

    ssh \
        "${SSH_ARGS[@]}" \
        -S "$CONTROL_SOCKET" \
        -O forward \
        -L "127.0.0.1:${port}:${REMOTE_SOCKET}" \
        "$HOST" \
        >/dev/null
}


if [[ -n "$LOCAL_PORT" ]]; then

    info "forwarding localhost:$LOCAL_PORT"

    add_forward "$LOCAL_PORT" ||
        die "could not bind local port $LOCAL_PORT"

else

    for ((port = 8765; port <= 8799; port++)); do

        if add_forward "$port" 2>/dev/null; then
            LOCAL_PORT="$port"
            break
        fi

    done

    [[ -n "$LOCAL_PORT" ]] ||
        die "could not find a free local port in 8765..8799"

fi


URL="http://127.0.0.1:${LOCAL_PORT}"


# ---------------------------------------------------------------------------
# Browser
# ---------------------------------------------------------------------------

open_browser() {

    local url="$1"
    local os

    (( NO_OPEN )) && return 0

    os="$(uname -s 2>/dev/null || true)"

    if [[ "$os" == "Darwin" ]] &&
       command -v open >/dev/null 2>&1
    then
        open "$url" >/dev/null 2>&1 &
        return 0
    fi

    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 &
        return 0
    fi

    if command -v wslview >/dev/null 2>&1; then
        wslview "$url" >/dev/null 2>&1 &
        return 0
    fi

    if command -v cmd.exe >/dev/null 2>&1; then
        cmd.exe /c start "" "$url" >/dev/null 2>&1 &
        return 0
    fi

    warn "could not open a browser automatically"
}


printf '\n'
printf '  VS Code:      \033[1;36m%s\033[0m\n' "$URL"
printf '  Remote:       %s\n' "$HOST"
printf '  Workspace:    %s\n' "${REMOTE_WORKSPACE:-$REMOTE_DIR}"
printf '  Architecture: %s\n' "$REMOTE_ARCH"
printf '  Transfer:     %s\n' "$TRANSFER_MODE"

if [[ -n "${REMOTE_VERSION:-}" ]]; then
    printf '  code-server:  %s\n' "$REMOTE_VERSION"
fi

printf '\n'


open_browser "$URL"


# ---------------------------------------------------------------------------
# Interactive shell
# ---------------------------------------------------------------------------

info "opening interactive SSH shell"

if (( KEEP_SERVER )); then
    info "remote code-server will remain until its idle timeout"
else
    info "remote code-server will stop when this shell exits"
fi

printf '\n'

set +e

ssh \
    "${SSH_ARGS[@]}" \
    -S "$CONTROL_SOCKET" \
    "$HOST"

RC=$?

set -e

exit "$RC"