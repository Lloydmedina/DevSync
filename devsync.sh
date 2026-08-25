#!/bin/bash
#
# devsync — Windows -> WSL one-way sync + local dev server runner
#
# Sync source code from a Windows-mounted (git-tracked) folder into a WSL
# folder for local testing, and run it there as a lightweight stand-in for
# Docker Desktop on underpowered laptops.
#
# Supports:
#   - Python: FastAPI (via uvicorn)
#   - Python: Django  (via manage.py runserver)
#   - PHP:    Laravel (via `php artisan serve`)
#   - PHP:    Yii2     (via PHP's built-in server against the webroot)
#
# Usage:
#   devsync init              # interactive setup, writes .devsync.conf in $DEST
#   devsync sync               # sync files
#   devsync sync --dry         # show what would change, no copying
#   devsync sync --diff        # file-by-file diff, Windows vs WSL
#   devsync run                # sync, then start the dev server
#   devsync run-only           # start the dev server without syncing
#   devsync stop               # stop whatever is on $PORT
#   devsync status             # show whether $PORT is in use + by what
#   devsync version            # show version
#
# Config file (.devsync.conf), created by `devsync init`, lives in $DEST and
# is a plain shell file that gets sourced. You can hand-edit it any time.
#
# All commands accept -c/--config <path> to point at a specific config file
# instead of the default ./ or $DEST/.devsync.conf lookup.

set -euo pipefail

# ---------- colors ----------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}$*${NC}" >&2; }
warn()  { echo -e "${YELLOW}$*${NC}" >&2; }
err()   { echo -e "${RED}$*${NC}" >&2; }
note()  { echo -e "${BLUE}$*${NC}" >&2; }

CONFIG_FILE=""
CMD=""
SYNC_MODE="sync"
VERSION="1.0.0"
CONFIG_LOADED=0
RESOLVED_FW=""

# ---------- arg parsing ----------
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -c|--config)
            if [ $# -lt 2 ]; then
                err "-c/--config requires a path argument."
                exit 1
            fi
            CONFIG_FILE="$2"
            shift 2
            ;;
        --dry)
            SYNC_MODE="dry"
            shift
            ;;
        --diff)
            SYNC_MODE="diff"
            shift
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

CMD="${ARGS[0]:-}"

if [ "$SYNC_MODE" != "sync" ] && [ "$CMD" != "sync" ]; then
    err "--dry and --diff can only be used with 'devsync sync'."
    exit 1
fi

# ---------- locate config ----------
find_config() {
    if [ -n "$CONFIG_FILE" ]; then
        if [ ! -f "$CONFIG_FILE" ]; then
            err "Config file not found: $CONFIG_FILE"
            exit 1
        fi
        echo "$CONFIG_FILE"
        return
    fi
    if [ -f "./.devsync.conf" ]; then
        echo "./.devsync.conf"
        return
    fi
    echo ""
}

DEFAULT_CONFIG_NAME=".devsync.conf"

# ---------- path normalization ----------
normalize_windows_path() {
    local p="$1"
    # Convert Windows drive paths (C:\..., V:\..., C:/..., V:/...) to /mnt/c/..., /mnt/v/...
    if [[ "$p" =~ ^([A-Za-z]):[\\/](.*) ]]; then
        local drive="${BASH_REMATCH[1]}"
        local rest="${BASH_REMATCH[2]}"
        # Replace backslashes with forward slashes
        rest="${rest//\\//}"
        echo "/mnt/${drive,,}/${rest}"
    else
        echo "$p"
    fi
}

