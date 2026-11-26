# NexoPOS – Proxmox LXC Installer

Einzeiler-Installer für [NexoPOS](https://github.com/Blair2004/NexoPOS) (GPL-3.0, Core 6.3.0) als
Debian-LXC auf Proxmox VE. Kein Docker, kein Node im Laufzeitbetrieb.

```
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/NexoPOS-Proxmox/main/install/nexopos.sh)"
```

## Was installiert wird

| Komponente | Version / Detail |
|---|---|
| Basis | Debian 12/13 LXC, unprivileged, `nesting=1`, `onboot=1` |
| PHP | 8.4-FPM (Debian 13) – Laravel 12 braucht ≥ 8.2 |
| Datenbank | MariaDB, eigene DB + Benutzer, Passwort zufällig |
| Webserver | Nginx auf Port **8080**, `fastcgi_pass` auf php8.4-fpm-Socket |
| Frontend | Vue/Vite-Build im CT (Node 24, nur einmalig beim Install/Update) |
| Dienste | `nexopos-scheduler` (`schedule:work`) + `nexopos-queue` (`queue:work`), beide `Restart=always` |
| Setup | headless per `php artisan ns:setup` (kein Browser-Wizard nötig) |

Der Admin-Benutzer wird beim ersten Lauf angelegt; das Passwort wird in der
Summary ausgegeben (oder per `--admin-pass` vorgegeben).

## Modi

```bash
# Neu-Installation (nächste freie CT-ID)
bash -c "$(wget -qLO - <RAW-URL>)" -- --yes

# Update (Code, Assets, Migrationen, Dienste neu starten)
bash -c "$(wget -qLO - <RAW-URL>)" -- --update

# Status / Deinstallieren
bash -c "$(wget -qLO - <RAW-URL>)" -- --status
bash -c "$(wget -qLO - <RAW-URL>)" -- --uninstall
```

### Optionen

| Flag | Standard | Bedeutung |
|---|---|---|
| `--id N` | – | CT-ID erzwingen (für `--update/--status/--uninstall`) |
| `--ram MB` | 2048 | RAM |
| `--disk GB` | 10 | Disk |
| `--cores N` | 2 | vCPUs |
| `--hostname X` | `nexopos` | CT-Hostname |
| `--port N` | 8080 | Web-Port im CT |
| `--admin-user X` | `admin` | Admin-Benutzername |
| `--admin-email X` | `admin@nexopos.local` | Admin-E-Mail |
| `--admin-pass X` | zufällig | Admin-Passwort |
| `--store-name X` | `NexoPOS` | Ladenname |
| `--bridge`, `--storage` | `vmbr0`, `local-lvm` | Netz/Storage |
| `--yes` | – | ohne Rückfrage |

## Nach der Installation

1. `http://<CT-IP>:8080` öffnen → Login mit dem Admin-Benutzer.
2. Cron/Queue laufen als systemd-Dienste, nichts weiter zu tun.
3. Reboot-Test: `pct reboot <ID>` – App und Dienste kommen automatisch zurück.

## Wichtig: Module sind kostenpflichtig

Der Core (POS, Inventar, Kunden, Buchhaltung, Reports, Module-API) ist GPL-3.0.
Komfort-Module (Gastro/Restaurant, MultiStore, Rental, WorkForce, QR-Menü,
PIN-Login, 2FA, Druck-Adapter) werden **separat über den NexoPOS-Marketplace**
lizenziert und sind nicht im Repo. Der Installer ändert daran nichts.

## Tests

```bash
bash harness/run.sh     # 69 Assertions, Mock-Proxmox (unshare -rm)
```

Der Harness mockt `pct/pveam/pvesh`, apt, systemd, MariaDB, PHP, Composer,
npm/git und lässt das In-Container-Script echt laufen (Pfade auf Mock-Root
umgeschrieben). Abgedeckt: Happy Path, Arch-Falle (arm64-Template auf amd64),
fehlgeschlagener Spawn, fehlende IP, DNS, `--update` (auch gestoppter CT),
`--status`, `--uninstall`, Fehlerkette mit `bash -x`-Hinweis.

```bash
bash -n install/nexopos.sh && shellcheck -S warning install/nexopos.sh harness/run.sh
```

## Bekannte Punkte

- **Kein offizielles Docker-Image / Compose** im Upstream-Repo – daher nativer
  LAMP-Stack im CT statt Container-in-Container.
- Der Setup-Wizard im Browser hat nur eine GET-Route; der verlässliche Weg ist
  `php artisan ns:setup` (macht der Installer).
- `ns:setup` setzt den Ladenname nicht selbst → wird per `tinker` nachgezogen.
- Marketplace-Module müssen zur Core-Version passen (hier 6.3.x).

## Herkunft / Lizenz

Installer: eigenes Script (frei verwendbar). NexoPOS selbst: GPL-3.0,
Copyright Blair2004 und Mitwirkende.
