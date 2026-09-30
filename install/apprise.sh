#!/usr/bin/env bash
#
# Apprise API Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:      Apprise API – lokaler Notification-Gateway (Web-UI + REST /notify)
# Upstream: https://github.com/caronc/apprise-api (lib: https://github.com/caronc/apprise)
# Stack:    Python/Django + Gunicorn (gevent, nur localhost:8001) + Nginx (:8000),
#           ohne Docker, ohne Cloud. Nginx liefert /s/ Static direkt aus
#           (Django hat keine /s/-Route) und proxyt den Rest nach Gunicorn.
# Läuft:    vollständig lokal im LXC, keine externen Cloud-Dienste nötig
# Host:     DAS SKRIPT LÄUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/AppRiseProxmox/main/install/apprise.sh)"
#   CT_ID=150 CORES=2 RAM=2048 DISK=8 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/AppRiseProxmox/main/install/apprise.sh)"
#   bash apprise.sh --ctid 150 --cores 2 --memory 2048 --disk 8 --bridge vmbr0 --debug
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="apprise"                                   # Container-Hostname + Service-Name
APP_PORT="8000"                                 # Apprise API Web-UI + REST
UPSTREAM_REPO="https://github.com/caronc/apprise-api"
INSTALLER_REPO="https://github.com/HatchetMan111/AppRiseProxmox"
SERVICE_URL="https://raw.githubusercontent.com/HatchetMan111/AppRiseProxmox/main/systemd/apprise.service"
NGINX_SITE_URL="https://raw.githubusercontent.com/HatchetMan111/AppRiseProxmox/main/nginx/apprise.conf"
# Öffentlich: Nginx auf APP_PORT (Static /s/ + Proxy). Intern: Gunicorn nur localhost:8001.

DEFAULT_CORES="1"                               # vCPU (1 reicht, 2 bei viel Last)
DEFAULT_RAM="1024"                              # RAM in MB (leichtgewichtiges Python)
DEFAULT_SWAP="512"                              # Swap (MB)
DEFAULT_DISK="4"                                # Disk in GB
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"                  # Storage für CT-Templates
DEFAULT_OS="debian-12-standard"                 # Template-Familie
UNPRIVILEGED="1"                                # 1 = unprivilegiert (reicht hier)
FEATURES="nesting=1"                            # nesting für pip/venv Robustheit

APP_USER="apprise"
APP_DIR="/opt/apprise-api"
VENV_DIR="/opt/apprise-api/.venv"
DATA_DIR="/var/lib/apprise"

# Umgebungs-Overrides: CT_ID=150 CORES=2 RAM=2048 DISK=8 ./apprise.sh
CT_ID_ARG="${CT_ID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollständige Ausgabe ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

# Bei Fehlern: komplette Kette ausgeben (Befehl, Zeile, Exit-Code, Log-Verweis)
trap 'ec=$?; msg_error "FEHLER: Befehl »${BASH_COMMAND}« scheiterte in Zeile ${LINENO} (Exit ${ec})."; msg_error "Vollständiges Log: ${LOG_FILE} – bei Bedarf erneut mit --debug laufen lassen."; exit ${ec}' ERR

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer

Usage:
  bash apprise.sh [OPTIONEN]
  CT_ID=150 bash apprise.sh
  bash -c "\$(wget -qLO - ${SERVICE_URL%/systemd/apprise.service}/install/apprise.sh)"

Optionen:
  --ctid ID            Container-ID (Default: nächste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW        Root-Passwort (Default: zufällig generiert, wird angezeigt)
  --ssh-key PATH       SSH Public Key in den Container übernehmen (optional)
  --debug              bash -x + maximale Fehlermeldungskette
  -h, --help           diese Hilfe
EOF
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CT_ID="$CT_ID_ARG" HOSTNAME_ARG="$APP" CORES="$CORES_ARG" RAM="$RAM_ARG" DISK="$DISK_ARG"
STORAGE_ARG="" TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE" BRIDGE="$DEFAULT_BRIDGE"
PASSWORD_ARG="" SSH_KEY_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CT_ID="$2"; shift 2;;
    --hostname) HOSTNAME_ARG="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --template-store) TEMPLATE_STORE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --password) PASSWORD_ARG="$2"; shift 2;;
    --ssh-key) SSH_KEY_ARG="$2"; shift 2;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Host-Prüfung