# ---------- dependency checks ----------
check_dependencies() {
    local missing=()
    command -v rsync >/dev/null 2>&1 || missing+=("rsync")
    command -v lsof  >/dev/null 2>&1 || missing+=("lsof")
    if [ ${#missing[@]} -gt 0 ]; then
        err "Missing required commands: ${missing[*]}"
        err "Install them with: sudo apt install ${missing[*]}"
        exit 1
    fi
}

# ---------- init: interactive setup ----------
cmd_init() {
    note "=== devsync setup ==="
    echo ""

    read -rp "Windows source path (e.g. /mnt/c/Users/you/project or V:\project): " SOURCE
    SOURCE="$(normalize_windows_path "$SOURCE")"
    DEST="$(pwd)"
    echo "WSL destination: $DEST (current directory)"
    echo ""

    if [ "$SOURCE" = "$DEST" ]; then
        err "Source and destination cannot be the same path."
        exit 1
    fi

    if [ ! -d "$SOURCE" ]; then
        warn "Note: $SOURCE doesn't exist yet (or drive isn't mounted). Continuing anyway."
    fi
    mkdir -p "$DEST"

    echo ""
    echo "Language:"
    echo "  1) Python"
    echo "  2) PHP"
    echo "  3) Not sure — auto-detect everything"
    read -rp "Choose [1-3]: " lang_choice

    FRAMEWORK="auto"
    case "$lang_choice" in
        1)
            echo ""
            echo "Python framework:"
            echo "  1) FastAPI"
            echo "  2) Django"
            echo "  3) Not sure — auto-detect"
            read -rp "Choose [1-3]: " fw_choice
            case "$fw_choice" in
                1) FRAMEWORK="fastapi" ;;
                2) FRAMEWORK="django" ;;
                *) FRAMEWORK="auto" ;;
            esac
            ;;
        2)
            echo ""
            echo "PHP framework:"
            echo "  1) Laravel"
            echo "  2) Yii2"
            echo "  3) Not sure — auto-detect"
            read -rp "Choose [1-3]: " fw_choice
            case "$fw_choice" in
                1) FRAMEWORK="laravel" ;;
                2) FRAMEWORK="yii2" ;;
                *) FRAMEWORK="auto" ;;
            esac
            ;;
        *)
            FRAMEWORK="auto"
            ;;
    esac

    read -rp "Port to run the dev server on [8000]: " PORT
    PORT="${PORT:-8000}"

    VENV_PATH=""
    APP_ENTRY=""
    PHP_DOCROOT=""
    DJANGO_MANAGE_PATH=""

    # Only prompt for settings relevant to what was chosen. With FRAMEWORK=auto
    # (either top-level "not sure" or a per-language "not sure"), fall back to
    # asking about anything that could plausibly apply.
    ask_python_settings=0
    ask_fastapi_settings=0
    ask_django_settings=0
    ask_php_settings=0

    case "$FRAMEWORK" in
        fastapi) ask_python_settings=1; ask_fastapi_settings=1 ;;
        django)  ask_python_settings=1; ask_django_settings=1 ;;
        yii2|laravel) ask_php_settings=1 ;;
        auto)
            case "$lang_choice" in
                1) ask_python_settings=1; ask_fastapi_settings=1; ask_django_settings=1 ;;
                2) ask_php_settings=1 ;;
                *) ask_python_settings=1; ask_fastapi_settings=1; ask_django_settings=1; ask_php_settings=1 ;;
            esac
            ;;
    esac

    if [ "$ask_python_settings" = "1" ]; then
        read -rp "Python venv path relative to DEST [venv] (leave blank to skip): " VENV_PATH
        VENV_PATH="${VENV_PATH:-venv}"
    fi

    if [ "$ask_fastapi_settings" = "1" ]; then
        read -rp "FastAPI app entry (module:app), blank = auto-detect: " APP_ENTRY
    fi

    if [ "$ask_django_settings" = "1" ]; then
        read -rp "Path to manage.py relative to DEST [manage.py]: " DJANGO_MANAGE_PATH
        DJANGO_MANAGE_PATH="${DJANGO_MANAGE_PATH:-manage.py}"
    fi

    if [ "$ask_php_settings" = "1" ]; then
        read -rp "PHP webroot relative to DEST, blank = auto-detect (web/ or public/): " PHP_DOCROOT
    fi

    CONFIG_PATH="$DEST/$DEFAULT_CONFIG_NAME"
    if [ -f "$CONFIG_PATH" ]; then
        warn "A .devsync.conf already exists at: $CONFIG_PATH"
        read -rp "Overwrite? [y/N]: " overwrite
        case "$overwrite" in
            [yY]*) ;;
            *) info "Aborted."; exit 0 ;;
        esac
    fi
    cat > "$CONFIG_PATH" <<EOF
# devsync config — generated by 'devsync init'
SOURCE="$SOURCE"
DEST="$DEST"
FRAMEWORK="$FRAMEWORK"     # auto | fastapi | django | laravel | yii2
PORT="$PORT"

# Python (FastAPI / Django) only
VENV_PATH="$VENV_PATH"     # relative to DEST, blank = skip venv activation
APP_ENTRY="$APP_ENTRY"     # FastAPI only, e.g. app.main:app, blank = auto-detect
DJANGO_MANAGE_PATH="$DJANGO_MANAGE_PATH"   # Django only, relative to DEST, blank = "manage.py"

