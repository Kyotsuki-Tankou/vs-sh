# vs.sh

VS Code over SSH in **one Bash file: `vs.sh`**. Then you can run your [d.sh](https://github.com/SiriusNEO/d.sh) on the familiar VS Code Web UI.

Bootstrap a self-contained, official [code-server](https://github.com/coder/code-server) instance onto any remote Linux host, tunnel it seamlessly through your existing SSH connection, and open it directly in your local browser — without opening firewall ports, requiring root privileges, or needing internet access on the remote machine.

```
local curl/download
     ↓
local cache (~/.cache/vs.sh)
     ↓
    scp
     ↓
remote install (~/.cache/vs.sh/releases)
     ↓
code-server on remote Unix socket
     ↓
existing SSH connection (-L forward)
     ↓
http://127.0.0.1:8765
```

---

## Highlights

- **Single file, zero configuration**: Just download `vs.sh` and run it.
- **Air-gapped & intranet friendly**: By default (`--transfer=always`), all artifacts are downloaded and cached locally and pushed to the remote host via `scp`. The remote machine **never** needs outbound internet access.
- **Zero root permissions needed**: Installs cleanly in user-space under `~/.cache/vs.sh`. Leaves system packages untouched.
- **Secure Unix domain sockets**: code-server binds to a private Unix socket on the remote machine and forwards through SSH to `127.0.0.1`. No remote TCP ports are opened.
- **Clean lifecycle management**: Automatically stops the remote server when your interactive SSH shell exits (or preserves it with `--keep-server`, with idle timeout protection).
- **Smart tilde expansion**: Safely normalizes local `~` and `~/project` arguments so they expand to the *remote* user's home directory.

---

## Quick Start

### 1. Download `vs.sh`

```bash
curl -fsSL https://raw.githubusercontent.com/Kyotsuki-Tankou/vs-sh/main/vs.sh -o vs.sh
chmod +x vs.sh
```

### 2. Connect & Launch

Launch an interactive session and open VS Code in your browser:

```bash
# Connect and open remote home directory
./vs.sh server

# Open a specific workspace
./vs.sh user@gpu-box ~/projects/my-app

# Specify custom SSH port and identity file
./vs.sh -p 2222 -i ~/.ssh/id_ed25519 user@gpu-box /data/project
```

Once connected, `vs.sh` will:
1. Probe the remote system (architecture, glibc, existing installation).
2. Download and cache the official code-server release locally (if not already cached).
3. Upload and extract code-server into `~/.cache/vs.sh/releases/` on the remote host.
4. Launch code-server bound to an isolated Unix socket with authentication disabled (protected by SSH).
5. Establish dynamic port forwarding to your local machine (e.g. `127.0.0.1:8765`).
6. Automatically open the Web UI in your default browser and drop you into an interactive SSH shell.

---

## Usage & Options

```
vs.sh [options] HOST [REMOTE_DIR]
```

### Transfer Modes (`--transfer`)

| Mode | Behavior | Use Case |
| :--- | :--- | :--- |
| `always` *(default)* | Download and cache locally, upload via `scp`, install remotely. Remote Internet is **never** accessed. | Strict firewalls, GPU clusters, air-gapped or intranet servers. |
| `auto` | Try local download + `scp` first; fall back to remote `curl` if local transfer fails. | General networks with mixed connectivity. |
| `none` | Never upload from local; remote machine downloads code-server directly via `curl`. | Slow local upload speeds or fast remote connection. |

### CLI Options

| Option | Description | Default |
| :--- | :--- | :--- |
| `--transfer MODE` | Transfer policy: `always`, `auto`, or `none`. | `always` |
| `--code-version VER` | Target code-server version (e.g., `4.136.2`). | `4.136.2` |
| `--download-base URL` | Custom mirror or artifact download base URL. | GitHub Releases |
| `--cache-dir DIR` | Local artifact download cache directory. | `~/.cache/vs.sh` |
| `-l, --local-port PORT` | Local browser port (picks first free in 8765..8799). | `8765..8799` |
| `--idle SECONDS` | Idle shutdown timeout (seconds, must be > 60). | `900` (15m) |
| `--no-open` | Do not automatically launch the local browser. | Disabled |
| `--keep-server` | Keep code-server running after SSH shell exits. | Disabled |

### SSH Options

These arguments are passed directly to `ssh` and `scp`:

- `-p, --ssh-port PORT`: Remote SSH port
- `-i, --identity FILE`: Private key file
- `-J, --jump HOST`: Jump host / ProxyJump specification
- `-F, --ssh-config FILE`: Alternative SSH configuration file
- `-o, --ssh-option OPTION`: Custom OpenSSH option (e.g., `-o StrictHostKeyChecking=no`)

---

## Environment Variables

All settings can be pre-configured via environment variables:

| Variable | Matching Flag | Default |
| :--- | :--- | :--- |
| `VS_TRANSFER` | `--transfer` | `always` |
| `VS_PORT` | `--local-port` | Automatic (`8765`..`8799`) |
| `VS_IDLE_TIMEOUT` | `--idle` | `900` |
| `VS_CODE_SERVER_VERSION` | `--code-version` | `4.136.2` |
| `VS_DOWNLOAD_BASE` | `--download-base` | Official GitHub Releases |
| `VS_CACHE_DIR` | `--cache-dir` | `~/.cache/vs.sh` |

---

## System Requirements

### Local Machine (Client)
- **OS**: Linux, macOS, WSL (Windows Subsystem for Linux)
- **Tools**: `bash`, `ssh`, `scp`, `curl`

### Remote Host (Server)
- **OS**: Linux (`x86_64` / `amd64` or `aarch64` / `arm64`)
- **Libc**: `glibc`-based distributions (Ubuntu, Debian, CentOS, RHEL, Fedora, Rocky, Arch, etc.)
- **Tools**: `bash`, `tar` (and `curl` only if using `--transfer=none` or fallback)
- **Privileges**: Standard user account (root is **not** required)

---

## License

[MIT](LICENSE)
