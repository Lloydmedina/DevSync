# devsync

devsync is a CLI tool for developers whose laptop or PC is too low-spec to run Docker Desktop comfortably. Docker Desktop consumes significant RAM and CPU even when idle, which is problematic on constrained hardware. devsync avoids this by using WSL (Windows Subsystem for Linux) itself as a lightweight local testing environment. The workflow: keep your git-tracked source code on the Windows side (C: drive, V: drive, wherever you normally work), use devsync to one-way sync that code into a WSL folder, then run the app's real dev server directly in WSL. This gives you a server-like Linux environment for testing without the overhead of virtualized containers.

This tool is aimed at developers on constrained hardware who cannot run Docker Desktop comfortably. It is not a general Docker replacement for everyone.

## Why WSL instead of Docker

Both WSL and Docker ultimately run on a Linux kernel. Docker Desktop adds a container runtime, a VM layer, and a management daemon on top of that kernel, all of which consume memory and CPU even at idle. If your goal is simply to run your app in a Linux environment for local testing, WSL already provides that kernel without the extra overhead. devsync leverages this by syncing your Windows-side source code into the WSL filesystem and launching the dev server there directly. No containers, no daemon, no VM management process eating resources in the background.

## Requirements

- **WSL2** with a Linux distribution installed (Ubuntu, Debian, etc.)
- **rsync** installed inside WSL (`sudo apt install rsync` or equivalent)
- **git** installed inside WSL
- **lsof** installed inside WSL (used by `devsync stop` and `devsync status`)
- **Python** installed inside WSL, if using FastAPI or Django
- **PHP** installed inside WSL, if using Laravel or Yii2
- For FastAPI: **uvicorn** available in your venv or system Python
- For Django: a `manage.py` in the project root (or a path you configure)

## Installation

Clone the repository into your WSL filesystem, not a Windows-mounted path. Cloning into `/mnt/c/...` or `/mnt/v/...` works but causes slow file I/O across the WSL/Windows boundary. Clone directly into your Linux home directory instead:

```bash
git clone <repo-url> ~/devsync
cd ~/devsync
chmod +x install.sh
./install.sh
source ~/.bashrc   # or open a new terminal
devsync help       # verify installation
```

The installer does three things:

1. Symlinks `devsync.sh` into `~/.local/bin/devsync`.
2. Adds `~/.local/bin` to your `PATH` in your shell rc file (`.bashrc` or `.zshrc`, auto-detected) if it is not already there.
3. Makes `devsync.sh` executable.

Because the installation is a symlink, running `git pull` later updates the tool with no reinstall needed. The installer is idempotent and safe to re-run.

## Quick start / first project setup

Run `devsync init` once, from inside (or pointed at) the WSL destination folder where you want your testing copy to live:

```bash
cd ~/my-project
devsync init
```

The interactive prompts will ask for:

- **Windows source path** — e.g. `/mnt/c/Users/you/project` or `/mnt/v/projects/my-project`
- **WSL destination path** — the local testing copy, e.g. `~/my-project`
- **Language** — Python, PHP, or "not sure" (auto-detect)
- **Framework** — narrowed to the chosen language (FastAPI/Django for Python, Laravel/Yii2 for PHP), or auto-detect
- **Port** — the port the dev server will bind to (default 8000)
- **Framework-specific settings** — Python venv path, FastAPI entry point (e.g. `app.main:app`), Django `manage.py` path, or PHP webroot

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
| `PORT` | Port the dev server binds to. Default: `8000`. |
| `VENV_PATH` | Path to a Python virtual environment, relative to `DEST`. Default: `venv`. Set blank to skip venv activation. |
| `APP_ENTRY` | FastAPI entry point in `module:app` format, e.g. `app.main:app`. If blank, devsync tries `app.main:app`, `main:app`, then `app:app`. |
| `DJANGO_MANAGE_PATH` | Path to `manage.py`, relative to `DEST`. Default: `manage.py`. |
| `PHP_DOCROOT` | Webroot directory for Yii2, relative to `DEST`. If blank, devsync auto-detects `web/` or `public/`. |
| `EXTRA_EXCLUDES` | Bash array of additional rsync exclude patterns beyond the framework defaults. e.g. `EXTRA_EXCLUDES=("storage/app/*" "some-other-dir/")` |

### Files preserved during sync

devsync uses `rsync --delete` but excludes local-only files so they are never overwritten by the Windows source. The following are always excluded:

- `.git/`, `.github/`, `.env`, `logs/`, `.devsync.conf`, `node_modules/`

Framework-specific excludes:

- **FastAPI**: `venv/`, `__pycache__/`, `*.pyc`, `.pytest_cache/`
- **Django**: `venv/`, `__pycache__/`, `*.pyc`, `.pytest_cache/`, `staticfiles/`, `media/`, `db.sqlite3`
- **Laravel**: `vendor/`, `storage/logs/`, `storage/framework/cache/`, `storage/framework/sessions/`, `storage/framework/views/`, `bootstrap/cache/`
- **Yii2**: `vendor/`, `runtime/`

Additional excludes can be added via `EXTRA_EXCLUDES` in the config file.

## Supported frameworks

| Language | Framework | Dev server command |
|---|---|---|
| Python | FastAPI | `uvicorn <entry> --host 0.0.0.0 --port <port> --reload` |
| Python | Django | `python manage.py runserver 0.0.0.0:<port>` |
| PHP | Laravel | `php artisan serve --host 0.0.0.0 --port <port>` |
| PHP | Yii2 | `php -S 0.0.0.0:<port> -t <docroot>` |

## Updating and uninstalling

### Updating

Because `install.sh` symlinks `devsync.sh` into your PATH, updating is just a git pull:

```bash
cd ~/devsync
git pull
```

The symlink stays current. No reinstall is needed.

### Uninstalling

```bash
cd ~/devsync
./install.sh uninstall
```

This removes the symlink from `~/.local/bin/devsync`. PATH entries in your shell rc file are left in place (harmless if unused). The cloned repository itself is not deleted; remove it manually if desired:

```bash
rm -rf ~/devsync
```

## Troubleshooting

### `devsync: command not found` after install

The installer adds `~/.local/bin` to your `PATH` in your shell rc file, but this does not take effect in your current terminal automatically. Run `source ~/.bashrc` (or `source ~/.zshrc` if using zsh), or simply open a new terminal. Verify with `devsync help`.

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

## License

This project is licensed under the GNU General Public License v3. See the [LICENSE](LICENSE) file for details.