# PHP (Laravel / Yii2) only
PHP_DOCROOT="$PHP_DOCROOT" # relative to DEST, blank = auto-detect (web/ or public/)

# Extra rsync excludes, on top of framework defaults, e.g.:
# EXTRA_EXCLUDES=("storage/app/*" "some-other-dir/")
EXTRA_EXCLUDES=()
EOF

    echo ""
    info "Config written to: $CONFIG_PATH"
    note "Run 'devsync run' from anywhere with -c $CONFIG_PATH, or cd into $DEST and just run 'devsync run'."
}

# ---------- load config ----------
load_config() {
    if [ "$CONFIG_LOADED" = "1" ]; then
        return
    fi
    local cfg
    cfg="$(find_config)"
    if [ -z "$cfg" ]; then
        err "No .devsync.conf found. Run 'devsync init' first, or pass -c <path>."
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$cfg"
    : "${SOURCE:?SOURCE not set in config}"
    : "${DEST:?DEST not set in config}"
    : "${PORT:=8000}"
    : "${FRAMEWORK:=auto}"
    : "${VENV_PATH:=venv}"
    : "${APP_ENTRY:=}"
    : "${DJANGO_MANAGE_PATH:=manage.py}"
    : "${PHP_DOCROOT:=}"
    EXTRA_EXCLUDES=("${EXTRA_EXCLUDES[@]:-}")
    CONFIG_USED="$cfg"
    CONFIG_LOADED=1
}

# ---------- framework detection ----------
# Checks a single directory for framework markers. Prints framework name or
# "unknown" to stdout only — no status chatter (this gets captured by callers).
detect_framework_in() {
    local dir="$1"
    if [ -f "$dir/artisan" ]; then
        echo "laravel"
    elif [ -f "$dir/yii" ]; then
        echo "yii2"
    elif [ -f "$dir/manage.py" ]; then
        echo "django"
    elif [ -f "$dir/requirements.txt" ] && grep -qi fastapi "$dir/requirements.txt" 2>/dev/null; then
        echo "fastapi"
    elif [ -f "$dir/pyproject.toml" ] && grep -qi fastapi "$dir/pyproject.toml" 2>/dev/null; then
        echo "fastapi"
    else
        echo "unknown"
    fi
}

# Tries DEST first (in case it's already synced), then falls back to SOURCE —
# important on a first-ever run, before anything has been copied into DEST yet.
detect_framework() {
    local detected
    detected="$(detect_framework_in "$DEST")"
    if [ "$detected" = "unknown" ] && [ -d "$SOURCE" ]; then
        detected="$(detect_framework_in "$SOURCE")"
    fi
    echo "$detected"
}

# Resolves FRAMEWORK (auto or explicit). Prints ONLY the framework name to
# stdout so `fw="$(resolve_framework)"` works safely; returns non-zero on
# failure instead of calling exit directly (exit inside a command
# substitution only kills the subshell, not the calling script).
resolve_framework() {
    if [ "$FRAMEWORK" = "auto" ]; then
        local detected
        detected="$(detect_framework)"
        if [ "$detected" = "unknown" ]; then
            return 1
        fi
        note "Auto-detected framework: $detected"
        echo "$detected"
    else
        echo "$FRAMEWORK"
    fi
}

# ---------- excludes per framework ----------
framework_excludes() {
    local fw="$1"
    local common=(--exclude=".git/" --exclude=".github/" --exclude=".env" --exclude="logs/" --exclude=".devsync.conf" --exclude="node_modules/")
    case "$fw" in
        fastapi)
            common+=(--exclude="venv/" --exclude="__pycache__/" --exclude="*.pyc" --exclude=".pytest_cache/")
            ;;
        django)
            common+=(--exclude="venv/" --exclude="__pycache__/" --exclude="*.pyc" --exclude=".pytest_cache/" --exclude="staticfiles/" --exclude="media/" --exclude="db.sqlite3")
            ;;
        laravel)
            common+=(--exclude="vendor/" --exclude="storage/logs/" --exclude="storage/framework/cache/" --exclude="storage/framework/sessions/" --exclude="storage/framework/views/" --exclude="bootstrap/cache/")
            ;;
        yii2)
            common+=(--exclude="vendor/" --exclude="runtime/")
            ;;
    esac
    printf '%s\n' "${common[@]}"
}

