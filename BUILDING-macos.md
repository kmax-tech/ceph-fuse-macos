# ceph-fuse auf macOS bauen — Problemkatalog

Stand 2026-08-31. Gebaut und im Betrieb: **Ceph 19.2.3 (Squid), macOS 26.6.2,
Apple Silicon (arm64), macFUSE 5.3.3, Apple clang 21.**

Die offizielle Anleitung (`docs.ceph.com/en/latest/dev/macos/`) taugt nicht als
Rezept: Sie stammt aus der Intel-Ära (`/usr/local/Cellar`, `osxfuse`, nss 3.48,
openssl 1.0.2t) und setzt `-DWITH_CEPHFS=OFF -DWITH_LIBCEPHFS=OFF`, baut also
gar keinen CephFS-Client. Der einzige bekannte funktionierende Tap
(`mulbc/homebrew-ceph-client`) steht bei Ceph 17.2.5, letzter Commit Februar
2023, und hängt an `boost@1.76`, das Homebrew am 2024-12-14 deaktiviert hat.

Dieses Dokument listet jedes Problem, das auf dem Weg auftrat, mit der echten
Fehlermeldung, der Ursache und der Lösung. Wer nur bauen will, findet die
Kurzanleitung am Anfang; die Details braucht man erst, wenn etwas abweicht.

## Kurzanleitung

```bash
brew install cmake ninja pkg-config ccache python@3.12 cython sphinx-doc \
             bash gnu-getopt yasm nasm snappy lz4 zstd icu4c openssl@3 nss nspr
brew install --cask macfuse           # 5.3.x, danach Kext freigeben (siehe unten)

cd src && curl -LO https://download.ceph.com/tarballs/ceph-19.2.3.tar.gz
tar xf ceph-19.2.3.tar.gz && mv ceph-19.2.3 ceph && cd ceph
git init && git add -A && git commit -m "vanilla ceph 19.2.3"
git am ../../patches/*.patch          # die sechs Patches aus diesem Projekt

../../scripts/build.sh                # cmake + ninja, nur das Target ceph-fuse
```

Der macFUSE-Kext muss freigegeben werden. Wie aufwendig das ist, hängt von der
Boot-Sicherheitsstufe des Geräts ab:

- **Mac erlaubt bereits Dritt-Kexts** (Startsicherheit steht auf „Reduzierte
  Sicherheit" mit Kext-Verwaltung, z. B. weil früher schon macFUSE o. ä.
  installiert war): Systemeinstellungen → Datenschutz & Sicherheit →
  Systemsoftware von „Benjamin Fleischer" erlauben → Neustart. Fertig.
- **Mac auf „Volle Sicherheit"** (Apple-Silicon-Werkszustand): erst einmalig
  Recovery-Modus → Startsicherheitsdienstprogramm → **Reduzierte Sicherheit** +
  „Benutzerverwaltung von Kernelerweiterungen erlauben" — der „Erlauben"-Dialog
  der Systemeinstellungen leitet einen in diesem Fall selbst dorthin. Danach
  wie oben.

Der Recovery-Schritt fällt also einmal pro Gerät an, nicht pro Kext. Welche
Stufe ein Gerät hat, zeigt `sudo bputil -d` — die relevanten Zeilen:

```
Security Mode:               Reduced    (smb0): 1
3rd Party Kexts Status:      Enabled    (smb2): 1
SIP Status:                  Enabled    (sip0): absent
Signed System Volume Status: Enabled    (sip1): absent
```

Wichtig für die Einordnung: „Reduzierte Sicherheit" ist nicht „SIP aus". SIP
und das signierte Systemvolume bleiben aktiv; erlaubt wird nur das Laden von
Kexts, die der Nutzer ausdrücklich genehmigt hat. Der Rechner läuft trotzdem
dauerhaft unterhalb der vollen Boot-Sicherheit — eine bewusste Entscheidung,
aber eine kleinere, als es zunächst klingt.

