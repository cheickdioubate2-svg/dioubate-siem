#!/usr/bin/env bash
# DIOUBATE SIEM — installation / mise à jour du central sur Ubuntu/Debian (service systemd).
#
#   sudo ./install-server.sh                      MODE LOCAL (recommandé) : central sur 127.0.0.1:5000 uniquement,
#                                                 console via tunnel SSH, agent installé sur ce serveur.
#   sudo ./install-server.sh --public --agents 41.223.10.20,102.176.0.0/16 [--console 41.x.x.x]
#                                                 MODE PUBLIC : central joignable depuis Internet, mais
#                                                 console = votre IP SSH (+ --console), agents = --agents.
#   Options : --port 5000  --no-agent
#
# Ré-exécutable : met à jour le programme en conservant la base, les réglages et le certificat.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "À exécuter en root : sudo $0"; exit 1; }
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PORT=5000; MODE=local; CONSOLE=""; AGENTS=""; WITH_AGENT=1
while [ $# -gt 0 ]; do
  case "$1" in
    --public) MODE=public ;;
    --local) MODE=local ;;
    --port) PORT="$2"; shift ;;
    --console) CONSOLE="$2"; shift ;;
    --agents) AGENTS="$2"; shift ;;
    --no-agent) WITH_AGENT=0 ;;
    *) echo "Option inconnue : $1"; exit 2 ;;
  esac
  shift
done
case "$(uname -m)" in x86_64|amd64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; *) echo "Architecture non supportée"; exit 1 ;; esac
# Paquet officiel : binaires dans dist/ ; ancienne disposition (linux/, agents/) toujours acceptée.
SRV_BIN=""
for c in "$HERE/dist/dioubate-siem-server-linux-$ARCH" "$HERE/linux/dioubate-siem-server-$ARCH"; do [ -f "$c" ] && { SRV_BIN="$c"; break; }; done
[ -n "$SRV_BIN" ] || { echo "Binaire du central introuvable (attendu : $HERE/dist/dioubate-siem-server-linux-$ARCH)"; exit 1; }

say() { echo -e "\n==> $*"; }
wait_up() {
  for i in $(seq 1 30); do
    code=$(curl -sk --noproxy '*' -o /dev/null -w "%{http_code}" "https://127.0.0.1:$PORT/api/me" || true)
    [ "$code" = "401" ] && [ -f $DATA/settings.json ] && return 0
    sleep 1
  done
  echo "Le central ne répond pas. Journal :"; journalctl -u dioubate-siem-server -n 30 --no-pager || true; exit 1
}
BASE=/opt/dioubate-siem-server
DATA=$BASE/data

# Vérification des options AVANT toute modification du système
if [ "$MODE" = local ]; then
  LISTEN="127.0.0.1:$PORT"
else
  LISTEN="0.0.0.0:$PORT"
  # Console : par défaut, uniquement l'IP depuis laquelle vous êtes connecté en SSH
  SSH_CLIENT="${SSH_CLIENT:-}"
  SSH_IP="${SSH_CLIENT%% *}"
  [ -n "$SSH_IP" ] || SSH_IP=$(who -m 2>/dev/null | sed -n 's/.*(\([0-9a-fA-F:.]*\)).*/\1/p')
  if [ -z "$CONSOLE" ]; then
    [ -n "$SSH_IP" ] || { echo "Impossible de détecter votre IP SSH : précisez --console VOTRE_IP"; exit 1; }
    CONSOLE="$SSH_IP"
  fi
  [ -n "$AGENTS" ] || { echo "Mode public : précisez --agents (IP publiques des serveurs/sites qui enverront des journaux)"; exit 1; }
fi

