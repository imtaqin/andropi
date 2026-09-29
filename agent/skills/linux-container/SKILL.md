---
name: linux-container
description: Install and run Linux software (Python, Node.js, compilers, databases, CLIs) on this Android phone through AndroPI's Debian/Alpine container. Use whenever a task needs a package, runtime or tool that is not already on PATH, or when a command fails with "not found".
---

# Linux container

AndroPI can run a real Linux userland (Debian or Alpine) through proot. The
home folder and workspace are mounted at the same paths inside, so files you
create in either place are the same files.

## Check what you have

```sh
command -v apt-get && echo debian-shell   # your shell is already inside Debian
command -v apk && echo alpine-shell       # already inside Alpine
command -v box && box -c 'cat /etc/os-release | head -1'   # container exists, you are outside
```

- If `apt-get` or `apk` works directly, every command already runs inside the
  container. Install with `apt-get install -y <pkg>` or `apk add <pkg>`.
- If only `box` works, run Linux commands as `box -c '<command>'`.
- If `box` prints "not installed", tell the user to install it in
  AndroPI under Settings → Linux container. Do not try to install it yourself.

## Installing things

Debian:

```sh
apt-get update                    # once per session before the first install
apt-get install -y python3 python3-pip python3-venv nodejs npm build-essential
```

Alpine: `apk add python3 py3-pip nodejs npm build-base`.

- Python: Debian marks the system Python as externally managed. Use a venv
  (`python3 -m venv .venv && . .venv/bin/activate && pip install ...`) or
  `pip install --break-system-packages` for quick one-offs.
- Newer Node.js than the distro ships: `npm install -g n && n lts`, or use the
  NodeSource setup script found with web_search.
- When unsure of a package name or install method, use `web_search` first.

## Limits

- You are root inside, but it is emulated (proot): no kernel modules, no
  systemd/services, no Docker, no mounting. Run servers in the foreground or
  with `nohup ... &`.
- It is ARM64 (aarch64). Pick arm64/aarch64 downloads.
- Processes are slower than native; avoid unbounded builds.