**Strategie des Builds:** nur das Target `ceph-fuse` bauen und alles andere
abschalten. `ceph-fuse` hängt in `src/CMakeLists.txt` allein an `WITH_FUSE`,
nicht an `WITH_CEPHFS`. Damit fallen MGR, RGW, BlueStore, RBD und die halbe
Abhängigkeitskette weg, bevor sie Ärger machen können. Insbesondere
`-DWITH_RBD=OFF` schaltet `rbd-fuse` ab — das Target, an dem der bekannte
Bericht von 2021 auf dem M1 scheiterte („Target 'rbd-fuse' links to target
'FUSE::FUSE' but the target was not found").

## Täglicher Gebrauch

Nach dem Bau genügen drei Kommandos. Sie lesen `site.conf` (siehe
`site.conf.example`) und liegen als Wrapper in `~/bin`, funktionieren also aus
jedem Verzeichnis:

```bash
ceph-mount            # mountet gemaess site.conf
ceph-umount           # haengt aus und beendet den Daemon
ceph-remount          # nach einem Netzwechsel: ceph-fuse und SMB neu verbinden
```

Andere Ziele gehen als Argumente:
`ceph-mount <user> /remote/path ~/mnt/ceph/andere`.

Warum nicht `ceph-fuse` direkt: Das Skript erledigt vier Dinge, die sonst jedes
Mal von Hand stimmen müssen — `-f` plus eigenes Backgrounding (sonst stirbt der
Daemon still, siehe Problem 13), die Konfiguration mit `run_dir` und Identität,
die macOS-Mountoptionen (`local`, `noappledouble`), und eine Prüfung, ob der
Mount wirklich antwortet statt nur in der Mount-Tabelle zu stehen.

Nach jedem Netzwechsel müssen **beide** Zugänge neu verbunden werden — der
FUSE-Mount hängt danach (Mount-Tabelle ja, Zugriff nein), und macOS' SMB-Mounts
überleben den Wechsel ebenfalls nicht. Dafür ist `ceph-remount` da.

## Probleme der Umgebung

Diese drei stecken in `scripts/build.sh`, nicht in den Ceph-Quellen.

### 1. ICU wird nicht gefunden

```
Failed to find all ICU components (missing: ICU_LIBRARY uc i18n) (found version "78.1")
```

Header gefunden, Bibliotheken nicht: `icu4c` ist in Homebrew keg-only und liegt
unter `/opt/homebrew/opt/icu4c@78`. `PKG_CONFIG_PATH` allein genügt `FindICU`
nicht. ICU ist nicht optional — `src/client/CMakeLists.txt` linkt `client`
gegen `ICU::uc` und `ICU::i18n`.

**Lösung:** `-DICU_ROOT="$(brew --prefix icu4c)"`.

### 2. CMake 4 lehnt ein mitgeliefertes Drittprojekt ab

```
CMake Error at src/cpp_redis/CMakeLists.txt:26 (cmake_minimum_required):
  Compatibility with CMake < 3.5 has been removed from CMake.
```

Kein macOS-Problem: Homebrew liefert CMake 4.x, und `cpp_redis` deklariert
`cmake_minimum_required` unterhalb 3.5.

**Lösung:** `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`.

### 3. Cython und PyYAML fehlen im falschen Python

```
CMake Error at cmake/modules/FindCython.cmake:13 (message):
  Could not find cython: /Users/…/.pyenv/versions/3.12.7/envs/…/bin/python3.12: No module named cython
```

und später beim Bauen:

```
File "…/src/common/options/y2c.py", line 3, in <module>
    import yaml
ModuleNotFoundError: No module named 'yaml'
```

cmake greift den Python, der zuerst im `PATH` steht — bei aktivem pyenv-venv
also ein projektfremdes. `src/pybind` lässt sich nicht wegkonfigurieren:
`add_subdirectory(pybind)` in `src/CMakeLists.txt:668` ist unbedingt (nur
`if(NOT WIN32)`), auch wenn `ceph-fuse` die Python-Bindings nicht braucht.

**Lösung:** ein eigenes Build-venv, das `scripts/build.sh` selbst anlegt und mit
`cython` und `pyyaml` bestückt, plus `-DPython3_EXECUTABLE=…`. So hängt der
Build nicht daran, welche Shell ihn startet.

## Portierungspatches

Die sechs Patches liegen in `patches/` und sind mit `git am` anwendbar.

### 4. `AppleClang` ist Ceph unbekannt (`patches/0001`)

```
CMake Error at cmake/modules/BuildBoost.cmake:91 (message):
  unknown compiler: AppleClang
```

`BuildBoost.cmake` kennt nur `GNU` und `Clang`; Apples Compiler meldet sich als
`AppleClang`. b2 kann ihn unter dem Toolset-Namen `clang` fahren.

**Lösung:** die Bedingung um `AppleClang` erweitern. Für Linux ändert sich nichts.

### 5. boost::context baut ELF-Assembler auf Apple Silicon (`patches/0002`)

```
libs/context/src/asm/make_arm64_aapcs_elf_gas.S:58:1: error: unknown directive
libs/context/src/asm/jump_arm64_aapcs_elf_gas.S:114:19: error: unexpected token in '.section' directive
```

`BuildBoost.cmake:137` setzt für ARM hart `binary-format=elf`. Auf Linux-ARM ist
das richtig, auf Apple Silicon ist das Objektformat aber Mach-O. Boost bringt
die passenden `*_arm64_aapcs_macho_gas.S` mit, sie wurden nur nie ausgewählt.

**Lösung:** unter `APPLE` `binary-format=mach-o` und `target-os=darwin` setzen.

### 6. `std::max` mit uneinheitlichen Typen (`patches/0003`)

```
src/osd/OSDMap.cc:6515:27: error: no matching function for call to 'max'
  candidate template ignored: deduced conflicting types for parameter '_Tp'
  ('uint64_t' (aka 'unsigned long long') vs. 'size_type' (aka 'unsigned long'))
```

Auf LP64-Linux sind `uint64_t` und `size_t` beide `unsigned long`, auf Darwin
ist `uint64_t` ein `unsigned long long`. Die Template-Deduktion scheitert.

**Lösung:** `std::max<uint64_t>(…)` — explizites Template-Argument, keine
Verhaltensänderung.

### 7. `-lcap` auf einem System ohne libcap (`patches/0003`)

```
ld: library 'cap' not found
```

`src/extblkdev/CMakeLists.txt` ruft `find_package(cap)` und linkt danach
bedingungslos `target_link_libraries(extblkdev cap)`. Weil der Name roh
übergeben wird, landet `-lcap` auch dann auf der Linkzeile, wenn cmake vorher
`Could NOT find cap` gemeldet hat. Linux-Capabilities gibt es auf macOS nicht.

**Lösung:** nur linken, wenn `cap_FOUND`.

### 8. macFUSE liefert FUSE 2 und FUSE 3 gleichzeitig (`patches/0003`)

```
/usr/local/include/fuse3/fuse_opt.h:77:8: error: redefinition of 'fuse_opt'
/usr/local/include/fuse/fuse_opt.h:76:8: note: previous definition is here
```

macFUSE installiert beide Generationen unter `/usr/local`: FUSE 2 als
`/usr/local/include/fuse.h` (ein Wrapper, der `fuse/fuse.h` einbindet), FUSE 3
unter `/usr/local/include/fuse3/`. cmake übergibt das FUSE-3-Verzeichnis per
`-isystem` — und damit verliert es gegen clangs eingebauten Suchpfad
`/usr/local/include`. `#include <fuse.h>` landet auf dem FUSE-2-Header, während
`#include <fuse_lowlevel.h>` aus fuse3 kommt: beide Generationen in einer
Übersetzungseinheit.

Nachstellbar in zwei Zeilen:

```bash
echo '#include <fuse.h>' > /tmp/t.c
clang -E -isystem /usr/local/include/fuse3 /tmp/t.c | grep -m1 '^# 1 "/usr/local'
#   -> /usr/local/include/fuse.h        (falsch)
clang -E -I/usr/local/include/fuse3 /tmp/t.c | grep -m1 '^# 1 "/usr/local'
#   -> /usr/local/include/fuse3/fuse.h  (richtig)
```

Warum `-isystem` verliert, zeigt Clang selbst
(`clang -E -v … | sed -n '/search starts here/,/End of search/p'`):

```
mit -isystem:                 mit -I:
 /usr/local/include       <-   /usr/local/include/fuse3   <-
 /usr/local/include/fuse3      /usr/local/include
 …SDK-Pfade…                   …SDK-Pfade…
```

`/usr/local/include` steht bei Apple-Clang ganz vorn in der System-Kette, und
`-isystem` sortiert den Pfad *dahinter* ein. Die verbreitete Merkregel „`-I` vor
`-isystem` vor den eingebauten Pfaden" führt hier also in die Irre: Gegen diesen
konkreten eingebauten Pfad verliert `-isystem`. `-I`-Pfade kommen dagegen vor
der gesamten System-Kette.

`/usr/local/include/fuse` wird dabei nie explizit hinzugefügt — es liegt unter
`/usr/local/include`, und `/usr/local/include/fuse.h` zieht `fuse/fuse.h`
selbst nach. Aus CMake heraus ist das nicht wegzukonfigurieren; der einzige
Hebel ist die Priorität.

**Lösung:** Der Pfad stammt nicht aus einem `target_include_directories`,
sondern aus `INTERFACE_INCLUDE_DIRECTORIES` des *importierten* Targets
`FUSE::FUSE` — und Include-Verzeichnisse importierter Targets behandelt CMake
grundsätzlich als System-Pfade. Abschalten lässt sich das mit der Property
`IMPORTED_NO_SYSTEM TRUE` (CMake >= 3.23), gesetzt unter `APPLE` in
`cmake/modules/FindFUSE.cmake`. Unter älterem CMake bliebe nur der Umweg über
`target_include_directories(ceph-fuse PRIVATE ${FUSE_INCLUDE_DIRS})` an den
Consumer-Targets.

### 9. macFUSE weicht von der libfuse3-API ab (`patches/0004`)

```
src/client/fuse_ll.cc:1331:11: error: cannot initialize a member subobject of type
  'void (*)(fuse_req_t, fuse_ino_t, struct fuse_darwin_attr *, int, struct fuse_file_info *)'
  with an lvalue of type
  'void (fuse_req_t, fuse_ino_t, struct stat *, int, struct fuse_file_info *)'
```

macFUSEs libfuse3 aktiviert per Default eigene Darwin-Erweiterungen und ersetzt
dabei `struct stat` durch `struct fuse_darwin_attr` in Callbacks und
Antwortfunktionen. Ceph implementiert die Standard-API. **Das ist die Stelle,
an der der Bau 2021 auf der ceph-users-Liste endete.**

macFUSE exportiert beide ABIs nebeneinander:

```bash
nm -gU /usr/local/lib/libfuse3.dylib | grep fuse_reply_attr
#   T _fuse_reply_attr
#   T _fuse_reply_attr$DARWIN
```

**Lösung:** `FUSE_DARWIN_ENABLE_EXTENSIONS 0` in `src/include/ceph_fuse.h` vor
`#include <fuse.h>`. Damit gelten die „vanilla"-Signaturen. Kosten: die
Darwin-spezifischen Attribute, die der Ceph-Client ohnehin nicht führt.
Kontrollierbar am fertigen Binary — `nm -u` muss `_fuse_reply_attr` ohne
`$DARWIN` zeigen.

### 10. xattr-Signatur mit `position` (`patches/0004`)

```
src/client/fuse_ll.cc:1351:12: error: … different number of parameters (6 vs 7)
```

`fuse_ll.cc` hängt unter `__APPLE__` einen `position`-Parameter an `setxattr`
und `getxattr` — ein Relikt der alten osxfuse-Schnittstelle. Der Parameter wird
im Rumpf nie benutzt.

**Lösung:** die Bedingung an `FUSE_DARWIN_ENABLE_EXTENSIONS` koppeln, statt
`__APPLE__` pauschal zu prüfen. Der Parameter gehört zur Extension-API.

### 11. iconv fehlt beim Linken (`patches/0004`)

```
Undefined symbols for architecture arm64:
  "_iconv", referenced from: boost::locale::conv::impl::iconverter_base::…
  "_iconv_open", "_iconv_close"
```

`Boost::locale` ruft `iconv_open`/`iconv`/`iconv_close`. Die glibc bringt sie
mit, macOS hat sie in einer eigenen Bibliothek. `find_package(Iconv)` hilft
nicht: cmake stuft iconv hier als „built-in" ein und erzeugt kein Link-Flag,
obwohl das SDK die Symbole in `libiconv.tbd` führt.

**Lösung:** in `src/client/CMakeLists.txt` unter `APPLE` direkt
`target_link_libraries(client iconv)`.

## Probleme zur Laufzeit

### 12. Abbruch an `/var/run/ceph`

```
warning: unable to create /var/run/cephPermission denied
libc++abi: terminating due to uncaught exception of type std::filesystem::filesystem_error:
  filesystem error: in permissions: No such file or directory ["/var/run/ceph"]
*** Caught signal (Abort trap) **
```

Ceph legt Admin-Socket und Log unter `/var/run/ceph` an. Das Verzeichnis
existiert auf macOS nicht und ist ohne root nicht anlegbar; der Fehler wird
nicht abgefangen, sondern führt zum Abbruch.

**Lösung ohne Patch**, in `etc/ceph.conf`:

```ini
[client]
    run_dir = /pfad/zum/projekt/run
    admin_socket = $run_dir/$cluster-$name.$pid.asok
    log_file = $run_dir/$cluster-$name.log
    pid_file =
```

### 13. Daemonisieren schlägt still fehl

Ohne `-f` erscheint der Mount in der Mount-Tabelle, der Prozess ist aber
verschwunden, das Log bleibt leer, und jeder Zugriff endet mit:

```
ls: /Users/…/mnt/ceph/storage: Device not configured
```

Das entspricht dem Bericht von 2021 („the drive is never mapped to the
directory"). Im Vordergrund läuft derselbe Aufruf stabil.

**Lösung:** `ceph-fuse` mit `-f` starten und selbst in den Hintergrund schicken
— macht `scripts/mount.sh`, samt PID-Datei; `scripts/umount.sh` beendet ihn.

### 14. Keine Nebengruppen (`patches/0005`)

Symptom: Verzeichnisse, auf die man über eine *Neben*gruppe Zugriff hat, sind
nicht betretbar:

```
ls: fts_read: Permission denied      # bei drwxr-xr-- root:100, "other" ohne x
```

macFUSE exportiert `fuse_req_getgroups`, liefert darüber aber **null** Gruppen
— kein Fehler, sonst stünde `getgroups failed` im Log. macOS hat kein `/proc`,
aus dem libfuse die Credentials des Aufrufers lesen könnte.

**Lösung:** wenn FUSE nichts liefert, die Gruppen aus der lokalen
Nutzerdatenbank auflösen (`getpwuid_r` + `getgrouplist`) — dieselbe Menge, die
der Linux-Kernel-Client mitschicken würde. Hängt am bestehenden Schalter
`fuse_set_user_groups` und greift nur unter `__APPLE__`.

### 15. Schreiben scheitert an der Identität (`patches/0006`)

CephFS prüft uid/gid wie ein lokales Dateisystem. Auf den Linux-Hosts stimmen
die Zahlen (LDAP), auf einem Mac mit lokaler uid 501 nicht — Schreiben scheitert
überall dort, wo man nicht Eigentümer ist.

`client_mount_uid` / `client_mount_gid` existieren in Ceph und sind als „uid to
mount as" dokumentiert, hatten aber keine Wirkung: `Client.cc:408` liest sie
einmal beim Init, während `fuse_ll.cc` bei *jedem* Request ein neues `UserPerm`
aus dem FUSE-Kontext baute.

**Lösung:** alle Aufrufstellen über einen Helfer führen, der die Optionen
berücksichtigt. **Achtung, hier steckt eine Falle:** 16 Stellen heißen `perms`,
vier weitere `perm` — und genau die vier sind `mkdir`, `unlink`, `rename` und
`link`. Wer nur `perms` ersetzt, bekommt einen Client, der Dateien mit der
gepinnten uid anlegt, Verzeichnisse aber mit der lokalen — ein `cp -R` scheitert
dann mit `Permission denied` im gerade selbst erzeugten Verzeichnis. Ein
einfacher Schreibtest mit `dd` läuft an diesem Fehler vorbei.

Konfiguration:

```ini
[client]
    client_mount_uid = <cluster-uid>
    client_mount_gid = <cluster-gid>
```

Die richtige Zahl bekommt man, ohne zu raten: eine Datei über das
Samba-Gateway schreiben und ihren Eigentümer durch den FUSE-Mount ansehen
(`ls -n`) — dort steht die Identität, unter der der Gateway arbeitet.

## Was weiterhin nicht funktioniert

- **Verzeichnisse fremder Gruppen.** Zugriff braucht die jeweilige gid lokal.
  `scripts/add-cluster-groups.sh` legt sie an; die Nummern liefert `id -G` auf
  einem Cluster-Host.
- **Persönliche Dateieigentümerschaft beim Schreiben.** Mit gepinnter uid
  gehören neue Dateien der Sammelidentität — wie beim Samba-Gateway auch. Wer
  die echte Zuordnung will, muss die eigene Cluster-uid lokal vorhalten und
  `client_mount_uid` weglassen.
- **Sequenzieller Durchsatz.** Ein einzelner Lesestrom bleibt deutlich unter dem
  Samba-Gateway. Readahead-Tuning bringt nichts (getestet, siehe Protokoll);
  paralleles Lesen skaliert dagegen.

## Patches pflegen

`scripts/export-patches.sh` erzeugt die Serie neu und prüft anschließend selbst,
dass sie auf den unveränderten Upstream-Baum passt (`git apply --check` gegen
den Vanilla-Commit). Von Hand exportieren lohnt nicht, denn dabei ist genau eine
Falle eingebaut:

`BuildBoost.cmake` baut Boost **im Quellbaum** — `src/boost/bin.v2/`,
`src/boost/stage/`, `project-config.jam`. Wer nach einem Build ein `git add -A`
macht, versioniert diese Artefakte, und `git format-patch` bläst die Serie damit
auf: In unserem Fall trugen zwei Patches zusammen 140 Abschnitte generierter
Dateien mit sich, bei ganze vier echten Quelldateien. Das Export-Skript filtert
sie heraus, `.gitignore` verhindert den Neuzugang, und `.DS_Store` fliegt gleich
mit raus.

## Bei einem Ceph-Update

Die Patches sind klein und plattformbezogen, aber keiner davon ist upstream. Vor
einem Versionswechsel lohnt der Blick, ob die betroffenen Stellen noch
existieren:

| Patch | Datei | Bricht, wenn … |
|---|---|---|
| 0001 | `cmake/modules/BuildBoost.cmake` | die Toolset-Erkennung umgebaut wird |
| 0002 | `cmake/modules/BuildBoost.cmake` | die ARM-Zweige umgebaut werden |
| 0003 | `src/osd/OSDMap.cc`, `src/extblkdev/CMakeLists.txt`, `cmake/modules/FindFUSE.cmake` | die Stellen wegfallen (dann Patch streichen) |
| 0004 | `src/include/ceph_fuse.h`, `src/client/fuse_ll.cc`, `src/client/CMakeLists.txt` | Ceph auf FUSE 3 umstellt oder die xattr-Zweige aufräumt |
| 0005 | `src/client/fuse_ll.cc` | `get_fuse_groups` umgebaut wird |
| 0006 | `src/client/fuse_ll.cc` | neue Aufrufstellen dazukommen — **dann erneut auf `perm` *und* `perms` prüfen** |

Upstream betreibt für macOS keine CI und investiert für macOS-Clients derzeit in
SMB (`ceph smb cluster create --client-compat macos`, Commits Juni/Juli 2026).
Mit Pflege von dieser Seite ist also nicht zu rechnen.
