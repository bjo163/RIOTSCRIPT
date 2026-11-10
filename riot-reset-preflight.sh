#!/usr/bin/env bash
#
# RIOT-RESET PREFLIGHT — read-only VPS reset capability check
# Supported: Debian/Ubuntu and common Linux VPS environments
#
# This script DOES NOT modify the server.
# Run: bash riot-reset-preflight.sh
#
set -Eeuo pipefail
export LC_ALL=C

section() { printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }
show_file() {
  local f="$1"
  if [[ -r "$f" ]]; then
    sed -n '1,12p' "$f"
  else
    printf 'Unavailable\n'
  fi
}

section "RIOT-RESET PREFLIGHT"
printf 'Hostname: %s\n' "$(hostname 2>/dev/null || echo unknown)"
printf 'Date: %s\n' "$(date -Is 2>/dev/null || echo unknown)"
printf 'Kernel: %s\n' "$(uname -srmo 2>/dev/null || echo unknown)"
printf 'Architecture: %s\n' "$(uname -m 2>/dev/null || echo unknown)"
printf 'UID: %s (root required for full diagnostics)\n' "$EUID"

section "OPERATING SYSTEM"
show_file /etc/os-release

section "VIRTUALIZATION / PROVIDER HINTS"
if command -v systemd-detect-virt >/dev/null 2>&1; then
  printf 'systemd-detect-virt: '
  systemd-detect-virt 2>/dev/null || true
fi
for f in sys_vendor product_name product_version board_vendor; do
  p="/sys/class/dmi/id/$f"
  if [[ -r "$p" ]]; then printf '%s: %s\n' "$f" "$(cat "$p")"; fi
done
if [[ -r /proc/1/cgroup ]]; then
  printf '\nPID 1 cgroup hints:\n'
  sed -n '1,12p' /proc/1/cgroup
fi

section "BOOT / ROOT FILESYSTEM"
printf 'Boot mode: '
if [[ -d /sys/firmware/efi ]]; then echo UEFI; else echo BIOS-or-virtualized; fi
printf 'Root mount: '
findmnt -no SOURCE,FSTYPE,OPTIONS / 2>/dev/null || true
printf '\nMounts:\n'
findmnt -rn -o TARGET,SOURCE,FSTYPE 2>/dev/null | sed -n '1,35p' || true
printf '\nBlock devices:\n'
lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL 2>/dev/null || true
printf '\nDisk space:\n'
df -hT / /boot 2>/dev/null || true

section "BOOTLOADER / INITRAMFS TOOLS"
for c in grub-install update-grub grub-mkconfig update-initramfs dracut bootctl efibootmgr; do
  if command -v "$c" >/dev/null 2>&1; then printf '%-20s %s\n' "$c" "$(command -v "$c")"; fi
done
printf '\nBoot-related packages (if dpkg):\n'
if command -v dpkg-query >/dev/null 2>&1; then
  dpkg-query -W -f='${binary:Package} ${Version}\n' 'grub*' 'systemd-boot*' 'linux-image*' 'initramfs-tools*' 2>/dev/null | sed -n '1,35p' || true
fi

section "SSH / NETWORK SAFETY CHECK"
for u in ssh.service sshd.service NetworkManager.service systemd-networkd.service networking.service; do
  if command -v systemctl >/dev/null 2>&1; then
    printf '%-30s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"
  fi
done
printf '\nSSH daemon config path: '
if command -v sshd >/dev/null 2>&1; then sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}'; else echo 'sshd binary not found'; fi
printf '\nNetwork addresses (local only):\n'
ip -brief address 2>/dev/null || true
printf '\nDefault route:\n'
ip route show default 2>/dev/null || true

section "CLOUD-INIT / PROVISIONING"
for c in cloud-init cloud-init status; do
  if command -v "$c" >/dev/null 2>&1; then
    printf '%s: ' "$c"
    "$c" --version 2>/dev/null | head -n 1 || true
  fi
done
for p in /etc/cloud/cloud.cfg /etc/cloud/cloud.cfg.d; do
  [[ -e "$p" ]] && printf 'Present: %s\n' "$p"
done

section "PACKAGE MANAGER"
for c in apt-get dnf yum zypper apk pacman; do
  command -v "$c" 2>/dev/null || true
done

section "ACTIVE VIRTUALIZATION / ORCHESTRATION SERVICES"
if command -v systemctl >/dev/null 2>&1; then
  systemctl --no-pager --type=service --state=running 2>/dev/null |
    grep -Ei 'docker|containerd|kube|k3s|rke2|podman|incus|lxc|cloud|ssh|network' |
    sed -n '1,50p' || true
fi

section "ASSESSMENT"
cat <<'EOF'
This report is read-only. It does not prove that an in-place OS reinstall is safe.
A genuine clean OS reinstall normally requires provider reinstall/rescue access,
a supported boot-to-rescue mechanism, or console/hypervisor access.

Do not run disk-wipe, partitioning, debootstrap, or bootloader replacement
commands over the only active SSH session. A failed attempt can permanently
remove remote access.

Share this report after reviewing it for private hostnames, addresses, or
provider identifiers. It contains no passwords or private SSH keys.
EOF
