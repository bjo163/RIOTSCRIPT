# R!OT SCRIPT

**Controlled server cleanup tools for Debian and Ubuntu.**

RIOTSCRIPT provides two separate utilities. They are intentionally conservative: they clean selected application software while preserving the operating system and remote access.

## Tools

### 1. RIOT-CLEAN — Docker purge

File: `riot-clean.sh`

Removes Docker Engine and related container runtime packages/data, including:
- Containers, images, networks, volumes and Docker data
- Docker/containerd/BuildKit packages and standard configuration
- Docker Snap installation and Docker APT source/key files
- Standard standalone Docker Compose binaries

**Warning:** Docker volumes may contain databases, uploads and other persistent data. This operation permanently deletes them.

Run:
```bash
curl -fsSLO https://raw.githubusercontent.com/bjo163/RIOTSCRIPT/main/riot-clean.sh
sudo bash riot-clean.sh
```

Type `WIPE-DOCKER` when prompted. For unattended use, `sudo bash riot-clean.sh --yes` removes standard Docker paths; custom Docker data roots are preserved in this mode.

### 2. RIOT-PURGE — application and service cleanup

File: `riot-purge.sh`

Reviews and optionally removes:
- Enabled/running non-core systemd service candidates (each requires confirmation)
- APT packages marked manually installed (each package requires confirmation)
- Immediate child directories under `/opt`, `/srv`, `/var/www`, `/usr/local/src`, and `/usr/local/share` (each requires confirmation)

Run a preview first:
```bash
curl -fsSLO https://raw.githubusercontent.com/bjo163/RIOTSCRIPT/main/riot-purge.sh
sudo bash riot-purge.sh --dry-run
```

Then run the interactive cleanup:
```bash
sudo bash riot-purge.sh
```

Review every candidate carefully. Answer yes only for software and data you recognize and intend to remove.

## Protected by design

Neither script is a factory reset. They do not format disks or remove Debian/Ubuntu. RIOT-PURGE deliberately preserves:
- SSH and network services/configuration
- systemd, APT/dpkg, core OS packages
- Kernel, initramfs, GRUB, partitions, filesystems and LVM
- User accounts, home directories and user crontabs
- Cron and shell startup files (listed for manual review, never bulk-deleted)

RIOT-CLEAN also stops if it detects active Kubernetes-family services that could depend on containerd.

## Recommended sequence

1. Back up anything important, especially Docker volumes and application databases.
2. Run `riot-purge.sh --dry-run` and inspect the candidates.
3. Run `riot-purge.sh` and approve only known application services/packages/directories.
4. If Docker data should also be destroyed, run `riot-clean.sh` separately and confirm its warning.
5. Verify SSH and network access before rebooting.

## Important limitations

- APT's manually-installed package list is not a reliable label for "application only". Review each package; do not approve packages you do not recognize.
- Service names are heuristic candidates, not proof that a service is disposable.
- Application data may live outside the listed directories. The scripts do not guess or recursively wipe arbitrary filesystem paths.
- Cron jobs, user startup files, PM2/systemd user units and other custom launchers may need manual inspection.
- Scripts have been committed to the repository; always inspect the source before running as root. Test on a disposable VPS before production use.

Repository: https://github.com/bjo163/RIOTSCRIPT