# ---------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausführen."; exit 1; }
command -v pct >/dev/null || { msg_error "pct nicht gefunden – kein Proxmox-Host?"; exit 1; }
command -v pvesh >/dev/null || { msg_error "pvesh nicht gefunden."; exit 1; }

# Immer nächste freie ID, außer --ctid gesetzt
if [[ -z "$CT_ID" ]]; then
  CT_ID="$(pvesh get /cluster/nextid)"
  msg_info "Nächste freie CT-ID: $CT_ID"
fi

# RootFS-Storage: Argument > local-lvm (wenn vorhanden) > erstes verfügbares
if [[ -z "$STORAGE_ARG" ]]; then
  if pvesm status --storage local-lvm >/dev/null 2>&1; then STORAGE_ARG="local-lvm";
  else STORAGE_ARG="$(pvesm status -content rootdir | awk 'NR>1 {print $1; exit}')";
  fi
fi
[[ -n "$STORAGE_ARG" ]] || { msg_error "Kein RootFS-Storage gefunden."; exit 1; }
msg_info "Storage: $STORAGE_ARG | Template-Store: $TEMPLATE_STORE | Bridge: $BRIDGE"

# ---------------------------------------------------------------------------
# 2. Template sicherstellen (neuestes debian-12-standard)
# ---------------------------------------------------------------------------
msg_info "Prüfe LXC-Template ..."
pveam update >/dev/null 2>&1 || msg_warn "pveam update scheiterte – nutze vorhandene Templates."
AVAILABLE_TEMPLATES="$(pveam available --section system 2>/dev/null || true)"
# Hinweis: Proxmox liefert Templates heute als .tar.zst (nicht nur .tar.gz/.tar.xz).
TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "${DEFAULT_OS}[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_warn "Kein ${DEFAULT_OS}-Template – suche neuestes Debian-Standard-Template als Fallback ..."
  TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "debian-[0-9]+-standard[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
fi
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_error "Kein Debian-Standard-Template gefunden. Verfügbare System-Templates:"
  printf '%s\n' "$AVAILABLE_TEMPLATES" | head -n 20 >&2 || true
  msg_error "Bitte 'pveam update' manuell prüfen (Netz/DNS auf dem Host)."
  exit 1
fi
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE"; then
  msg_info "Lade Template $TEMPLATE ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE"
fi
msg_ok "Template bereit: $TEMPLATE_STORE:vztmpl/$TEMPLATE"

# ---------------------------------------------------------------------------
# 3. Container erstellen (idempotent: existiert die ID, wird aktualisiert)
# ---------------------------------------------------------------------------
if pct status "$CT_ID" >/dev/null 2>&1; then
  msg_warn "CT $CT_ID existiert – überspringe Erstellung (Update-Modus)."
else
  [[ -z "$PASSWORD_ARG" ]] && PASSWORD_ARG="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
  msg_info "Erstelle CT $CT_ID ($HOSTNAME_ARG): $CORES vCPU / $RAM MB / ${DISK}G ..."
  pct create "$CT_ID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME_ARG" \
    --cores "$CORES" --memory "$RAM" --swap "$DEFAULT_SWAP" \
    --rootfs "${STORAGE_ARG}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged "$UNPRIVILEGED" --features "$FEATURES" \
    --onboot 1 --start 0 \
    --password "$PASSWORD_ARG"
  msg_ok "CT $CT_ID erstellt (unprivilegiert, nesting, onboot=1)."
fi

if [[ -n "$SSH_KEY_ARG" ]]; then
  [[ -f "$SSH_KEY_ARG" ]] || { msg_error "SSH-Key nicht gefunden: $SSH_KEY_ARG"; exit 1; }
  pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys 2>/dev/null \
    || { pct exec "$CT_ID" -- mkdir -p /root/.ssh; pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys; }
