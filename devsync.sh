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

# ---------- port auto-detection ----------
detect_port() {
    local dir="$1"
    # 1. Check docker-compose*.yml for the app service port mapping
    local compose_file
    compose_file="$(find "$dir" -maxdepth 1 -name 'docker-compose*.y*ml' 2>/dev/null | head -1)"
    if [ -n "$compose_file" ]; then
        # Look for port mapping like "4000:4000" or "- 4000:4000"
        local port
        port="$(grep -oP '"?\d{4,5}:\d{4,5}"?' "$compose_file" 2>/dev/null | head -1 | grep -oP '^\d{4,5}' || true)"
        if [ -n "$port" ]; then
            echo "$port"
            return
        fi
    fi
    # 2. Check .env / .env.example for PORT= or APP_PORT=
    for envfile in "$dir/.env" "$dir/.env.example" "$dir/env.example"; do
        if [ -f "$envfile" ]; then
            local port
            port="$(grep -oiP '^(APP_)?PORT=\K\d+' "$envfile" 2>/dev/null | head -1 || true)"
            if [ -n "$port" ]; then
                echo "$port"
                return
            fi
        fi
    done
    # 3. Check Dockerfile is being EXPOSE
    local dockerfile
    dockerfile="$(find "$dir" -maxdepth 1 -name 'Dockerfile*' 2>/dev/null | head -1)"
    if [ -n "$dockerfile" ]; then
        local port
        port="$(grep -oP '^EXPOSE\s+\K\d+' "$dockerfile" 2>/dev/null | head -1 || true)"
        if [ -n "$port" ]; then
            echo "$port"
            return
        fi
    fi
    # 4. Default
    echo "8000"
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

# ---------- python version check ----------
check_python_version() {
    local dir="$1"
    local dockerfile
    dockerfile="$(find "$dir" -maxdepth 1 -name 'Dockerfile*' 2>/dev/null | head -1)"
    if [ -z "$dockerfile" ]; then
        return
    fi
    local required_major required_minor
    required_major="$(grep -oP '^FROM python:\K(\d+)' "$dockerfile" 2>/dev/null | head -1 || true)"
    required_minor="$(grep -oP '^FROM python:\d+\.\K(\d+)' "$dockerfile" 2>/dev/null | head -1 || true)"
    if [ -z "$required_major" ]; then
        return
    fi
    local actual_major actual_minor
    actual_major="$(python3 -c 'import sys; print(sys.version_info[0])' 2>/dev/null || echo "0")"
    actual_minor="$(python3 -c 'import sys; print(sys.version_info[1])' 2>/dev/null || echo "0")"
    if [ "$actual_major" -lt "$required_major" ] 2>/dev/null || \
       { [ "$actual_major" -eq "$required_major" ] 2>/dev/null && [ -n "$required_minor" ] && [ "$actual_minor" -lt "$required_minor" ] 2>/dev/null; }; then
        local required_ver="${required_major}"
        [ -n "$required_minor" ] && required_ver="${required_major}.${required_minor}"
        local actual_ver="${actual_major}.${actual_minor}"
        warn "Python version mismatch: project requires ${required_ver}, WSL has ${actual_ver}."
        warn "Some features may not work. Consider installing Python ${required_ver} in WSL."
    fi
}

# ---------- php version check ----------
check_php_version() {
    local dir="$1"
    local composer_json="$dir/composer.json"
    if [ ! -f "$composer_json" ]; then
        return
    fi
    # Extract the minimum PHP version from the "php" constraint, e.g. "^8.2" -> "8.2"
    local required_version
    required_version="$(grep -oP '"php"\s*:\s*"[~^>=]*\K[0-9.]+' "$composer_json" 2>/dev/null | head -1 || true)"
    if [ -z "$required_version" ]; then
        return
    fi
    if ! command -v php >/dev/null 2>&1; then
        warn "PHP is not installed in WSL but composer.json requires PHP ${required_version}."
        warn "Install PHP with: sudo apt install php-cli php-mbstring php-xml php-sqlite3"
        return
    fi
    local required_major required_minor
    required_major="${required_version%%.*}"
    local remainder="${required_version#*.}"
    required_minor="${remainder%%.*}"
    [ -z "$required_minor" ] && required_minor="0"

    local actual_major actual_minor
    actual_major="$(php -r 'echo PHP_MAJOR_VERSION;' 2>/dev/null || echo "0")"
    actual_minor="$(php -r 'echo PHP_MINOR_VERSION;' 2>/dev/null || echo "0")"

    if [ "$actual_major" -lt "$required_major" ] 2>/dev/null || \
       { [ "$actual_major" -eq "$required_major" ] 2>/dev/null && [ "$actual_minor" -lt "$required_minor" ] 2>/dev/null; }; then
        local actual_ver="${actual_major}.${actual_minor}"
        warn "PHP version mismatch: project requires ${required_version}, WSL has ${actual_ver}."
        warn "Some features may not work. Consider installing PHP ${required_version} in WSL."
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

    PORT="$(detect_port "$SOURCE")"
    echo "Detected port: $PORT (from project config)"
    read -rp "Press Enter to use this, or type a different port: " custom_port
    PORT="${custom_port:-$PORT}"

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
        VENV_PATH="venv"
        if [ -d "$DEST/venv" ]; then
            echo "Found existing venv at: $DEST/venv"
        elif [ -d "$DEST/.venv" ]; then
            VENV_PATH=".venv"
            echo "Found existing venv at: $DEST/.venv"
        else
            echo "No venv found — will create one at: $DEST/venv"
        fi
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
    EXTRA_EXCLUDES=("${EXTRA_EXCLUDES[@]+${EXTRA_EXCLUDES[@]}}")
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
    local common=(--exclude=".git/" --exclude=".github/" --exclude=".env" --exclude="logs/" --exclude=".devsync.conf" --exclude="node_modules/" --exclude="localstack/")
    case "$fw" in
        fastapi)
            common+=(--exclude="venv/" --exclude="__pycache__/" --exclude="*.pyc" --exclude=".pytest_cache/")
            ;;
        django)
            common+=(--exclude="venv/" --exclude="__pycache__/" --exclude="*.pyc" --exclude=".pytest_cache/" --exclude="staticfiles/" --exclude="media/" --exclude="db.sqlite3")
            ;;
        laravel)
            common+=(--exclude="vendor/" --exclude="storage/logs/" --exclude="storage/framework/cache/" --exclude="storage/framework/sessions/" --exclude="storage/framework/views/" --exclude="bootstrap/cache/" --exclude="database/*.sqlite" --exclude=".phpunit.cache/" --exclude="public/storage/" --exclude="public/build/" --exclude="public/hot" --exclude="storage/pail/" --exclude="storage/*.key")
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
    if [ ${#EXTRA_EXCLUDES[@]} -gt 0 ]; then
        EXCLUDES+=("${EXTRA_EXCLUDES[@]}")
    fi

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
            rsync -avh --delete "${EXCLUDES[@]}" "$SOURCE/" "$DEST/" || {
                local rc=$?
                if [ $rc -eq 23 ]; then
                    warn "Some files could not be deleted (permission denied) — sync completed with warnings."
                else
                    err "rsync failed with exit code $rc"
                    exit 1
                fi
            }
            echo ""
            info "=== Sync complete ==="
            ;;
    esac

    if [ "$fw" = "fastapi" ] || [ "$fw" = "django" ]; then
        check_python_version "$DEST"
    fi
    if [ "$fw" = "laravel" ] || [ "$fw" = "yii2" ]; then
        check_php_version "$DEST"
    fi
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

# ---------- venv management ----------
ensure_venv() {
    cd "$DEST"
    if [ -z "$VENV_PATH" ]; then
        return
    fi
    if [ -f "$VENV_PATH/bin/activate" ]; then
        echo "Activating venv: $VENV_PATH"
        # shellcheck disable=SC1091
        source "$VENV_PATH/bin/activate"
        return
    fi
    warn "No venv at '$VENV_PATH' — creating one now..."
    if ! python3 -m venv "$VENV_PATH" 2>/dev/null; then
        warn "python3 -m venv failed — 'python3-venv' package may be missing."
        warn "Attempting to install it automatically..."
        if ! sudo apt install -y python3-venv 2>/dev/null; then
            err "Could not install python3-venv. Please run manually:"
            err "  sudo apt install python3-venv"
            exit 1
        fi
        if ! python3 -m venv "$VENV_PATH" 2>/dev/null; then
            err "Failed to create venv even after installing python3-venv."
            err "Check your Python installation: python3 --version"
            exit 1
        fi
    fi
    # shellcheck disable=SC1091
    source "$VENV_PATH/bin/activate"
    pip install --upgrade pip >/dev/null 2>&1 || true
    if [ -f "requirements.txt" ]; then
        info "Installing dependencies from requirements.txt..."
        pip install -r requirements.txt
    elif [ -f "pyproject.toml" ]; then
        info "Installing dependencies from pyproject.toml..."
        pip install -e . 2>/dev/null || pip install .
    else
        warn "No requirements.txt or pyproject.toml found — venv is empty."
        warn "Install your dependencies manually after sync."
    fi
}

# ---------- AWS mock management ----------
ensure_localstack() {
    cd "$DEST"
    local aws_port=4566

    # 1. Check if something is already serving on the AWS mock port.
    #    lsof can't always see Docker-bound ports in WSL, so also try curl.
    local port_in_use=0
    if lsof -ti :"$aws_port" >/dev/null 2>&1; then
        port_in_use=1
    elif curl -s --connect-timeout 2 "http://localhost:$aws_port/_localstack/health" >/dev/null 2>&1; then
        port_in_use=1
    elif curl -s --connect-timeout 2 "http://localhost:$aws_port" >/dev/null 2>&1; then
        port_in_use=1
    fi
    if [ $port_in_use -eq 1 ]; then
        info "AWS mock already running on port $aws_port."
        return
    fi

    # 2. Check if this project uses localstack/moto (looks for localhost:4566 in env files)
    local uses_aws_mock=0
    for envfile in ".env" ".env.example"; do
        if [ -f "$envfile" ] && grep -qi "localhost:4566" "$envfile" 2>/dev/null; then
            uses_aws_mock=1
            break
        fi
    done
    if [ $uses_aws_mock -eq 0 ]; then
        return
    fi

    # 3. Start moto_server as a lightweight AWS mock (no Docker needed)
    warn "AWS mock not running on port $aws_port — starting moto_server..."

    # Ensure moto is installed in the venv
    if ! command -v moto_server >/dev/null 2>&1; then
        if [ -n "${VIRTUAL_ENV:-}" ]; then
            info "Installing moto[server] in venv..."
            pip install "moto[server]" >/dev/null 2>&1 || {
                warn "Failed to install moto. Install manually: pip install moto[server]"
                warn "Then run: moto_server -p $aws_port"
                return
            }
        else
            warn "moto_server not found and no venv active."
            warn "Install manually: pip install moto[server]"
            warn "Then run: moto_server -p $aws_port"
            return
        fi
    fi

    # Start moto_server in background
    moto_server -p "$aws_port" >/dev/null 2>&1 &
    local moto_pid=$!

    # Wait for it to be ready
    local retries=15
    while [ $retries -gt 0 ]; do
        if lsof -ti :"$aws_port" >/dev/null 2>&1 || curl -s --connect-timeout 1 "http://localhost:$aws_port" >/dev/null 2>&1; then
            info "moto_server is ready on port $aws_port (PID: $moto_pid)."
            return
        fi
        sleep 1
        retries=$((retries - 1))
    done
    warn "moto_server did not become ready in time. Try starting it manually: moto_server -p $aws_port"
}

# ---------- start: fastapi ----------
start_fastapi() {
    ensure_venv
    ensure_localstack

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
    ensure_venv
    ensure_localstack

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

# ---------- test ----------
cmd_test() {
    load_config
    SOURCE="$(normalize_windows_path "$SOURCE")"
    local fw
    if [ -n "$RESOLVED_FW" ]; then
        fw="$RESOLVED_FW"
    else
        if ! fw="$(resolve_framework)"; then
            err "Could not auto-detect framework."
            err "Set FRAMEWORK explicitly in your .devsync.conf."
            exit 1
        fi
        RESOLVED_FW="$fw"
    fi

    cd "$DEST"

    case "$fw" in
        fastapi|django)
            ensure_venv
            if [ ! -f "pytest.ini" ] && [ ! -f "pyproject.toml" ] && [ ! -f "setup.cfg" ]; then
                warn "No pytest configuration found (pytest.ini, pyproject.toml, or setup.cfg)."
            fi
            if ! python -c 'import pytest' 2>/dev/null; then
                warn "pytest not installed in venv — installing now..."
                pip install pytest pytest-asyncio >/dev/null 2>&1 || {
                    err "Failed to install pytest. Install manually: pip install pytest pytest-asyncio"
                    exit 1
                }
            fi
            info "Running pytest..."
            echo ""
            exec python -m pytest
            ;;
        laravel|yii2)
            if ! command -v phpunit >/dev/null 2>&1 && [ ! -f "vendor/bin/phpunit" ]; then
                err "phpunit not found. Install dependencies first: composer install"
                exit 1
            fi
            info "Running phpunit..."
            echo ""
            if [ -f "vendor/bin/phpunit" ]; then
                exec vendor/bin/phpunit
            else
                exec phpunit
            fi
            ;;
        *)
            err "Unsupported framework for testing: $fw"
            exit 1
            ;;
    esac
}

