# devsync

devsync is a CLI tool for developers whose laptop or PC is too low-spec to run Docker Desktop comfortably. Docker Desktop consumes significant RAM and CPU even when idle, which is problematic on constrained hardware. devsync avoids this by using WSL (Windows Subsystem for Linux) itself as a lightweight local testing environment. The workflow: keep your git-tracked source code on the Windows side (C: drive, V: drive, wherever you normally work), use devsync to one-way sync that code into a WSL folder, then run the app's real dev server directly in WSL. This gives you a server-like Linux environment for testing without the overhead of virtualized containers.

This tool is aimed at developers on constrained hardware who cannot run Docker Desktop comfortably. It is not a general Docker replacement for everyone. For projects that depend on AWS services (DynamoDB, S3), devsync can automatically start [moto](https://github.com/getmoto/moto) as a lightweight AWS mock server — no Docker required.

## Why WSL instead of Docker

Both WSL and Docker ultimately run on a Linux kernel. Docker Desktop adds a container runtime, a VM layer, and a management daemon on top of that kernel, all of which consume memory and CPU even at idle. If your goal is simply to run your app in a Linux environment for local testing, WSL already provides that kernel without the extra overhead. devsync leverages this by syncing your Windows-side source code into the WSL filesystem and launching the dev server there directly. No containers, no daemon, no VM management process eating resources in the background.

## Requirements

- **WSL2** with a Linux distribution installed (Ubuntu, Debian, etc.)
- **rsync** installed inside WSL (`sudo apt install rsync` or equivalent)
- **git** installed inside WSL
- **lsof** installed inside WSL (used by `devsync stop`, `devsync status`, and AWS mock detection)
- **Python** installed inside WSL, if using FastAPI or Django
- **python3-venv** installed inside WSL (`sudo apt install python3-venv`) — auto-installed by devsync if missing
- **PHP** installed inside WSL, if using Laravel or Yii2
- For FastAPI: **uvicorn** listed in your `requirements.txt` (devsync installs it into the venv automatically)
- For Django: a `manage.py` in the project root (or a path you configure)
- For AWS-dependent projects: **moto** is auto-installed into the venv if your project references `localhost:4566` in `.env` or `.env.example`

## Installation

Clone the repository into your WSL filesystem, not a Windows-mounted path. Cloning into `/mnt/c/...` or `/mnt/v/...` works but causes slow file I/O across the WSL/Windows boundary. Clone directly into your Linux home directory instead:

```bash
git clone <repo-url> ~/devsync
cd ~/DevSync
chmod +x install.sh
./install.sh
source ~/.bashrc   # or open a new terminal
devsync help       # verify installation
```

The installer does three things:

1. Copies `devsync.sh` into `~/.local/share/devsync/devsync.sh` and makes the copy executable. The git-tracked original in your repo is never modified, so `git status` stays clean on WSL.
2. Symlinks `~/.local/bin/devsync` to that copy.
3. Adds `~/.local/bin` to your `PATH` in your shell rc file (`.bashrc` or `.zshrc`, auto-detected) if it is not already there.

The installer also records the path to your cloned repo in `~/.local/share/devsync/.source-repo` so that `devsync update` can find it later. The installer is idempotent and safe to re-run.

## Quick start / first project setup

Run `devsync init` once, from inside (or pointed at) the WSL destination folder where you want your testing copy to live:

```bash
cd ~/my-project
devsync init
```

The interactive setup will:

- **Ask for Windows source path** — e.g. `/mnt/c/Users/you/project` or `V:\project` (Windows paths are auto-converted to `/mnt/v/...`)
- **Auto-detect WSL destination** — uses the current directory as the destination
- **Ask for language** — Python, PHP, or "not sure" (auto-detect)
- **Ask for framework** — narrowed to the chosen language (FastAPI/Django for Python, Laravel/Yii2 for PHP), or auto-detect
- **Auto-detect port** — scans `docker-compose*.yml`, `.env` files, and `Dockerfile` `EXPOSE` directives for port mappings (e.g. `4000:4000` or `EXPOSE 8000`). Press Enter to accept or type a different port.
- **Auto-detect venv** — checks for existing `venv/` or `.venv/` in the destination. If none exists, one is created on first `run`.
- **Ask for framework-specific settings** — FastAPI entry point (e.g. `app.main:app`), Django `manage.py` path, or PHP webroot

This writes a `.devsync.conf` file into the destination folder. After that, every other command auto-finds `./.devsync.conf` in the current directory, or accepts an explicit path via `-c/--config <path>`.

## Command reference

| Command | Description |
|---|---|
| `devsync init` | Interactive setup. Writes `.devsync.conf` in the destination folder. |
| `devsync sync` | One-way rsync from the Windows source folder to the WSL destination. Preserves local-only files (see below). |
| `devsync sync --dry` | Preview what would change without copying any files. |
| `devsync sync --diff` | File-by-file diff comparing the Windows source against the WSL destination. |
| `devsync run` | Sync files, then start the dev server. |
| `devsync run-only` | Start the dev server without syncing first. |
| `devsync stop` | Kill whatever process is running on the configured port. |
| `devsync status` | Show whether the configured port is in use, and by which process. |
| `devsync test` | Run the project's test suite in the venv (pytest for Python, phpunit for PHP). |
| `devsync update` | Pull the latest from git and reinstall the tool. |
| `devsync help` | Show usage information. |
| `devsync version` | Show the installed version. |

All commands accept `-c <path>` or `--config <path>` to specify a `.devsync.conf` file explicitly instead of relying on the default `./.devsync.conf` lookup.

### Typical daily workflow

```bash
cd ~/my-project        # the WSL destination folder
devsync run            # sync from Windows, then start the dev server
```

Edit code on the Windows side as usual, then re-run `devsync run` to sync the latest changes and restart the server.

## Config file reference

The `.devsync.conf` file is a plain shell script that gets sourced by devsync. It is generated by `devsync init` and can be hand-edited at any time. It contains no secrets, just paths and settings. Because it contains machine-specific absolute paths, it should be gitignored if the WSL destination folder is itself a tracked repository.

| Field | Description |
|---|---|
| `SOURCE` | Windows-mounted source path, e.g. `/mnt/c/Users/you/project`. This is where your git-tracked code lives. |
| `DEST` | WSL destination path where files are synced to and the dev server runs. |
| `FRAMEWORK` | `auto`, `fastapi`, `django`, `laravel`, or `yii2`. When set to `auto`, devsync detects the framework by checking for marker files (`artisan` for Laravel, `yii` for Yii2, `manage.py` for Django, `fastapi` in `requirements.txt` or `pyproject.toml` for FastAPI). |
| `PORT` | Port the dev server binds to. Auto-detected from `docker-compose*.yml`, `.env` files, or `Dockerfile` `EXPOSE` directive during `init`. Default: `8000`. |
| `VENV_PATH` | Path to a Python virtual environment, relative to `DEST`. Auto-detected during `init` (`venv/` or `.venv/`). If no venv exists, one is created automatically on first `run`/`run-only` and dependencies are installed from `requirements.txt` or `pyproject.toml`. Set blank to skip venv entirely. |
| `APP_ENTRY` | FastAPI entry point in `module:app` format, e.g. `app.main:app`. If blank, devsync tries `app.main:app`, `main:app`, then `app:app`. |
| `DJANGO_MANAGE_PATH` | Path to `manage.py`, relative to `DEST`. Default: `manage.py`. |
| `PHP_DOCROOT` | Webroot directory for Yii2, relative to `DEST`. If blank, devsync auto-detects `web/` or `public/`. |
| `LARAVEL_DEPS` | Laravel only: how to handle `vendor/` dependencies. `composer` (default) — run `composer install` in WSL when `vendor/` is missing or `composer.json` changed. `copy` — sync `vendor/` from the Windows source (use when `composer install` fails due to old or private packages). |
| `EXTRA_EXCLUDES` | Bash array of additional rsync exclude patterns beyond the framework defaults. e.g. `EXTRA_EXCLUDES=("storage/app/*" "some-other-dir/")` |

### Files preserved during sync

devsync uses `rsync --delete` but excludes local-only files so they are never overwritten by the Windows source. The following are always excluded:

- `.git/`, `.github/`, `.env`, `logs/`, `.devsync.conf`, `node_modules/`, `localstack/`

Framework-specific excludes:

- **FastAPI**: `venv/`, `__pycache__/`, `*.pyc`, `.pytest_cache/`
- **Django**: `venv/`, `__pycache__/`, `*.pyc`, `.pytest_cache/`, `staticfiles/`, `media/`, `db.sqlite3`
- **Laravel**: `vendor/` (only when `LARAVEL_DEPS=composer`; synced from source when `LARAVEL_DEPS=copy`), `storage/logs/`, `storage/framework/cache/`, `storage/framework/sessions/`, `storage/framework/views/`, `bootstrap/cache/`, `database/*.sqlite`, `.phpunit.cache/`, `public/storage/`, `public/build/`, `public/hot`, `storage/pail/`, `storage/*.key`
- **Yii2**: `vendor/`, `runtime/`

Additional excludes can be added via `EXTRA_EXCLUDES` in the config file.

### AWS mock (moto) auto-management

If your project references `localhost:4566` in `.env` or `.env.example` (the standard localstack/moto endpoint), devsync automatically manages an AWS mock server on `devsync run` and `devsync run-only`:

1. **Port 4566 already in use** — devsync detects it and skips (works with localstack, moto, or any other AWS mock already running).
2. **Port 4566 is free** — devsync installs `moto[server]` into your venv (if not already installed) and starts `moto_server -p 4566` in the background.
3. **Waits for readiness** — polls port 4566 for up to 15 seconds before starting the dev server.

This means you can develop and test AWS-dependent applications (DynamoDB, S3) without Docker or localstack. Moto runs as a lightweight Python process inside your venv.

If you prefer to use localstack with Docker instead, simply start it manually before `devsync run` — devsync will detect port 4566 in use and skip moto.

### Virtual environment auto-management

For Python projects (FastAPI, Django), devsync automatically manages the virtual environment:

1. **During `init`** — checks for existing `venv/` or `.venv/` in the destination directory and uses it. If neither exists, defaults to `venv/`.
2. **During `run`/`run-only`** — if the venv doesn't exist yet, creates it with `python3 -m venv`, installs `moto[server]` if needed, then installs dependencies from `requirements.txt` (or `pyproject.toml` as fallback). If `python3-venv` is missing, devsync attempts to install it via `apt`.
3. **Subsequent runs** — the venv already exists, so it just activates and starts the server.

Set `VENV_PATH` to blank in `.devsync.conf` to skip venv entirely and use system Python.

### Laravel dependency management

For Laravel projects, devsync needs `vendor/` to be present in the WSL destination for the app to run. There are two strategies, chosen during `devsync init` and stored as `LARAVEL_DEPS` in `.devsync.conf`:

1. **`composer`** (default) — `vendor/` is excluded from sync. On `devsync run`, if `vendor/` is missing or `composer.json` has changed since the last install, devsync runs `composer install` in WSL. This builds `vendor/` for the WSL platform, which is the recommended approach. Requires `composer` to be installed in WSL (`sudo apt install composer`).

2. **`copy`** — `vendor/` is synced from the Windows source along with everything else. No `composer install` is run. Use this when `composer install` fails (e.g. packages that are too old, private, or require a PHP version not available in WSL). Note that `vendor/bin/` executables may have Windows line endings or lack the executable bit — run `php vendor/bin/pest` instead of `./vendor/bin/pest` if you encounter issues.

## Supported frameworks

| Language | Framework | Dev server command |
|---|---|---|
| Python | FastAPI | `uvicorn <entry> --host 0.0.0.0 --port <port> --reload` |
| Python | Django | `python manage.py runserver 0.0.0.0:<port>` |
| PHP | Laravel | `php artisan serve --host 0.0.0.0 --port <port>` |
| PHP | Yii2 | `php -S 0.0.0.0:<port> -t <docroot>` |

## Updating and uninstalling

### Updating

To update devsync to the latest version, run:

```bash
devsync update
```

This runs `git pull` in your cloned repo and then re-runs `install.sh` to copy the updated `devsync.sh` into place. The git-tracked files in your repo are never modified by the install process, so `git status` stays clean.

### Uninstalling

```bash
cd ~/devsync
./install.sh uninstall
```

This removes the symlink from `~/.local/bin/devsync` and the copied files from `~/.local/share/devsync/`. PATH entries in your shell rc file are left in place (harmless if unused). The cloned repository itself is not deleted; remove it manually if desired:

```bash
rm -rf ~/devsync
```

## Troubleshooting

### `devsync: command not found` after install

The installer adds `~/.local/bin` to your `PATH` in your shell rc file, but this does not take effect in your current terminal automatically. Run `source ~/.bashrc` (or `source ~/.zshrc` if using zsh), or simply open a new terminal. Verify with `devsync help`.

Do not run the installer with `sudo`. It installs per-user into `$HOME/.local/bin`. Running with sudo installs into `/root` instead of your user home, making the tool unavailable to your user. If you already did this, clean up the root install:

```bash
sudo rm -f /root/.local/bin/devsync
```

Then re-run the installer without sudo:

```bash
cd ~/devsync
./install.sh
source ~/.bashrc
```

### Cloning onto `/mnt/c/` is slow

If you cloned the devsync repo into a Windows-mounted path like `/mnt/c/...` or `/mnt/v/...`, file I/O across the WSL/Windows boundary is significantly slower than operating within the native Linux filesystem. The installer will warn you if it detects this. To fix it, re-clone into your Linux home directory:

```bash
git clone <repo-url> ~/devsync
cd ~/devsync
./install.sh
```

The same advice applies to your project's WSL destination folder: keep it in the Linux filesystem (e.g. `~/my-project`), not under `/mnt/`.

### Port already in use

`devsync run` and `devsync run-only` will automatically stop any existing process on the configured port before starting the dev server. If you need to manually check or stop a process, use:

```bash
devsync status    # show what is using the port
devsync stop      # kill it
```

### Framework not auto-detected

Auto-detection checks for the following marker files in the destination folder first, then falls back to the source folder:

- `artisan` — Laravel
- `yii` — Yii2
- `manage.py` — Django
- `fastapi` in `requirements.txt` or `pyproject.toml` — FastAPI

If detection fails, set `FRAMEWORK` explicitly in `.devsync.conf` to one of `fastapi`, `django`, `laravel`, or `yii2`. You can also re-run `devsync init` and choose the framework manually instead of relying on auto-detect.

### Python version mismatch

After sync, devsync checks the project's `Dockerfile*` for the Python version (e.g. `FROM python:3.13`) and compares it to the WSL Python version. If WSL has an older version, a warning is shown:

```
Python version mismatch: project requires 3.13, WSL has 3.10.
Some features may not work. Consider installing Python 3.13 in WSL.
```

This is a warning only — the sync and server startup proceed regardless. To fix it, install the required Python version in WSL (e.g. `sudo apt install python3.13`).

### PHP version mismatch

After sync, devsync checks the project's `composer.json` for the PHP version constraint (e.g. `"php": "^8.2"`) and compares it to the WSL PHP version. If WSL has an older version, a warning is shown:

```
PHP version mismatch: project requires 8.2, WSL has 8.1.
Some features may not work. Consider installing PHP 8.2 in WSL.
```

This is a warning only — the sync and server startup proceed regardless. To fix it, install the required PHP version in WSL (e.g. `sudo apt install php8.2-cli php8.2-mbstring php8.2-xml php8.2-sqlite3`).

### rsync permission errors on localstack directory

If you previously ran localstack with Docker, the `localstack/` directory may contain root-owned files that rsync cannot delete. devsync excludes `localstack/` from sync automatically. If you still see errors, remove the directory manually:

```bash
sudo rm -rf localstack/
```

### Windows paths not recognized

If you entered a Windows-style path (e.g. `V:\project`) during `devsync init`, it is automatically converted to the WSL equivalent (`/mnt/v/project`). If you hand-edited `.devsync.conf` with a Windows path, devsync normalizes it at runtime. No manual conversion needed.

## License

This project is licensed under the GNU General Public License v3. See the [LICENSE](LICENSE) file for details.
