# RIOT-CLEAN

**Destructive server cleanup utility for Ubuntu and Debian.**

RIOT-CLEAN removes Docker Engine and related Docker/container runtime packages and data from an APT-based Ubuntu/Debian server.

## What it removes

- Docker Engine packages and Docker CLI packages installed through APT
- Docker Compose plugin and Buildx plugin packages
- Docker containers, images, networks, volumes and the standard Docker data directory
- Standard containerd and BuildKit data/configuration directories
- Docker Snap installation, when Snap is available
- Docker APT source entries and signing keys
- Standalone Docker Compose binaries in standard locations
- Docker-specific APT cache/dependencies where APT considers them unused

## Important: destructive operation

**This script permanently deletes Docker volumes and all data stored inside them.** This may include PostgreSQL, MySQL, Redis, application uploads, and other persistent data.

Back up anything important before running it.

The script:
- Requires root privileges.
- Supports Ubuntu and Debian with APT.
- Stops if it detects active kubelet, k3s, RKE2, or MicroK8s containerd services.
- Does not intentionally remove Podman, Kubernetes packages, firewall rules, SSH, kernel packages, or network configuration.
- Preserves a custom Docker data-root unless the operator explicitly confirms its deletion interactively. In `--yes` mode, a custom data-root is preserved.

## Usage

Download and run:

```bash
curl -fsSLO https://raw.githubusercontent.com/bjo163/RIOTSCRIPT/main/riot-clean.sh
sudo bash riot-clean.sh
```

Read the warning and type:

```text
WIPE-DOCKER
```

For unattended use (standard paths only; custom data-root is preserved):

```bash
sudo bash riot-clean.sh --yes
```

## After cleanup

Review the report printed by the script. Reboot when convenient:

```bash
sudo reboot
```

Verify that Docker commands and services are absent:

```bash
command -v docker || true
command -v dockerd || true
command -v containerd || true
systemctl status docker docker.socket containerd
```

A missing command or unit is expected if it was fully removed.

## Scope limitations

This is a Docker cleanup tool, not a general-purpose VPS reset. It does not wipe user data, SSH configuration, firewall policies, network interfaces, Podman, Kubernetes installations, or arbitrary application directories. Review the script before running it on production infrastructure.