fi

pct start "$CT_ID" 2>/dev/null || true
msg_info "Warte auf Container-Netz ..."
CT_IP=""
for i in $(seq 1 24); do
  sleep 5
  CT_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "${CT_IP:-}" ]] && break
done
[[ -n "${CT_IP:-}" ]] || { msg_error "Keine Container-IP (pct exec hostname -I). Netzwerk/Bridge prüfen."; exit 1; }
msg_ok "Container-IP: $CT_IP"

# ---------------------------------------------------------------------------
# 4. Apprise API im Container (via pct exec, idempotent)
# ---------------------------------------------------------------------------
msg_info "Installiere Apprise API im Container (nativ, ohne Docker) ..."
# Hinweis: äußere Single-Quotes – der Block läuft dadurch 1:1 im Container,
# ohne dass die Host-Shell $ oder $(...) anfasst (kein Escaping nötig).
pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git curl ca-certificates python3 python3-venv python3-pip nginx
  id apprise >/dev/null 2>&1 || useradd -m -s /bin/bash apprise
  if [ ! -d /opt/apprise-api/.git ]; then
    rm -rf /opt/apprise-api
    git clone https://github.com/caronc/apprise-api /opt/apprise-api
  else
    git -C /opt/apprise-api pull --ff-only
  fi
  if [ ! -x /opt/apprise-api/.venv/bin/python ]; then
    python3 -m venv /opt/apprise-api/.venv
  fi
  /opt/apprise-api/.venv/bin/pip install --upgrade pip
  /opt/apprise-api/.venv/bin/pip install -r /opt/apprise-api/requirements.txt "gunicorn[gevent]"
  mkdir -p /var/lib/apprise/config/store /var/lib/apprise/attach /var/lib/apprise/plugin
  chown -R apprise:apprise /opt/apprise-api /var/lib/apprise
'
# Hinweis: bewusst kein '| tail' hier – mit pipefail würde der trap sonst
# die Pipe (tail) statt des gescheiterten pct-Befehls melden. Voll-Output steht im Log.

# systemd-Unit aus diesem Repo übernehmen (fällt auf Inline-Unit zurück)
if pct exec "$CT_ID" -- curl -fsSL -o /etc/systemd/system/apprise.service "$SERVICE_URL" 2>/dev/null; then
  msg_ok "apprise.service aus Repo übernommen."
else
  msg_warn "Service-URL nicht erreichbar – schreibe Inline-Unit."
  pct push "$CT_ID" /dev/stdin /etc/systemd/system/apprise.service <<UNIT
[Unit]
Description=Apprise API – lokaler Notification-Gateway (Gunicorn/Django)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=apprise
Group=apprise
WorkingDirectory=/opt/apprise-api/apprise_api
Environment=PYTHONUNBUFFERED=1
Environment=DJANGO_SETTINGS_MODULE=core.settings
Environment=APPRISE_CONFIG_DIR=/var/lib/apprise/config
Environment=APPRISE_ATTACH_DIR=/var/lib/apprise/attach
Environment=APPRISE_PLUGIN_PATHS=/var/lib/apprise/plugin
Environment=APPRISE_STATEFUL_MODE=simple
Environment=APPRISE_WORKER_COUNT=2
ExecStart=/opt/apprise-api/.venv/bin/gunicorn --bind 127.0.0.1:8001 --workers 2 --worker-class gevent --timeout 300 core.wsgi:application
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
fi
pct exec "$CT_ID" -- systemctl daemon-reload
pct exec "$CT_ID" -- systemctl enable --now apprise

# Nginx-Front: liefert /s/ Static direkt aus, proxyt den Rest nach Gunicorn.
# (Ohne diesen Layer lädt die Web-UI ungestylt: riesige Icons, tote Buttons –
# Django hat keine /s/-Route, Static kommt Upstream per Nginx.)
msg_info "Richte Nginx-Front (:8000) ein ..."
if ! pct exec "$CT_ID" -- curl -fsSL -o /etc/nginx/sites-available/apprise "$NGINX_SITE_URL" 2>/dev/null; then
  msg_warn "Nginx-Site-URL nicht erreichbar – schreibe Inline-Site."
  pct push "$CT_ID" /dev/stdin /etc/nginx/sites-available/apprise <<NGINX_SITE
