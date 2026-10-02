#!/usr/bin/env bash
# Étape 1 — Durcissement du serveur Debian (type VPS)
# Usage : sudo bash step1-hardening.sh <utilisateur_admin>
set -euo pipefail

ADMIN_USER="${1:?usage: sudo bash $0 <utilisateur_admin>}"
API_PORT=8080
LOG="/home/${ADMIN_USER}/step1.log"
exec > >(tee "$LOG") 2>&1

[ "$(id -u)" -eq 0 ] || { echo "À lancer avec sudo"; exit 1; }
id "$ADMIN_USER" >/dev/null

# Garde-fou : ne pas couper l'accès si aucune clé n'est installée
AUTH_KEYS="/home/${ADMIN_USER}/.ssh/authorized_keys"
[ -s "$AUTH_KEYS" ] || { echo "ERREUR : $AUTH_KEYS vide, abandon."; exit 1; }

echo "== Paquets de base"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q ufw fail2ban python3-systemd unattended-upgrades curl ca-certificates

echo "== SSH : clé uniquement, pas de root"
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<CONF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers ${ADMIN_USER}
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
CONF
sshd -t
systemctl restart ssh

echo "== Pare-feu UFW"
ufw default deny incoming
ufw default allow outgoing
ufw limit 22/tcp comment 'SSH (rate-limited)'
ufw allow ${API_PORT}/tcp comment 'API telemetry'
ufw --force enable

echo "== Fail2ban"
cat > /etc/fail2ban/jail.local <<'CONF'
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
CONF
systemctl enable --now fail2ban
systemctl restart fail2ban
sleep 2

echo "== Mises à jour de sécurité automatiques"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
systemctl enable --now unattended-upgrades

echo "== Docker"
if ! command -v docker >/dev/null; then
  # packagekit (présent si un bureau est installé) peut garder le verrou dpkg
  systemctl stop packagekit 2>/dev/null || true
  # apt attend le verrou jusqu'à 5 min au lieu d'échouer immédiatement
  echo 'DPkg::Lock::Timeout "300";' > /etc/apt/apt.conf.d/99lock-timeout
  curl -fsSL https://get.docker.com | sh
  rm -f /etc/apt/apt.conf.d/99lock-timeout
fi
usermod -aG docker "$ADMIN_USER"

echo
echo "=================== RÉSUMÉ ==================="
echo "--- sshd effectif"
sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|allowusers|maxauthtries) '
echo "--- UFW"
ufw status verbose
echo "--- Fail2ban"
fail2ban-client status sshd
echo "--- unattended-upgrades"
systemctl is-enabled unattended-upgrades; apt-config dump | grep -E 'Periodic::(Update-Package-Lists|Unattended-Upgrade) '
echo "--- Docker"
docker --version; systemctl is-active docker
echo "ÉTAPE 1 TERMINÉE"