# ---------- sync ----------
do_sync() {
    load_config
    SOURCE="$(normalize_windows_path "$SOURCE")"
    local fw
    if ! fw="$(resolve_framework)"; then
        err "Could not auto-detect framework (checked $DEST and $SOURCE)."
        err "Set FRAMEWORK explicitly in your .devsync.conf (fastapi | django | laravel | yii2)."
        exit 1
    fi
    RESOLVED_FW="$fw"

    if [ ! -d "$SOURCE" ]; then
        err "ERROR: Source folder not found: $SOURCE"
        err "Make sure the Windows drive is mounted in WSL."
        exit 1
    fi
    mkdir -p "$DEST"

    mapfile -t EXCLUDES < <(framework_excludes "$fw")
    EXCLUDES+=("${EXTRA_EXCLUDES[@]}")

    echo "Source:      $SOURCE"
    echo "Destination: $DEST"
    echo "Framework:   $fw"
    echo ""

    case "$SYNC_MODE" in
        dry)
            warn "DRY RUN — no changes will be made:"
            echo ""
            rsync -avhn --delete "${EXCLUDES[@]}" "$SOURCE/" "$DEST/" --itemize-changes || true
            ;;
        diff)
            warn "Diffing Windows vs WSL:"
            echo ""
            local diff_excludes=()
            for e in "${EXCLUDES[@]}"; do
                local pattern="${e#--exclude=}"
                pattern="${pattern%/}"
                diff_excludes+=(--exclude="$pattern")
            done
            diff -rq "${diff_excludes[@]}" "$SOURCE" "$DEST" 2>&1 || true
            echo ""
            note "Files only in Windows (>) would be copied. Files only in WSL (<) are local-only and kept."
            ;;
        *)
            info "Syncing files..."
            rsync -avh --delete "${EXCLUDES[@]}" "$SOURCE/" "$DEST/"
            echo ""
            info "=== Sync complete ==="
            ;;
    esac
}

# ---------- stop / status ----------
port_pids() {
    lsof -ti :"$PORT" 2>/dev/null || true
}

cmd_stop() {
    load_config
    warn "=== Stopping any process on port $PORT ==="
    local pids
    pids="$(port_pids)"
    if [ -z "$pids" ]; then
        echo "No process running on port $PORT."
        return
    fi
    echo "Sending SIGTERM to PID(s): $pids"
    for pid in $pids; do
        kill -15 "$pid" 2>/dev/null || true
    done
    sleep 2
    local remaining
    remaining="$(port_pids)"
    if [ -n "$remaining" ]; then
        warn "Process(es) did not exit on SIGTERM, sending SIGKILL."
        for pid in $remaining; do
            kill -9 "$pid" 2>/dev/null || true
        done
        sleep 1
    fi
    if [ -z "$(port_pids)" ]; then
        info "Port $PORT is now free."
    else
        err "Failed to stop process on port $PORT."
    fi
}

cmd_status() {
    load_config
    local pids
    pids="$(port_pids)"
    if [ -z "$pids" ]; then
        echo "Port $PORT: free"
    else
        echo "Port $PORT: in use by PID(s) $pids"
        ps -p $pids -o pid,cmd 2>/dev/null || true
    fi
}

# ---------- start: fastapi ----------
start_fastapi() {
    cd "$DEST"
    if [ -n "$VENV_PATH" ] && [ -f "$VENV_PATH/bin/activate" ]; then
        echo "Activating venv: $VENV_PATH"
        # shellcheck disable=SC1091
        source "$VENV_PATH/bin/activate"
    else
        warn "No venv found at '$VENV_PATH' — running with system/current Python."
    fi

    local entry="$APP_ENTRY"
    if [ -z "$entry" ]; then
        for candidate in "app.main:app" "main:app" "app:app"; do
            module="${candidate%%:*}"
            module_path="$(echo "$module" | tr '.' '/')"
            if [ -f "${module_path}.py" ] || [ -f "${module_path}/__init__.py" ]; then
                entry="$candidate"
                break
            fi
        done
    fi
    if [ -z "$entry" ]; then
        err "Could not auto-detect FastAPI entry point. Set APP_ENTRY in your config (e.g. app.main:app)."
        exit 1
    fi

    info "Starting uvicorn ($entry) on :$PORT"
    echo "  App:  http://localhost:$PORT"
    echo "  Docs: http://localhost:$PORT/docs"
    exec uvicorn "$entry" --host 0.0.0.0 --port "$PORT" --reload
}