say "Utilisateur système et dossiers"
id dioubate >/dev/null 2>&1 || useradd --system --home $BASE --shell /usr/sbin/nologin dioubate
install -d -o root -g root -m 0755 $BASE $BASE/dist
install -d -o dioubate -g dioubate -m 0700 $DATA
systemctl stop dioubate-siem-server 2>/dev/null || true
install -m 0755 "$SRV_BIN" $BASE/dioubate-siem-server
for d in "$HERE/dist" "$HERE/agents"; do
  install -m 0644 "$d"/dioubate-siem-agent-* $BASE/dist/ 2>/dev/null || true
  # manifeste signé : active la mise à jour automatique des agents
  [ -f "$d/manifest.json" ] && install -m 0644 "$d/manifest.json" $BASE/dist/manifest.json
done
chmod 0644 $BASE/dist/* 2>/dev/null || true

say "Service systemd (écoute : $LISTEN)"
cat > /etc/systemd/system/dioubate-siem-server.service <<EOF
[Unit]
Description=DIOUBATE SIEM - central
After=network-online.target
Wants=network-online.target

[Service]
User=dioubate
Group=dioubate
WorkingDirectory=$BASE
ExecStart=$BASE/dioubate-siem-server -listen $LISTEN -data $DATA -dist $BASE/dist
Restart=always
RestartSec=3
MemoryMax=512M
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$DATA
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now dioubate-siem-server >/dev/null
systemctl restart dioubate-siem-server
say "Vérification"
wait_up
echo "   central opérationnel"
if [ "$MODE" = public ]; then
  say "Listes d'accès"
  runuser -u dioubate -- $BASE/dioubate-siem-server allow -data $DATA -console "$CONSOLE" -agents "$AGENTS"
  systemctl restart dioubate-siem-server
  wait_up
  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    say "UFW : port $PORT ouvert uniquement pour les adresses autorisées"
    for ip in ${CONSOLE//,/ } ${AGENTS//,/ }; do ufw allow from "$ip" to any port "$PORT" proto tcp >/dev/null; echo "   autorisé : $ip"; done
  else
    echo "   ATTENTION : UFW n'est pas actif. Le central filtre lui-même les IP, mais fermez aussi le port $PORT"
    echo "   dans le pare-feu de votre hébergeur (ou activez UFW) pour toutes les autres adresses."
  fi
fi


if [ $WITH_AGENT = 1 ]; then
  say "Agent sur ce serveur (surveillance SSH, sudo, web, pare-feu)"
  TOKEN=$(grep -o '"enroll_token": *"[^"]*"' $DATA/settings.json | cut -d'"' -f4)
  if [ -f /etc/dioubate-siem/agent.json ]; then
    echo "   agent déjà installé : mise à jour du programme"
    install -m 0755 $BASE/dist/dioubate-siem-agent-linux-$ARCH /opt/dioubate-siem-agent/dioubate-siem-agent && systemctl restart dioubate-siem-agent
  else
    curl -fsSk --noproxy '*' "https://127.0.0.1:$PORT/install/linux.sh?token=$TOKEN" | bash
  fi
fi

FP=$(openssl x509 -in $DATA/server.crt -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
echo
echo "================================================================"
echo " DIOUBATE SIEM est installé."
if [ -f $DATA/ADMIN-INITIAL-PASSWORD.txt ]; then
  sed 's/^/ /' $DATA/ADMIN-INITIAL-PASSWORD.txt
fi
echo
if [ "$MODE" = local ]; then
  echo " MODE LOCAL : rien n'est exposé sur Internet."
  echo " Pour ouvrir la console depuis votre PC :"
  echo "   1) dans PowerShell (ou un terminal) sur VOTRE PC :"
  echo "        ssh -N -L 5000:127.0.0.1:$PORT ${SUDO_USER:-utilisateur}@$(hostname -I | awk '{print $1}')"
  echo "   2) laissez cette fenêtre ouverte et allez sur : https://localhost:5000"
else
  echo " MODE PUBLIC : https://$(hostname -I | awk '{print $1}'):$PORT"
  echo "   console autorisée pour : $CONSOLE"
  echo "   agents autorisés pour  : $AGENTS"
fi
echo
echo " Empreinte TLS (à comparer avec celle du navigateur) :"
echo "   $FP"
echo "================================================================"