# ---------- update: git pull + reinstall ----------
cmd_update() {
    local data_dir="$HOME/.local/share/devsync"
    local repo_marker="$data_dir/.source-repo"

    if [ ! -f "$repo_marker" ]; then
        err "Cannot determine source repo path."
        err "Was devsync installed with install.sh? If not, re-run install.sh"
        err "from your cloned devsync repo."
        exit 1
    fi

    local repo_dir
    repo_dir="$(cat "$repo_marker")"

    if [ ! -d "$repo_dir" ]; then
        err "Source repo not found at: $repo_dir"
        err "It may have been moved or deleted. Re-clone and re-run install.sh."
        exit 1
    fi

    if [ ! -d "$repo_dir/.git" ]; then
        err "$repo_dir is not a git repository."
        err "Cannot update. Re-clone the devsync repo and re-run install.sh."
        exit 1
    fi

    note "=== devsync update ==="
    echo ""
    info "Pulling latest changes from $repo_dir..."
    (cd "$repo_dir" && git pull)

    echo ""
    info "Reinstalling..."
    bash "$repo_dir/install.sh"

    echo ""
    info "=== Update complete ==="
    note "Run 'devsync version' to verify."
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
  devsync test                 Run the project's test suite (pytest/phpunit)
  devsync update               Pull latest from git and reinstall the tool
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
    test)       check_dependencies; cmd_test ;;
    update)     cmd_update ;;
    ""|help|-h|--help) usage ;;
    version|--version) echo "devsync $VERSION" ;;
    *)
        err "Unknown command: $CMD"
        usage
        exit 1
        ;;
esac