server {
    listen 8000;
    listen [::]:8000;
    server_name _;
    client_max_body_size 500M;
    location /s/ {
        alias /opt/apprise-api/apprise_api/static/;
        expires 7d;
        access_log off;
    }
    location = /favicon.ico {
        alias /opt/apprise-api/apprise_api/static/favicon.ico;
        access_log off;
        log_not_found off;
    }
    location / {
        proxy_pass http://127.0.0.1:8001;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
    }
}
NGINX_SITE
fi
pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  ln -sf /etc/nginx/sites-available/apprise /etc/nginx/sites-enabled/apprise
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
'
msg_ok "Nginx-Front aktiv (Static /s/ + Proxy nach 127.0.0.1:8001)."

# ---------------------------------------------------------------------------
# 5. Verifikation: Service + Web UI
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."
pct exec "$CT_ID" -- systemctl is-active apprise || { msg_error "systemd-Service apprise ist nicht active."; pct exec "$CT_ID" -- systemctl status apprise --no-pager || true; exit 1; }
msg_ok "Service läuft (systemctl is-active apprise = active)."

msg_info "Warte auf Web UI (max. 3 Min) ..."
WEB_OK=0
for _ in $(seq 1 18); do
  if pct exec "$CT_ID" -- curl -fs -m 10 "http://localhost:${APP_PORT}/status" >/dev/null 2>&1; then WEB_OK=1; break; fi
  sleep 10
done
[[ "$WEB_OK" == "1" ]] \
  || { msg_error "Web UI antwortet nicht auf localhost:${APP_PORT}/status."; pct exec "$CT_ID" -- systemctl status apprise --no-pager || true; pct exec "$CT_ID" -- journalctl -u apprise --no-pager -n 100 || true; exit 1; }
msg_ok "Web UI antwortet (HTTP 200 auf localhost:${APP_PORT}/status)."

msg_info "Prüfe Static-Layer (/s/ CSS) ..."
pct exec "$CT_ID" -- curl -fs -m 10 "http://localhost:${APP_PORT}/s/css/base.css" >/dev/null 2>&1 \
  || { msg_error "Static antwortet nicht auf localhost:${APP_PORT}/s/css/base.css (Nginx-Layer prüfen)."; pct exec "$CT_ID" -- systemctl status nginx --no-pager || true; pct exec "$CT_ID" -- nginx -t || true; exit 1; }
msg_ok "Static antwortet (HTTP 200 auf localhost:${APP_PORT}/s/css/base.css)."

echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : Apprise API – lokaler Notification-Gateway"
echo "  Upstream     : $UPSTREAM_REPO"
echo "  Container    : CT $CT_ID (Hostname: $HOSTNAME_ARG, unprivilegiert, onboot=1)"
echo "  Ressourcen   : $CORES vCPU / $RAM MB RAM / $DISK GB Disk"
echo "  Web UI       : http://${CT_IP}:${APP_PORT}"
echo "  API          : http://${CT_IP}:${APP_PORT}/notify  (POST urls+body)"
echo "  Health       : http://${CT_IP}:${APP_PORT}/status"
echo "  Root-Passwort: ${PASSWORD_ARG:-<bestehender CT, unverändert>} (nur jetzt angezeigt!)"
echo "  Service      : systemctl status apprise nginx  (im Container via: pct enter $CT_ID)"
echo "  Update       : Skript erneut laufen lassen (idempotent, git pull + pip upgrade)"
echo "  Deinstall    : pct stop $CT_ID && pct destroy $CT_ID"
echo "  Reboot-Test  : pct reboot $CT_ID && sleep 60 && curl -fs http://${CT_IP}:${APP_PORT}/status"
echo "  Log          : $LOG_FILE"
echo "══════════════════════════════════════════════════════════"