# ---------- start: django ----------
start_django() {
    cd "$DEST"
    if [ -n "$VENV_PATH" ] && [ -f "$VENV_PATH/bin/activate" ]; then
        echo "Activating venv: $VENV_PATH"
        # shellcheck disable=SC1091
        source "$VENV_PATH/bin/activate"
    else
        warn "No venv found at '$VENV_PATH' — running with system/current Python."
    fi

    local manage_path="${DJANGO_MANAGE_PATH:-manage.py}"
    if [ ! -f "$manage_path" ]; then
        err "No '$manage_path' found in $DEST. Set DJANGO_MANAGE_PATH in your config if manage.py lives elsewhere."
        exit 1
    fi

    info "Starting Django dev server on :$PORT"
    echo "  App: http://localhost:$PORT"
    exec python "$manage_path" runserver "0.0.0.0:$PORT"
}

# ---------- start: laravel ----------
start_laravel() {
    cd "$DEST"
    if [ ! -f "artisan" ]; then
        err "No 'artisan' file found in $DEST — is this a Laravel project?"
        exit 1
    fi
    info "Starting Laravel dev server on :$PORT"
    echo "  App: http://localhost:$PORT"
    exec php artisan serve --host 0.0.0.0 --port "$PORT"
}

# ---------- start: yii2 ----------
start_yii2() {
    cd "$DEST"
    local docroot="$PHP_DOCROOT"
    if [ -z "$docroot" ]; then
        if [ -d "web" ]; then
            docroot="web"
        elif [ -d "public" ]; then
            docroot="public"
        else
            err "Could not auto-detect Yii2 webroot. Set PHP_DOCROOT in your config."
            exit 1
        fi
    fi
    info "Starting PHP built-in server for Yii2 on :$PORT (docroot: $docroot)"
    echo "  App: http://localhost:$PORT"
    exec php -S 0.0.0.0:"$PORT" -t "$docroot"
}

start_app() {
    load_config
    SOURCE="$(normalize_windows_path "$SOURCE")"
    local fw
    if [ -n "$RESOLVED_FW" ]; then
        fw="$RESOLVED_FW"
    else
        if ! fw="$(resolve_framework)"; then
            err "Could not auto-detect framework (checked $DEST and $SOURCE)."
            err "Set FRAMEWORK explicitly in your .devsync.conf (fastapi | django | laravel | yii2)."
            exit 1
        fi
        RESOLVED_FW="$fw"
    fi

    # stop any existing instance on this port first
    local pids
    pids="$(port_pids)"
    if [ -n "$pids" ]; then
        warn "Port $PORT already in use — stopping existing process first."
        cmd_stop
    fi

    case "$fw" in
        fastapi) start_fastapi ;;
        django)  start_django ;;
        laravel) start_laravel ;;
        yii2)    start_yii2 ;;
        *)
            err "Unsupported framework: $fw"
            exit 1
            ;;
    esac
}

# ---------- run: sync + start ----------
cmd_run() {
    do_sync
    start_app
}

cmd_run_only() {
    start_app
}

usage() {
    cat <<EOF
devsync — Windows -> WSL sync + dev server runner (FastAPI / Django / Laravel / Yii2)

Usage:
  devsync init                 Interactive setup, writes .devsync.conf
  devsync sync [--dry|--diff]  Sync files from Windows source to WSL dest
  devsync run                  Sync, then start the dev server
  devsync run-only             Start the dev server without syncing
  devsync stop                 Stop whatever is running on the configured port
  devsync status               Show whether the port is in use
  devsync version              Show version

Options:
  -c, --config <path>          Use a specific .devsync.conf instead of the
                                default lookup (./.devsync.conf)
EOF
}

case "$CMD" in
    init)       cmd_init ;;
    sync)       check_dependencies; do_sync ;;
    run)        check_dependencies; cmd_run ;;
    run-only)   check_dependencies; cmd_run_only ;;
    stop)       check_dependencies; cmd_stop ;;
    status)     check_dependencies; cmd_status ;;
    ""|help|-h|--help) usage ;;
    version|--version) echo "devsync $VERSION" ;;
    *)
        err "Unknown command: $CMD"
        usage
        exit 1
        ;;
esac
