# DarkTask

Cross-platform systeembeheerder & benchmark-tool (Darkerst Inc.). Vrije, eigen
alternatief in de geest van TMOG — geen licenties, geen phone-home, volledige
broncode van jou.

## Status van deze bouwstap

**Werkend:**
- **Complete zijbalk** met alle TMOG-navigatie-items: Summary,
  Performance, Processes, System Info, Startup apps, Users, Services,
  Power & Freq, Connections, Installed Apps, Disk Space, Benchmarks,
  Log, Settings, Colors — plus eigen DarkTask-branding onderaan (geen
  "PRO"-scheiding, DarkTask heeft geen betaalmodel)
- **Performance** herbouwd als master-detail-layout (net als TMOG):
  links een lijst met CPU/Memory/CPU Power/Thermals/Disk/Network **plus
  elke gedetecteerde GPU** (in TMOG's screenshot niet zichtbaar, maar
  wij hebben wél echte GPU-data, dus die liet ik staan), elk met een
  mini-sparkline. Rechts een gedetailleerde weergave van de selectie —
  het uitgebreidst voor CPU: een volledige-breedte gauge-balk, een grid
  met per-kern live-grafiekjes (`/proc/stat` per kern), en een
  systeeminfo-paneel (basissnelheid/fysieke kernen/virtualisatie/
  frequency driver/sockets/logische processoren/VM-status/governor —
  via `lscpu` en sysfs, één keer gelezen per bezoek, niet elke seconde)
  plus een echt threadaantal (via `ps -eo nlwp`, opgeteld)
- Bewuste weglating: TMOG's per-kern-grafiekjes tonen een tweede
  (rode) lijn naast de blauwe belastingslijn — ik heb geen betrouwbare
  tweede metriek per kern (geen per-kern temperatuur/kernel-tijd
  beschikbaar), dus toon ik daar bewust maar één echte lijn i.p.v. een
  verzonnen tweede
