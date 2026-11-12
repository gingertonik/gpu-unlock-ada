#!/usr/bin/env bash
# One-command install for Arch and Arch-based distros (CachyOS, EndeavourOS, ...).
# Builds this repo's repinned packages and installs them. Changes nothing on
# the GPU: the unlock only runs if you add the kernel option in step 2.
set -euo pipefail

cd "$(dirname "$0")"

if [ "$(id -u)" -eq 0 ]; then
  echo "Run as your normal user (sudo is used where needed)." >&2
  exit 1
fi

if ! command -v pacman >/dev/null; then
  echo "This installer is for Arch-based distros. For Debian/Ubuntu use 'make install-deb'," >&2
  echo "for Fedora/RHEL 'make install-rpm' (see README)." >&2
  exit 1
fi

SUDO=""
if [ "${SUDO:-}" = "" ]; then
  sudo -v
  SUDO="sudo"
fi

echo "==> Installing build/runtime dependencies"
needed_pkgs=(git dkms)
if ! pacman -Qq linux-headers >/dev/null 2>&1; then
  # Pick the headers package matching the running kernel flavour.
  case "$(uname -r)" in
    *cachyos-lts*)  needed_pkgs+=(linux-cachyos-lts-headers) ;;
    *cachyos*)      needed_pkgs+=(linux-cachyos-headers) ;;
    *lts*)          needed_pkgs+=(linux-lts-headers) ;;
    *zen*)          needed_pkgs+=(linux-zen-headers) ;;
    *)              needed_pkgs+=(linux-headers) ;;
  esac
fi
to_install=()
for p in "${needed_pkgs[@]}"; do
  pacman -Qq "$p" >/dev/null 2>&1 || to_install+=("$p")
done
if [ ${#to_install[@]} -gt 0 ]; then
  $SUDO pacman -S --needed --noconfirm "${to_install[@]}"
fi

echo "==> Building repinned packages (downloads SHA-pinned NVIDIA inputs, runs the full test suite)"
make install-arch

echo "==> Installed. Verifying DKMS built for the running kernel"
dkms status | grep gpu-unlock

cat <<'EON'

Install complete. Nothing has touched the GPU yet. To enable the unlock:

  1. Print the exact kernel option for your card:
       python3 tools/print_boot_option.py
     Append the printed option(s) to your kernel command line
     (systemd-boot: edit the entry; limine: edit /boot/efi/limine.conf;
     grub: GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub).

  2. Clean shutdown, unplug AC power for 30 seconds, power on (cold boot).
     A warm reboot will NOT unlock: the module skips an already-initialised
     card by design.

  3. Verify:
       sudo dmesg | grep -i gpu_unlock      # want: "gpu_unlock: unlocked"
       python3 tools/read_sm_rates.py --expect-uuid $(nvidia-smi --query-gpu=uuid --format=csv,noheader)

  Uninstall: remove the kernel option, then
       sudo pacman -Rns gpu-unlock-dkms gpu-unlock-firmware && sudo mkinitcpio -P
  An AC power cycle returns the card to its stock state at any time.
EON
