#!/usr/bin/env bash
# Suppression de l'environnement de bureau (GNOME) pour obtenir un serveur type VPS
# Usage :
#   bash remove-desktop.sh --dry-run        # simulation, sans sudo, ne modifie rien
#   sudo bash remove-desktop.sh <admin>     # exécution réelle (détachée) puis redémarrage
set -euo pipefail

# Paquets qui ne doivent JAMAIS partir (accès, sécurité, réseau, Docker, outils)
PROTECTED="openssh-server sudo ufw fail2ban python3-systemd unattended-upgrades
  docker-ce docker-ce-cli containerd.io docker-compose-plugin iptables
  ifupdown dhcpcd-base ca-certificates curl wget git rsync nano less
  bash-completion man-db locales console-setup keyboard-configuration
  open-vm-tools task-ssh-server task-french"

# Bureau et services inutiles sur un serveur (motifs dpkg)
REMOVE_REGEX='^(task-desktop|task-gnome-desktop|task-french-desktop|gnome|gnome-.*|gdm3|xorg|xserver-.*|xwayland|cups|cups-.*|avahi-.*|bluez|bluez-.*|modemmanager|packagekit|packagekit-.*|network-manager|network-manager-.*|wpasupplicant|pipewire|pipewire-.*|wireplumber|pulseaudio|pulseaudio-.*|firefox-esr|libreoffice-.*|evolution|evolution-.*|open-vm-tools-desktop)$'

installed() { dpkg-query -W -f='${Status} ${Package}\n' 2>/dev/null | awk '/ok installed/{print $4}'; }
TO_REMOVE=$(installed | grep -E "$REMOVE_REGEX" | grep -vxF -f <(tr -s ' \n' '\n' <<<"$PROTECTED") | tr '\n' ' ')

APT_OPTS=()   # en --dry-run : pointe vers une copie de l'état apt
simulate() {
  apt-get "${APT_OPTS[@]}" -s purge --autoremove $TO_REMOVE 2>/dev/null | awk '/^(Purg|Remv) /{print $2}' | sort -u
}

check_protected() {
  local victims; victims=$(simulate | grep -xF -f <(tr -s ' \n' '\n' <<<"$PROTECTED") || true)
  if [ -n "$victims" ]; then
    echo "ABANDON : ces paquets protégés seraient supprimés :"; echo "$victims"; exit 1
  fi
}

if [ "${1:-}" = "--dry-run" ]; then
  # Reproduit le marquage « manuel » de l'étape 2 sur une copie, sans root
  STATES=$(mktemp); trap 'rm -f "$STATES"' EXIT
  cp /var/lib/apt/extended_states "$STATES"
  APT_OPTS=(-o "Dir::State::extended_states=$STATES")
  apt-mark "${APT_OPTS[@]}" manual $(installed | grep -xF -f <(tr -s ' \n' '\n' <<<"$PROTECTED")) >/dev/null
  echo "Paquets ciblés : $(wc -w <<<"$TO_REMOVE")"
  echo "Total supprimé (avec dépendances orphelines) : $(simulate | wc -l)"
  check_protected
  echo "Aucun paquet protégé touché. Simulation OK."
  exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "À lancer avec sudo (ou --dry-run)"; exit 1; }

if [ "${1:-}" != "--detached" ]; then
  ADMIN_USER="${1:?usage: sudo bash $0 <utilisateur_admin>}"
  LOG="/home/${ADMIN_USER}/remove-desktop.log"

  echo "== 1. ens33 géré par ifupdown (DHCP) au lieu de NetworkManager"
  cat > /etc/network/interfaces.d/ens33 <<'CONF'
auto ens33
iface ens33 inet dhcp
CONF

  echo "== 2. Protection des paquets indispensables"
  apt-get install -y -q rsync >/dev/null      # utile à l'étape 4 (sauvegardes)
  apt-mark manual $(installed | grep -xF -f <(tr -s ' \n' '\n' <<<"$PROTECTED")) >/dev/null

  echo "== 3. Simulation de contrôle"
  check_protected
  echo "OK : $(simulate | wc -l) paquets seront supprimés, aucun paquet protégé."

  echo "== 4. Lancement détaché (survit à une coupure SSH)"
  cp "$0" /root/remove-desktop.sh
  systemd-run --unit=remove-desktop --collect \
    bash -c "bash /root/remove-desktop.sh --detached > '$LOG' 2>&1"
  echo "Suivi : tail -f $LOG"
  echo "La VM redémarrera automatiquement à la fin (≈ 3-5 min)."
  exit 0
fi

# ---- Partie détachée ----
export DEBIAN_FRONTEND=noninteractive
echo "Début : $(date)"
systemctl stop gdm3 packagekit 2>/dev/null || true
echo 'DPkg::Lock::Timeout "300";' > /etc/apt/apt.conf.d/99lock-timeout
check_protected
apt-get purge -y --autoremove $TO_REMOVE
apt-get autoremove -y --purge
rm -f /etc/apt/apt.conf.d/99lock-timeout
systemctl set-default multi-user.target

echo "--- Restes éventuels"
installed | grep -E "$REMOVE_REGEX" || echo "aucun"
echo "--- Paquets restants : $(installed | wc -l)"
df -h / | tail -1
echo "Fin : $(date) — redémarrage"
sync
systemctl reboot
