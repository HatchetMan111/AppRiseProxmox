# Apprise API auf Proxmox – Einzeiler-Installation (Community-Scripts-Stil)

> Upstream-App (kein Teil dieses Ordners): `https://github.com/caronc/apprise-api`
> (Lib: `https://github.com/caronc/apprise`)
> Dieser Ordner enthält **nur den Proxmox-Installer**: Install-Script + systemd-Unit.
> Die App läuft nativ (Python/Django + Gunicorn, ohne Docker) – vollständig lokal, keine Cloud nötig.

## Einzeiler (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/AppRiseProxmox/main/install/apprise.sh)"
```

Anpassungen per Umgebungsvariable oder Flag (ID immer **nächste freie**, außer gesetzt):

```bash
CT_ID=150 CORES=2 RAM=2048 DISK=8 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/AppRiseProxmox/main/install/apprise.sh)"
bash apprise.sh --ctid 150 --cores 2 --memory 2048 --disk 8 --bridge vmbr0 --storage local-lvm
bash apprise.sh --debug   # = bash -x, komplette Fehlermeldungskette + Log unter /tmp/apprise-install-*.log
```

> Dieses Repo ist der Installer (`HatchetMan111/AppRiseProxmox`).
> Die systemd-Unit liegt unter `systemd/apprise.service` desselben Repos und wird
> vom Installer von dort geladen (Fallback: Inline-Unit im Script).

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `apprise` |
| Zweck | Lokaler Notification-Gateway – eine URL-Syntax für 150+ Dienste (Telegram, Discord, Mail, Gotify …), Web-UI + REST `/notify` |
| Tech-Stack | Python/Django + Gunicorn (nur `127.0.0.1:8001`) + Nginx (`:8000`, liefert `/s/` Static direkt, proxyt Rest nach Gunicorn), venv `/opt/apprise-api/.venv` |
| GitHub-Repo (Upstream) | `https://github.com/caronc/apprise-api` |
| Web UI | `http://<LXC-IP>:8000` (Nginx-Front), Health `/status` |
| Standard-Ressourcen | 1 vCPU / 1024 MB RAM / 4 GB Disk (leichtgewichtig, reicht für den Gateway-Betrieb) |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-12-standard` (neuestes auf Storage `local`) |
| LXC-Features | **unprivilegiert** (`--unprivileged 1`), `nesting=1`, `onboot: 1` |

Das Skript (`set -euo pipefail`, idempotent, `trap ERR` mit Befehl+Zeile+Exit-Code):
1. prüft Host/Tools, nimmt die nächste freie CT-ID, erkennt RootFS-Storage
   (bevorzugt `local-lvm`), lädt das neueste `debian-12-standard`-Template falls nötig,
2. erstellt den LXC `apprise` (`onboot: 1`, unprivilegiert),
3. installiert im Container Python+venv+git, legt User `apprise` an,
   klont/pullt `caronc/apprise-api` nach `/opt/apprise-api`, installiert
   `requirements.txt` + `gunicorn[gevent]`, legt `/var/lib/apprise/{config/store,attach,plugin}` an,
   schreibt `apprise.service`, `systemctl enable --now apprise`,
4. verifiziert `systemctl is-active apprise` + HTTP auf `localhost:8000/status`
   **und** Static auf `localhost:8000/s/css/base.css` (Nginx-Layer)
   und gibt die finale URL + Container-IP aus.

> Hinweis (Fix v2): Die Web-UI braucht CSS/JS unter `/s/`, die Upstream per
> Nginx liefert (Django hat keine `/s/`-Route). Darum läuft Gunicorn nur auf
> `127.0.0.1:8001` und Nginx auf `:8000` davor. Ohne diesen Layer lädt die
> Seite ungestylt (riesige Icons, tote Buttons) – kein Upstream-Bug.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active apprise = active).
[OK]    Web UI antwortet (HTTP 200 auf localhost:8000/status).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : Apprise API – lokaler Notification-Gateway
  Container    : CT 100 (Hostname: apprise, unprivilegiert, onboot=1)
  Ressourcen   : 1 vCPU / 1024 MB RAM / 4 GB Disk
  Web UI       : http://192.168.1.100:8000
  API          : http://192.168.1.100:8000/notify  (POST urls+body)
  Health       : http://192.168.1.100:8000/status
  ...
  Log          : /tmp/apprise-install-2026-....log
══════════════════════════════════════════════════════════
```

Test-Notification (stateless, ohne gespeicherte Config):

```bash
curl -X POST -d 'urls=mailto://user:pass@gmail.com&body=test message' http://<LXC-IP>:8000/notify
```

## Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 60
pct exec $CT -- systemctl is-active apprise
curl -fs http://<LXC-IP>:8000/status >/dev/null && echo WEB_UI_OK
```

## Update / Deinstall

```bash
bash apprise.sh --ctid 100            # Update: idempotent (git pull + pip upgrade + restart)
pct stop 100 && pct destroy 100     # Deinstall
```

## Debugging

- Jeder Fehler gibt Befehl + Zeile + Exit-Code aus, Voll-Log unter `/tmp/apprise-install-*.log`.
- `bash apprise.sh --debug` für `bash -x`-Trace.
- Im Container: `systemctl status apprise --no-pager`, `journalctl -u apprise -n 100`.

## Dateien

- `install/apprise.sh` – Proxmox-Einzeiler (Host, root).
- `systemd/apprise.service` – Gunicorn-Unit (nur localhost:8001, `After=network-online.target`, `Restart=always`).
- `nginx/apprise.conf` – Nginx-Site (`:8000`, `/s/` Static aus `apprise_api/static` + Proxy nach Gunicorn).