- **System Info uitgebreid**: hostname/OS/kernel/uptime/architectuur,
  CPU-model + kernen, totaal geheugen, gedetecteerde GPU('s),
  fabrikant/model/BIOS-versie/-datum via DMI (`/sys/class/dmi/id/*`),
  desktopomgeving/display-server (X11 vs Wayland)/shell/taal via de
  procesomgeving — gegroepeerd in Systeem/Hardware/Software-secties
- **Startup apps** (nieuw, echt werkend): lijst via `.desktop`-bestanden
  uit `~/.config/autostart` en `/etc/xdg/autostart`, volgens de
  officiële freedesktop.org XDG autostart-specificatie. In-/uitschakelen
  werkt ook echt: systeembrede entries krijgen een
  gebruikers-override-bestand (`Hidden=true/false`), precies zoals de
  spec voorschrijft — geen hack, geen root nodig
- **Users** (nieuw, echt werkend): ingelogde sessies via `who -u`
  (gebruiker, terminal, ingelogd-sinds, host, inactieve tijd),
  aangevuld met per-gebruiker CPU%/geheugen/procesaantal via één
  gebundelde `ps`-aanroep. `who`-regels los getest tegen realistische
  voorbeelden (inclusief lokale sessies, externe SSH-sessies, en
  inactieve terminals) — parseert correct in alle gevallen
- **Services** (nieuw, echt werkend): alle systemd-services via
  `systemctl list-units`/`list-unit-files`, met status (actief/inactief/
  mislukt, kleurgecodeerd), ingeschakeld-bij-opstarten-status, filter op
  naam/omschrijving, en een "alleen actief"-toggle. Starten/stoppen/
  herstarten en in-/uitschakelen werkt echt via `pkexec` (zelfde
  patroon als de GPU-permissiefix) — met een bevestigingsdialoog voor
  Stoppen en Uitschakelen, omdat dat de risicovollere acties zijn. Geeft
  een duidelijke melding i.p.v. een lege lijst op niet-systemd-systemen.
- **Power & Freq** (nieuw, echt werkend): live frequentie per CPU-kern
  (elke seconde ververst), governor + beschikbare governors (wijzigbaar
  via `pkexec`, schrijft naar alle kernen tegelijk), frequency driver,
  frequentiebereik, turbo/boost-status met aan/uit-schakelaar (herkent
  zowel `intel_pstate`'s omgekeerde `no_turbo`-vlag als de generieke
  `cpufreq`-boost-vlag), en batterij-info als het apparaat er een heeft
  (percentage, laadstatus, stroomadapter aangesloten of niet) — die
  sectie verschijnt automatisch niet op een desktop zonder batterij
- **Connections** (nieuw, echt werkend): actieve TCP/UDP-verbindingen
  via `ss -tunap`, met status (kleurgecodeerd: groen=actief,
  blauw=luisterend, oranje=aan het sluiten), lokaal/extern adres+poort,
  en het bijbehorende proces waar zichtbaar (procesinfo is alleen
  zichtbaar voor sockets van je eigen processen, tenzij de app met
  root draait — verbindingen zonder zichtbare procesinfo blijven
  gewoon getoond, niet verborgen). Filter op proces/adres/poort, plus
  TCP/UDP- en "alleen actief"-knoppen. Nette melding op systemen zonder
  `ss` (bijv. zeer minimale installaties zonder `iproute2`).
- **Installed Apps** (nieuw, echt werkend): scant `.desktop`-bestanden
  uit alle standaard applicatiemappen (`/usr/share/applications`,
  `/usr/local/share/applications`, `~/.local/share/applications`, plus
  Flatpak- en Snap-exportmappen), met naam, omschrijving en
  bron-badge (Systeem/Gebruiker/Flatpak/Snap, kleurgecodeerd).
  **Echte iconen**: haalt PNG/XPM-bestanden op uit de standaard
  icoonmappen (`hicolor`-thema, `pixmaps`), met terugval naar een
  generiek icoon als er niets (of alleen SVG, dat renderen we niet
  zonder extra package) gevonden wordt.
  **Verwijderen**: per bron een eigen strategie — Flatpak
  (`flatpak uninstall`, user- of system-scope), Snap (`snap remove`),
  systeempakket (reverse lookup via `dpkg -S`/`rpm -qf`/`pacman -Qo`,
  gevolgd door `apt-get`/`dnf`/`pacman` remove), of bij losse
  gebruikers-`.desktop`-bestanden gewoon dat bestand weghalen. Altijd
  een bevestigingsdialoog die **het exacte commando toont** vóór
  uitvoering, met een extra waarschuwing bij systeempakketten
  (afhankelijkheidsrisico). Achtergrond-/integratie-entries
  (`NoDisplay=true`/`Hidden=true`) worden overgeslagen. Werkt op elke
  distributie. Icoonresolutie en pakketherkenning (Flatpak-scope,
  Snap-naam, dpkg/pacman-output) apart getest tegen realistische
  voorbeelden.
- **Benchmarks** herbouwd in HardInfo/KDiskMark-stijl:
  - **Disk**: nu ook echte IOPS (schrijf + lees), berekend uit het
    daadwerkelijke aantal I/O-operaties ÷ verstreken tijd (bij de
    gebruikte 16 MiB-chunkgrootte — expliciet zo gelabeld, want dat is
    een ander getal dan de gangbare 4K-IOPS die tools als `fio`
    rapporteren). Resultaten in een opgeruimde KDiskMark-achtige tabel
    (Lezen/Schrijven × MB/s/IOPS).
  - **CPU/GPU**: een horizontaal staafdiagram dat je huidige run
    vergelijkt met eerdere runs **in deze sessie, op dezelfde
    intensiteit** — bewust géén vergelijking met een externe
    referentiedatabase (zoals HardInfo's "vergelijk met duizenden
    andere CPU's" doet): die data hebben we niet, en verzonnen
    referentiewaarden tonen zou nepdata als echt presenteren.
- Summary is nu weer **lean**: alleen de compacte overzichtskop
  (gauges, CPU/Memory-grafiek, top-processen, load/tasks, bottom
  staafjes-rij). Geen dubbele content meer met Performance.
- Live monitoring dashboard in Mission-Center-achtige "Summary"-stijl:
  verticale gauge-staafjes voor CPU/Clock/Temp/GPU, CPU-overzichtsgrafiek
  (belasting groen + temperatuur oranje + Kernel rood — echte
  systeemtijd apart gedift), top-processen-tabel, geheugengauge +
  -grafiek, load average, taakaantal, horizontale staafjes-kaarten voor
  CPU-vermogen (RAPL)/Thermals/Disk-I/O-activiteit
  (`/proc/diskstats`)/Netwerk
- Detailkaarten: CPU, Memory, GPU (NVIDIA/AMD/Intel, meerdere tegelijk),
  Schijven (ruimte), Netwerk (LAN/Wi-Fi-herkenning)
- Proceslijst met filter en beëindigen
- Benchmarks: CPU/Disk/GPU met veiligheidsstop en throttle-detectie
- Logscherm: filter, kopiëren, opslaan, wissen
- De overige 2 zijbalk-items (Settings, Colors) zijn eerlijke
  **"Nog niet gebouwd"-placeholders** — geen nepdata

**Nog te doen (volgende bouwstappen):**
- De 9 placeholderschermen één voor één echt maken
- Thema-opties (kleuraccenten, evt. licht thema) — hoort bij "Colors"
- Per-proces GPU-kolom in de procestabel
- Windows/macOS sensor-services

**Performance:**
- Elke pollingronde heeft een in-flight guard: als een ronde (met name
  de GPU/fdinfo-scan) langer duurt dan het 1s-interval, wordt de
  volgende timer-tick overgeslagen in plaats van een overlappende scan
  te starten — anders stapelen dure scans zich op en wordt de app
  steeds trager.
- De fdinfo-scan (die alle processen op het systeem doorzoekt) draait
  hooguit eens per 2 seconden, niet elke pollingronde; tussendoor wordt
  het laatst bekende percentage hergebruikt.
- De fdinfo-scan zelf gebruikt begrensde parallelle I/O (max. 32
  gelijktijdige mapoplijstingen, 64 gelijktijdige bestandslezingen)
  i.p.v. duizenden bestanden na elkaar te lezen.
- **Alleen het zichtbare tabblad pollt.** Summary, Performance en
  Processen pauzeren hun pollingtimer zodra je naar een ander tabblad
  wisselt en hervatten meteen bij terugkeer.
- **`IndexedStack` is verwijderd.** Die hield alle 15 tabbladen
  permanent gebouwd en gelayout in de renderboom (alleen het schilderen
  van niet-actieve tabbladen werd overgeslagen) — dat bleek zelf al
  genoeg om het semantics-framework-probleem te triggeren, ook met
  pollingtimers gepauzeerd. Nu bestaat er op elk moment maar één
  scherm in de widget-boom. **Bijwerking**: tabbladwisselen reset nu
  weer de historie/schuifpositie van dat scherm (zoals vóór de eerdere
  `IndexedStack`-introductie) — die stabiliteit weegt zwaarder dan het
  gemak van behouden state, gezien de crash de hele app onbruikbaar
  maakte.

## Setup (Linux desktop)

Deze instructies volgen jouw standaardconventie:

```bash
flutter config --enable-linux-desktop
flutter create --platforms=linux .
flutter pub get
flutter run -d linux
```

> Let op: op Zorin OS moet Flutter via de tarball op `~/flutter/bin/flutter`
> geïnstalleerd zijn, niet via snap — de snap-sandbox blokkeert de
> pkg-config-paden die nodig zijn voor de native Linux-desktop build.

## Systeemvereisten voor volledige data

- `lm-sensors` (optioneel, fallback voor CPU-temperatuur als hwmon niets
  oplevert): `sudo apt install lm-sensors && sudo sensors-detect`
- `nvidia-smi` (alleen relevant met een NVIDIA-GPU — komt normaal al mee
  met de NVIDIA-driver)
- Intel GPU-belasting: de app leest dit bij voorkeur rechtstreeks uit de
  kernel via `/proc/<pid>/fdinfo/` (dezelfde permissieloze techniek als
  `nvtop` en Frigate's huidige GPU-collector) — **geen extra software,
  geen speciale rechten nodig**, werkt op elke kernel ≥ 5.19 met de i915-
  of xe-driver. Alleen als dat niets oplevert (oudere kernel) valt de
  app terug op `intel-gpu-tools` als los te installeren extraatje. Die
  fallback draait als doorlopend achtergrondproces (niet steeds
  opnieuw gespawned, zoals productiemonitoringtools als Netdata dat ook
  doen) en toont, alleen als hij daadwerkelijk gebruikt wordt en rechten
  mist, zelf een knop ("Rechten herstellen" / "intel-gpu-tools
  installeren") die via `pkexec` de systeem-authenticatiedialoog opent.
  De rechtenfix gebruikt dan `setcap cap_perfmon+ep` op specifiek het
  `intel_gpu_top`-binary — een gerichte, permanente rechtenverlening aan
  precies dat ene programma, niet een systeembrede sysctl-wijziging.

## Architectuur

```
lib/
├── core/
│   ├── logging/app_logger.dart       # centrale logger, singleton
│   └── models/                        # CpuSample, MemorySample, GpuSample, ProcessInfo
├── services/
│   ├── sensors/linux_sensor_service.dart   # /proc + nvidia-smi + lm-sensors
│   └── process_service.dart                # ps-gebaseerde proceslijst + kill
├── features/
│   ├── monitoring/monitoring_dashboard.dart
│   ├── processes/process_list_screen.dart
│   └── benchmarks/benchmarks_screen.dart   # stub, volgende stap
├── widgets/
│   ├── mini_graph.dart                # eigen CustomPainter sparkline
│   └── stat_card.dart
└── app.dart / main.dart
```

Geen netwerkverkeer, geen externe dependencies voor de sensor-logica zelf —
alles leest lokaal uit `/proc`, `/sys`, of shelt naar tools die je toch al
op je systeem hebt staan.
