# CephFS nativ auf macOS (Apple Silicon)

`ceph-fuse` für macOS: sechs Patches gegen Ceph 19.2.3, ein Build-Skript,
Betriebsskripte und Messwerkzeuge für den Vergleich mit einem SMB-Gateway.

Getestet mit **Ceph 19.2.3 (Squid) auf macOS 26.6, arm64, macFUSE 5.3.3,
Apple clang 21**.

Warum überhaupt: Für macOS wird üblicherweise ein SMB-Gateway empfohlen, und
für große Einzeldateien ist das auch richtig. Aber CephFS-Snapshots (`.snap`)
gibt es nur über den nativen Client, und bei vielen kleinen Dateien ist
`ceph-fuse` **ein bis zwei Größenordnungen schneller** — siehe
[Messergebnisse](#was-das-bringt).

Der Stand der Dinge, warum es überhaupt Patches braucht: Die offizielle
Anleitung stammt aus der Intel-Ära und baut gar keinen CephFS-Client; der
einzige bekannte Homebrew-Tap steht bei Ceph 17.2.5 und wird seit 2023 nicht
gepflegt; Upstream betreibt für macOS keine CI. Jeder Fehler auf dem Weg —
mit Meldung, Ursache und Lösung — steht in
[BUILDING-macos.md](BUILDING-macos.md).

## Installation

Voraussetzungen: Homebrew, Xcode Command Line Tools, Netzzugang zu einem
CephFS-Cluster, ein cephx-Schlüssel.

**1. Abhängigkeiten und macFUSE**

```bash
brew install cmake ninja pkg-config ccache python@3.12 cython sphinx-doc \
             bash gnu-getopt yasm nasm snappy lz4 zstd icu4c openssl@3 nss nspr
brew install --cask macfuse
```

macFUSE bringt eine Kernel-Erweiterung mit: Systemeinstellungen → Datenschutz
& Sicherheit → Software von „Benjamin Fleischer" erlauben → Neustart. Steht der
Mac noch auf voller Boot-Sicherheit, ist einmalig zusätzlich der Recovery-Modus
nötig; Details und Prüfkommando in [BUILDING-macos.md](BUILDING-macos.md).

**2. Quellen holen und patchen**

```bash
mkdir -p src && cd src
curl -LO https://download.ceph.com/tarballs/ceph-19.2.3.tar.gz
tar xf ceph-19.2.3.tar.gz && mv ceph-19.2.3 ceph && cd ceph
git init -q && git add -A && git commit -qm "vanilla ceph 19.2.3"
git am ../../patches/*.patch
cd ../..
```

**3. Bauen** — etwa 15 Minuten, gebaut wird nur das Target `ceph-fuse`

```bash
./scripts/build.sh
src/ceph/build/bin/ceph-fuse --version
```

**4. Konfigurieren** — siehe [nächster Abschnitt](#konfiguration)

**5. Mounten**

```bash
./scripts/mount.sh
```

Optional für den Alltag, damit die Kommandos überall funktionieren:

```bash
for c in mount umount remount; do
  printf '#!/bin/sh\nexec "%s/scripts/%s.sh" "$@"\n' "$PWD" "$c" > ~/bin/ceph-$c
  chmod +x ~/bin/ceph-$c
done
```

## Konfiguration

Zwei Dateien, beide vom Repository ausgenommen — deine Cluster-Daten bleiben
lokal:

**`site.conf`** (aus `site.conf.example`) — Nutzer, Pfade, Mountpunkte und die
Ziele der Benchmarks. Alle Skripte lesen sie und funktionieren auch ohne, dann
müssen die Werte als Argumente kommen.

```bash
cp site.conf.example site.conf && $EDITOR site.conf
```

**`etc/ceph.conf`** (aus `etc/ceph.conf.example`) — Monitor, fsid und die
macOS-spezifischen Einstellungen. Drei Punkte darin sind wichtig:

- `run_dir` muss auf ein beschreibbares Verzeichnis zeigen. Ceph will sonst
  nach `/var/run/ceph`, das es auf macOS nicht gibt — und bricht dort mit einem
  nicht abgefangenen Fehler ab.
- `fuse_set_user_groups = true` aktiviert unsere lokale Gruppenauflösung.
  macFUSE liefert keine Nebengruppen, ohne das erreichst du nur Dateien, die
  über deine *primäre* Gruppe freigegeben sind.
- `client_mount_uid`/`client_mount_gid` sind auskommentiert. Brauchst du sie,
  steht das Warum unten unter [Schreibzugriff](#schreibzugriff).

**Schlüssel ablegen** — ohne ihn in der Shell-History zu hinterlassen:

```bash
# cephx-Schlüssel in die Zwischenablage kopieren, dann:
./scripts/set-keyring.sh <ceph-user>
```

Das Skript prüft das Format (40 Zeichen base64, Präfix `AQ`) vor dem Schreiben
und gibt den Schlüssel nie aus. Er landet in
`~/.ceph/ceph.client.<user>.keyring` mit Modus 0600.

## Betrieb

```bash
ceph-mount            # mountet gemäß site.conf
ceph-umount
ceph-remount          # nach jedem Netzwechsel: CephFS (und SMB) neu verbinden
```

Abweichende Ziele als Argumente:
`ceph-mount <user> /remote/path ~/mnt/ceph/andere`.

Snapshots liegen in jedem gesnapshotteten Verzeichnis unter `.snap` — versteckt,
taucht im `ls` des Elternverzeichnisses nicht auf:

```bash
ls ~/mnt/ceph/storage/<verzeichnis>/.snap
```

**Nach einem Netzwechsel** hängt der Mount (er steht in der Mount-Tabelle,
antwortet aber nicht mehr); dasselbe gilt für SMB-Mounts. `ceph-remount` stellt
beides wieder her.

### Schreibzugriff

CephFS prüft uid und gid wie ein lokales Dateisystem. Die uid deines Macs
(meist 501) hat mit den uids des Clusters (oft LDAP-verwaltet) in der Regel
nichts zu tun — Schreiben scheitert dann überall dort, wo du nicht Eigentümer
bist. Drei Wege:

1. **Nichts tun** und zum Schreiben ein SMB-Gateway nutzen, sofern vorhanden.
   Das mappt die Identität serverseitig.
2. **`client_mount_uid`/`client_mount_gid` setzen** — der Client handelt dann
   unter dieser Identität, so wie ein SMB-Gateway es serverseitig tut. Dateien
   tragen danach diese uid, nicht deine persönliche. Die passende Zahl findest
   du, ohne zu raten: eine Datei über das Gateway schreiben und ihren
   Eigentümer durch den FUSE-Mount ansehen (`ls -n`).
3. **Deine Cluster-uid lokal vorhalten** (zweiter Account) — die einzige
   Variante, bei der Dateien dir persönlich gehören.

Für gruppenbasierte Freigaben genügt es, die Cluster-gids lokal anzulegen:
`sudo scripts/add-cluster-groups.sh <gid>...`; die Nummern liefert `id -G` auf
einem Linux-Host am selben Cluster.

## Weitergeben als Binary

```bash
./scripts/package.sh
```

erzeugt unter `dist/` ein eigenständiges Bundle (~57 MB): Binary, die fünf
nötigen Bibliotheken mit auf `@executable_path` umgebogenen Pfaden, ad-hoc
signiert, dazu Konfigurationsvorlage und Mount-Skripte. Auf dem Zielrechner
wird **kein Homebrew** gebraucht — nur macFUSE (Kernel-Erweiterung, lässt sich
nicht bündeln).

Das Bundle ist nicht notarisiert; nach einem Download blockt Gatekeeper es, bis
`xattr -dr com.apple.quarantine .` gelaufen ist. Nur arm64.

## Messen

```bash
./scripts/bench-run.sh <label>              # misst und friert die Umgebung ein
python3 analysis/summarize.py --run <label> # Tabellen
python3 analysis/summarize.py --compare     # alle Läufe nebeneinander
python3 analysis/summarize.py --check       # Lücken statt stiller Kürzung
python3 analysis/latency-scaling.py         # skaliert es mit der RTT?
```

Die Benchmarks brauchen `BENCH_TREE`, `BENCH_BIGFILE` und `BENCH_SCRATCH` in
`site.conf`. Gemessen werden Verzeichnislistings (kalt/warm), viele kleine
Dateien hoch und runter, ein Thumbnail-Muster, sequenzieller Durchsatz
(alternierend zwischen den Zugängen, jede Messung von einem anderen Offset,
damit nichts aus dem Page-Cache kommt), Parallelitäts-Skalierung sowie die
Objecter-Statistik des Clients.

## Was das bringt

Fünf Läufe in drei Netzen, 100 Dateien à 100 KB, gegen einen Cluster mit
SMB-Gateway zum Vergleich:

| | ceph-fuse | SMB-Gateway |
|---|---|---|
| viele kleine Dateien hochladen (LAN, 1,3 ms) | **1,7 s** | 92 s |
| viele kleine Dateien herunterladen (LAN) | **0,6 s** | 22 s |
| dasselbe über WLAN von zuhause (34 ms) | **28 s / 5,3 s** | 524 s / 240 s |
| Verzeichnis listen, kalt (LAN) | **0,43 s** | 4,2 s |
| Verzeichnis listen, **wiederholt** | 0,43 s | **0,17 s** |
| eine große Datei sequenziell (LAN) | 17–42 MB/s | **48–62 MB/s** |
| Snapshots (`.snap`) | **ja** | nein |

Kurz: `ceph-fuse` für Suchen, Navigieren, Snapshots und alles mit vielen
Dateien; das Gateway für große Einzeltransfers im LAN und für wiederholte
Blicke in denselben Ordner. Beides parallel zu mounten ist die praktische
Antwort.

Zwei Befunde aus der Analyse, die das erklären: Ein Verzeichnislisting kostet
**einen MDS-Roundtrip pro Eintrag** (über fünf Netze bestätigt: die Zeit wächst
mit 118 ms je ms RTT bei 112 Einträgen) — deshalb ist es latenzempfindlich und
wird nie „warm". Und der sequenzielle Durchsatz eines *einzelnen* Lesestroms
ist durch die Bedienzeit je Objektanfrage begrenzt, nicht durch die Leitung:
Vier parallele Leser erreichen das Mehrfache.

## Aufbau

| Pfad | Inhalt |
|---|---|
| `patches/` | die sechs Patches gegen Ceph 19.2.3 |
| `scripts/` | bauen, mounten, messen, Bundle bauen, Patches exportieren |
| `analysis/` | Auswertung der Messungen |
| `BUILDING-macos.md` | Problemkatalog: jeder Fehler mit Meldung, Ursache, Fix |
| `site.conf.example`, `etc/ceph.conf.example` | Konfigurationsvorlagen |

## Grenzen

- **Kein Upstream-Support.** Ceph testet macOS in keiner CI; jedes Update kann
  die Patch-Serie brechen. `scripts/export-patches.sh` prüft, ob sie noch auf
  den unveränderten Baum passt; welcher Patch woran bricht, steht in
  `BUILDING-macos.md`.
- **Reduzierte Boot-Sicherheit** ist der Preis für macFUSE (SIP bleibt aktiv).
- **Nur arm64.** Auf Intel-Macs ungetestet; Patch 0002 (Mach-O statt ELF für
  boost::context) ist dort gegenstandslos, sollte aber nicht schaden.
- **Netzwechsel** überstehen weder FUSE- noch SMB-Mounts.
