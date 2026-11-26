import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../core/logging/app_logger.dart';
import 'native_elevation_check.dart';
import 'powershell_session.dart';

const _logSource = 'LibreHardwareMonitor';

/// Whether the LibreHardwareMonitorLib bridge is usable, and why not if
/// it isn't — mirrors the honesty rule used everywhere else in this
/// app: a null/missing sensor reading always comes with a reason a
/// person can act on, not a silent gap.
enum LhmStatus { notChecked, dllMissing, initFailed, ok }

/// Bridges to LibreHardwareMonitorLib (a .NET assembly) from within the
/// shared [PowerShellSession], closing gaps stock Windows WMI simply
/// doesn't cover: CPU temperature, CPU package power, and AMD/Intel GPU
/// load & temperature. NVIDIA GPUs don't need this — `nvidia-smi`
/// already covers them with equally good data (see
/// WindowsSensorService._readNvidiaGpusWindows).
///
/// **The DLL ships bundled with the app**, copied next to the built
/// `.exe` automatically by `windows/runner/CMakeLists.txt` from
/// `windows/runner/lhm/` (the official, unmodified v0.9.6 release —
/// see that folder's `NOTICE.md` for where it came from and the
/// MPL-2.0 license obligation this satisfies). That's the first of
/// [_candidateDllPaths]'s lookup locations, so a normal build finds it
/// immediately with no separate download step or first-run wait.
///
/// This wasn't always the case: an earlier version of this bridge
/// deliberately did NOT ship or download the DLL itself, reasoning
/// that silently fetching and loading an arbitrary third-party .NET
/// assembly from the internet was a bigger trust decision than
/// installing a signed distro package via `pkexec`/`apt-get` the way
/// the Linux side does. Bundling the exact same official release
/// binary directly in the repo — inspected once, checked in, and
/// shipped as a fixed versioned artifact — sidesteps that concern
/// rather than compromising on it: there's no runtime fetch of
/// arbitrary/unpinned code left to trust at all. [downloadAndInstall]
/// below still exists as a repair path (e.g. if these files are ever
/// deleted from an existing install, or for a from-source build that
/// skipped `windows/runner/lhm/`), quietly falling back to returning
/// null (never faking a reading) if the DLL genuinely can't be found
/// anywhere. Marco has previously wired this same library into
/// Hardware Tester via PowerShell, so this is a known-good approach
/// for this app's ecosystem either way.
///
/// **Known requirement**: several sensors (notably CPU temperature) may
/// only populate when the process is running elevated (as
/// Administrator) — this is a LibreHardwareMonitorLib/Windows driver
/// requirement, not something this bridge can work around. If readings
/// stay null even with the DLL correctly in place, that's the first
/// thing to check.
///
/// **Verification note**: written without a Windows machine to test
/// against. The HardwareType/SensorType enum names and sensor-name
/// patterns ("*Package*", "*Core*") are grounded in
/// LibreHardwareMonitor's actual source (HardwareType.cs) and
/// maintainer-provided examples, not guessed — but exact sensor naming
/// has genuinely varied across hardware generations per
/// LibreHardwareMonitor's own maintainers, so a specific CPU/GPU
/// reporting null here is a real possibility worth checking against
/// LibreHardwareMonitor's own standalone app before assuming this
/// bridge is broken.
class LibreHardwareMonitorBridge {
  final PowerShellSession _shell;
  LibreHardwareMonitorBridge(this._shell);

  LhmStatus _status = LhmStatus.notChecked;
  LhmStatus get status => _status;

  /// The exact path [_doInitialize] actually loaded the DLL from —
  /// whichever of [_candidateDllPaths]'s three locations (bundled next
  /// to the .exe, that .exe's `lhm` subfolder, or the LOCALAPPDATA
  /// repair-download location) had a usable copy first. Null until a
  /// successful init has happened at least once.
  ///
  /// Exists specifically so [BackgroundSensorFeed.setupBackgroundService]
  /// can find a real DLL to copy from even when the app's own copy came
  /// from the bundled-next-to-the-.exe location rather than
  /// LOCALAPPDATA — see that method's doc for why it insists on its own
  /// LOCALAPPDATA copy regardless of where this bridge found one.
  String? get loadedDllPath => _status == LhmStatus.ok ? _loadedDllPath : null;
  String? _loadedDllPath;

  /// True while the most recent poll detected LibreHardwareMonitor's
  /// specific "sensor known, value always empty" pattern for CPU
  /// temperature — the signature of needing Administrator privileges
  /// for the low-level MSR access that reading actually requires (see
  /// [readCpuSensors]'s diagnostic logic for the reasoning). Distinct
  /// from "no sensor exists at all" (a genuine hardware/library gap,
  /// like the Intel HD 530 GPU case), which never sets this.
  ///
  /// **Live, not one-shot**: re-evaluated on every [readCpuSensors]
  /// call and cleared back to false the moment a real reading comes
  /// through — so a transient empty read right after
  /// LibreHardwareMonitor's cold start doesn't permanently stick a
  /// "blocked" verdict on a sensor that's actually working fine one
  /// poll later. Only ever set when [NativeElevationCheck.isElevated]
  /// says this process is genuinely NOT elevated at that moment — see
  /// [msrBlockedByVbs] for the same empty-sensor pattern observed while
  /// already elevated, which needs a completely different explanation
  /// and fix.
  bool needsElevation = false;

  /// True while the most recent poll detected the same "sensor known,
  /// value always empty" CPU temperature pattern as [needsElevation] —
  /// but while this process was already confirmed elevated
  /// ([NativeElevationCheck.isElevated] returned true). Elevation is
  /// therefore not the missing piece; telling the user to "restart as
  /// Administrator" here would send them to redo something that
  /// already didn't help.
  ///
  /// The far more likely cause on a modern Windows 11 machine: Memory
  /// Integrity / Core Isolation (Virtualization-Based Security), which
  /// many OEMs now ship turned on by default and which blocks direct
  /// MSR reads for every usermode process regardless of elevation —
  /// a well-known, widely-reported limitation of LibreHardwareMonitor
  /// and every other MSR-based tool (HWiNFO, OpenHardwareMonitor, Core
  /// Temp, ...), not something specific to DarkTask or fixable from
  /// application code. Running inside a VM (where the hypervisor
  /// itself intercepts MSR access) produces the identical symptom for
  /// the identical underlying reason.
  ///
  /// **Live, not one-shot** — same self-healing re-evaluation as
  /// [needsElevation] above; see that field's doc for why that matters.
  bool msrBlockedByVbs = false;

  /// True once the live polling in [readCpuSensors] has seen a real
  /// (non-null) CPU temperature reading — proof MSR access itself
  /// works on this machine right now — while the CPU Package power
  /// sensor keeps reporting exactly 0.0 across several consecutive
  /// polls in a row. Distinct from [msrBlockedByVbs]/[needsElevation]:
  /// those cover "no MSR access at all" (every Temperature sensor
  /// stays null); this covers the narrower, separately-reproducible
  /// case where temperature genuinely works but the RAPL-based Power
  /// sensor ("CPU Package"/Cores/Memory/Platform) stays stuck at a
  /// literal 0.0. LibreHardwareMonitor gives that sensor an explicit
  /// 0.0 default rather than leaving it null (unlike Temperature,
  /// which stays null until a real reading exists), so a plain null
  /// check can't tell "never computed a real value" apart from "this
  /// sensor object was created and immediately read" — hence tracking
  /// this as its own pattern instead of folding it into the
  /// temperature flags above.
  ///
  /// **Live, not one-shot** — same self-healing re-evaluation as
  /// [needsElevation]/[msrBlockedByVbs]: the moment a real non-zero
  /// Package power reading shows up, this clears itself and logs the
  /// recovery, rather than latching permanently from one early
  /// cold-start reading (RAPL's very first Update() after a fresh
  /// Computer.Open() has no prior energy/time baseline to diff
  /// against, so an initial 0.0 is expected and not by itself a sign
  /// of anything wrong — only several in a row is).
  bool cpuPowerStuckAtZero = false;
  int _consecutiveZeroPowerWithRealTemp = 0;

  /// Raw findings from the `$driverDiag` PowerShell list built in
  /// [_doInitialize] — one entry per check ('sc:...', 'service:...',
  /// 'file:...', 'resource:...'), reset to empty on every fresh init
  /// attempt (including after [installPawnIo] resets [_initFuture]) so
  /// a stale verdict from before an install never lingers. Exposed
  /// narrowly through [pawnIoConfirmedMissing] below rather than
  /// directly — callers should never need to parse this list
  /// themselves.
  List<String> _driverDiagFindings = const [];

  /// The exact strings [_doInitialize]'s PowerShell script logs when
  /// each of its three independent PawnIO checks finds nothing —
  /// matched literally rather than with a fuzzier "doesn't look
  /// positive" heuristic, so a check that threw an exception (and
  /// therefore never logged its "not found" marker at all) correctly
  /// keeps [pawnIoConfirmedMissing] at false instead of being
  /// mistaken for a clean negative result.
  static const _scNotFoundMarker =
      'sc:geen pawn/ring0-vermelding in sc.exe query type= driver state= all';
  static const _serviceNotFoundMarker = 'service:geen pawn-service in het serviceregister';
  static const _fileNotFoundMarker = 'file:geen *pawn*-bestand gevonden in de onderzochte mappen';

  /// True once init has run and every one of the three independent
  /// PawnIO checks in [_doInitialize] — the native `sc.exe` driver
  /// list, the service registry, and a filesystem sweep for a stray driver file
  /// — came back completely empty: this machine has never had the
  /// PawnIO kernel driver installed at all. Confirmed live on a real
  /// i5-1135G7 where the TjMax=0 workaround above was independently
  /// verified working (GetReport() showed the corrected value) yet
  /// every CPU Temperature sensor stayed empty regardless — proving
  /// TjMax wasn't the real blocker. LibreHardwareMonitor's own GUI app
  /// shows a one-time install prompt for PawnIO on first run; this
  /// bridge talks to LibreHardwareMonitorLib.dll directly via
  /// reflection and never runs that GUI, so that prompt (and the
  /// install it triggers) never fires through this integration path —
  /// on any machine, not just this one. See [installPawnIo] for the
  /// in-app fix this makes possible.
  bool get pawnIoConfirmedMissing =>
      _driverDiagFindings.contains(_scNotFoundMarker) &&
      _driverDiagFindings.contains(_serviceNotFoundMarker) &&
      _driverDiagFindings.contains(_fileNotFoundMarker);

  static const _dllFileName = 'LibreHardwareMonitorLib.dll';

  /// Plausible locations, checked in order. The first two assume the
  /// DLL ships alongside the built .exe (the natural place once this
  /// is wired into the installer); the last is a manual-drop location
  /// under the user's own profile that needs no rebuild to try.
  List<String> _candidateDllPaths() {
    final paths = <String>[];
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      paths.add('$exeDir\\$_dllFileName');
      paths.add('$exeDir\\lhm\\$_dllFileName');
    } catch (_) {
      // Platform.resolvedExecutable can theoretically throw in unusual
      // embeddings — fall through to the LOCALAPPDATA candidate below.
    }
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null) {
      paths.add('$localAppData\\DarkTask\\$_dllFileName');
    }
    return paths;
  }

  /// Downloads a known-good LibreHardwareMonitorLib build from GitHub
  /// and places the DLL at the LOCALAPPDATA candidate path — a repair/
  /// reinstall path now that the DLL ships bundled by default (see
  /// this class's own doc comment), used when the bundled copy is
  /// somehow missing (deleted from an existing install, or a
  /// from-source build that skipped `windows/runner/lhm/`). Still only
  /// ever runs on explicit request (never automatically), the same as
  /// the Linux side's "install this optional tool" buttons
  /// (`installIntelGpuTools`/glmark2) — downloading and loading a
  /// third-party .NET assembly at runtime is a bigger trust step than
  /// a signed apt/dnf package, worth keeping behind an explicit action
  /// even now that it's a fallback rather than the primary path.
  ///
  /// Runs as its own one-off `powershell.exe` process, deliberately
  /// NOT through the shared [PowerShellSession] — a download can take
  /// anywhere from a few seconds to over a minute depending on
  /// connection speed, and blocking the one shared session for that
  /// long would stall every other sensor reading (CPU/memory/disk/...)
  /// for the whole app in the meantime.
  ///
  /// **Deliberately pinned to a specific known-good release/asset,
  /// not "latest".** Previously pinned to v0.9.4 out of a (as it turned
  /// out, mistaken) assumption that later releases had dropped .NET
  /// Framework builds entirely in favor of .NET-10-only assets.
  ///
  /// Moved to v0.9.5 specifically (not just "whatever still has a
  /// net472 build") because that's the release where upstream replaced
  /// the bundled WinRing0 driver with PawnIO. WinRing0 — what v0.9.4
  /// used — is now on Microsoft's vulnerable-driver blocklist:
  /// Windows Defender quarantines it on sight regardless of admin
  /// elevation or Memory Integrity settings, which is a real,
  /// confirmed failure mode this app hit in testing (sensors enumerate
  /// correctly, every value stays empty, with a
  /// "VulnerableDriverWinNT/Winring0" detection in Defender's
  /// protection history). PawnIO is a separately-signed, actively
  /// maintained driver built specifically to replace WinRing0 across
  /// the hardware-monitoring ecosystem for this exact reason.
  ///
  /// The asset itself is a combined `LibreHardwareMonitor.zip` now
  /// (confirmed against the release's own download link), not a
  /// framework-specific `-net472.zip` the way v0.9.4 shipped it —
  /// **verified by actually downloading and extracting it** (not
  /// guessed): it's a single flat folder containing one copy of
  /// `LibreHardwareMonitorLib.dll` (a net472-targeted build, alongside
  /// `LibreHardwareMonitor.exe`, its own GUI-only dependencies like
  /// OxyPlot/Aga.Controls, and per-language satellite resource
  /// folders) — not the per-target-framework subfolders (net472,
  /// net8.0-windows, ...) an earlier version of this comment assumed
  /// might be there. The extraction script's `net472` folder-name
  /// match below is accordingly a no-op today (there's only one copy
  /// to find either way) but is left in place as cheap forward
  /// compatibility, in case a future release does reorganize into
  /// per-framework subfolders the way v0.9.4-era naming once hinted at.
  /// `windows/runner/lhm/` (this DLL's primary source now — see this
  /// class's own doc comment) was populated from this exact same
  /// verified download, keeping only the `.dll` files and dropping the
  /// `.exe`/`.pdb`/`.xml`/`.config` and language subfolders this bridge
  /// never needs.
  ///
  /// **Bumped again to v0.9.6** after a real, reproduced compatibility
  /// failure with v0.9.5.0 on a live machine: PawnIO was confirmed
  /// genuinely installed and RUNNING (`sc.exe query` showing
  /// `STATE: 4 RUNNING, WIN32_EXIT_CODE: 0`), the official
  /// LibreHardwareMonitor GUI app (v0.9.6.0) read real CPU temperature
  /// and package power off that exact driver instance without issue —
  /// yet this app's own bundled LibreHardwareMonitorLib v0.9.5.0,
  /// against the same running driver moments later, enumerated every
  /// CPU sensor as empty (`Computer.GetReport()` showing
  /// `Version: 0.9.5.0` with nothing but blank values). Since v0.9.4 →
  /// v0.9.5 is precisely where upstream swapped in PawnIO, it's a
  /// reasonable inference that PawnIO itself has moved on since (the
  /// official app's own installer may bundle/require a newer PawnIO
  /// build than the one DarkTask's separate `PawnIO_setup.exe` download
  /// installs), and v0.9.5.0's compiled-in expectations of that driver
  /// (module ABI, `.bin` resource format, or similar) no longer match
  /// on that class of install. **Verified before making this change**
  /// (not guessed): downloaded and extracted both the v0.9.5 and v0.9.6
  /// release zips directly — same flat single-folder layout, an
  /// identical set of 27 top-level `.dll` filenames on both sides (no
  /// dependency added or dropped), and confirmed the previously-bundled
  /// `LibreHardwareMonitorLib.dll` was a byte-for-byte match of the
  /// official v0.9.5 build (1,138,688 bytes,
  /// MD5 `27771c1fe285376f6c99c3fd9be3a4d9`) while v0.9.6's is a
  /// genuinely different, larger build (1,203,200 bytes,
  /// MD5 `ecc49bd21fc187ba1a39b2f84bcfb9af`). All 27 `.dll` files in
  /// `windows/runner/lhm/` were swapped 1:1 for their v0.9.6
  /// counterparts on that basis.
  static const _pinnedDownloadUrl =
      'https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/v0.9.6/LibreHardwareMonitor.zip';

  Future<bool> downloadAndInstall({void Function(String status)? onProgress}) async {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null) {
      AppLogger.instance.error(_logSource, 'LOCALAPPDATA environment variable not set — cannot determine install location.');
      return false;
    }
    final targetDir = '$localAppData\\DarkTask';
    final targetPath = '$targetDir\\$_dllFileName';

    onProgress?.call('Downloaden...');
    AppLogger.instance.info(_logSource, 'Downloaden van LibreHardwareMonitorLib (v0.9.6, net472, PawnIO) gestart (doel: $targetPath)');

    // Escaped for embedding inside the single-quoted PowerShell string
    // literal below — same doubling rule as in _ensureInitialized.
    final targetDirEscaped = targetDir.replaceAll("'", "''");

    final script = '''
\$ErrorActionPreference = 'Stop'
try {
  \$tempZip = Join-Path \$env:TEMP 'darktask_lhm_download.zip'
  \$tempExtract = Join-Path \$env:TEMP 'darktask_lhm_extract'

  Invoke-WebRequest -Uri '$_pinnedDownloadUrl' -OutFile \$tempZip -UseBasicParsing

  if (Test-Path \$tempExtract) { Remove-Item \$tempExtract -Recurse -Force }
  Expand-Archive -Path \$tempZip -DestinationPath \$tempExtract -Force

  # v0.9.5's combined zip almost certainly contains more than one copy
  # of this filename — one per bundled target framework. Picking
  # blindly (as the old single-framework v0.9.4 zip safely could) risks
  # grabbing a .NET 8/9/10 build instead of net472, which classic
  # PowerShell 5.1's Add-Type cannot load — trading the WinRing0/
  # Defender problem this migration fixes for a silent load failure
  # instead. A path containing "net472" is matched explicitly first;
  # only if that specific folder isn't present does this fall back to
  # whatever copy exists, so a differently-organized future release
  # doesn't leave this with nothing at all.
  \$dllFile = Get-ChildItem -Path \$tempExtract -Filter '$_dllFileName' -Recurse |
    Where-Object { \$_.DirectoryName -match 'net472' } |
    Select-Object -First 1
  if (-not \$dllFile) {
    \$dllFile = Get-ChildItem -Path \$tempExtract -Filter '$_dllFileName' -Recurse | Select-Object -First 1
  }
  if (-not \$dllFile) { Write-Output 'DARKTASK_LHM_INSTALL_ERROR: LibreHardwareMonitorLib.dll niet gevonden in het gedownloade archief'; exit 1 }

  New-Item -ItemType Directory -Force -Path '$targetDirEscaped' | Out-Null
  # Copy every DLL sitting alongside LibreHardwareMonitorLib.dll, not
  # just that one file — it depends on several others (HidSharp,
  # System.Management, etc.) that .NET's assembly resolution needs to
  # find in the same directory. Copying only the single requested file
  # leaves those dependencies missing and causes a
  # ReflectionTypeLoadException ("Kan een of meer van de gevraagde
  # typen niet laden") at Add-Type time — the exact failure this fixes.
  #
  # Added 2026-09-12, reproduced live: this used to be one blind
  # \`Copy-Item ... -Force\` over the whole *.dll glob, which aborts the
  # ENTIRE install the moment any single sibling DLL can't be
  # overwritten — reproduced on a real machine where a leftover
  # DiskInfoToolkit.dll from an earlier install was still held open by
  # another process (most likely the background sensor service's own
  # long-running PowerShell process, which keeps every DLL it has ever
  # loaded via LoadFrom locked for as long as it keeps running), giving
  # "Kan geen toegang krijgen tot het bestand ... omdat het wordt
  # gebruikt door een ander proces." and failing the whole download for
  # what was really just one stale-but-present file. Copying file by
  # file instead means a locked file is only a genuine problem when
  # there's nothing already at the destination to fall back on — a
  # locked file that already exists there (almost always an identical
  # leftover of the same pinned version) is perfectly usable as-is, so
  # that case is now a collected warning rather than an aborted install.
  \$copyWarnings = New-Object System.Collections.Generic.List[string]
  foreach (\$srcDll in (Get-ChildItem -Path \$dllFile.DirectoryName -Filter '*.dll')) {
    \$destPath = Join-Path '$targetDirEscaped' \$srcDll.Name
    try {
      Copy-Item \$srcDll.FullName \$destPath -Force -ErrorAction Stop
    } catch {
      if (Test-Path \$destPath) {
        \$copyWarnings.Add(\$srcDll.Name + ': ' + \$_.Exception.Message)
      } else {
        # No existing copy to fall back on — this dependency would
        # genuinely be missing, so re-throw and let the outer catch
        # report this as the real install failure it is.
        throw
      }
    }
  }

  # Belt-and-braces alongside the same Unblock-File call
  # _ensureInitialized() makes right before loading: the file just
  # downloaded via Invoke-WebRequest above is itself a fresh
  # Mark-of-the-Web candidate, so there's no reason to assume this
  # copy needs it less than a manually-bundled one does. Cheap and
  # idempotent either way.
  Get-ChildItem -Path '$targetDirEscaped' -Filter '*.dll' -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

  Remove-Item \$tempZip -Force -ErrorAction SilentlyContinue
  Remove-Item \$tempExtract -Recurse -Force -ErrorAction SilentlyContinue

  if (\$copyWarnings.Count -gt 0) {
    # Separate line/marker from DARKTASK_LHM_INSTALL_OK below, on
    # purpose — that line's own regex on the Dart side captures
    # everything after the colon as the source directory, so appending
    # free-form warning text there would corrupt that capture instead
    # of being parsed as anything meaningful.
    Write-Output ('DARKTASK_LHM_INSTALL_WARNINGS:' + (\$copyWarnings -join ' || '))
  }
  Write-Output ('DARKTASK_LHM_INSTALL_OK:' + \$dllFile.DirectoryName)
} catch {
  Write-Output ('DARKTASK_LHM_INSTALL_ERROR: ' + \$_.Exception.Message)
}
''';

    try {
      onProgress?.call('Downloaden en installeren...');
      final result = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-Command', script],
      ).timeout(const Duration(minutes: 2));

      final output = '${result.stdout}\n${result.stderr}';
      if (output.contains('DARKTASK_LHM_INSTALL_OK')) {
        final dirMatch = RegExp(r'DARKTASK_LHM_INSTALL_OK:(.+)').firstMatch(output);
        final sourceDir = dirMatch?.group(1)?.trim();
        AppLogger.instance.info(
          _logSource,
          'LibreHardwareMonitorLib.dll succesvol geïnstalleerd op $targetPath'
          '${sourceDir != null ? ' (uit: $sourceDir)' : ''}.',
        );
        // One or more sibling DLLs couldn't be refreshed (almost always
        // because another process — most likely the background sensor
        // service's own long-running PowerShell process — still had a
        // leftover copy from an earlier install open) but already
        // existed at the destination, so the install itself still
        // succeeded using that existing copy rather than aborting — see
        // this method's own PowerShell script for the reasoning.
        final warnMatch = RegExp(r'DARKTASK_LHM_INSTALL_WARNINGS:(.+)').firstMatch(output);
        if (warnMatch != null) {
          AppLogger.instance.info(
            _logSource,
            'Let op: ${warnMatch.group(1)?.trim()} kon niet vervangen worden door de zojuist '
            'gedownloade versie (waarschijnlijk nog open bij een ander proces, zoals de '
            'achtergronddienst) — de al aanwezige kopie wordt gebruikt in plaats daarvan. Dit is '
            'meestal onschuldig (dezelfde gepinde versie als hiervoor); sluit DarkTask volledig af '
            '(ook het systeemvakicoontje) en start opnieuw als sensoren hierna nog steeds niet '
            'werken.',
          );
        }
        // Force the next sensor read to re-run _ensureInitialized()
        // against the newly-downloaded file, instead of remembering
        // the earlier "missing" result for the rest of the session —
        // clearing the stored Future (not a boolean flag) is what
        // makes _ensureInitialized()'s `??=` create a genuinely fresh
        // attempt next time, consistent with the single-flight pattern
        // that method now uses throughout.
        _initFuture = null;
        _status = LhmStatus.notChecked;
        // A freshly-downloaded DLL means an entirely new
        // Computer/Hardware object next init, with its own sensor
        // instances — the one-shot "LHM-sensordump voor CPU/GPU" log
        // lines (and the RAPL-power stuck-at-zero streak below) need
        // to run again against that new state rather than staying
        // silent for the rest of the session because they already
        // fired once against the old, now-replaced object.
        _cpuSensorDiagnosticLogged = false;
        _gpuSensorDiagnosticLogged = false;
        cpuPowerStuckAtZero = false;
        _consecutiveZeroPowerWithRealTemp = 0;
        return true;
      }

      final errorMatch = RegExp(r'DARKTASK_LHM_INSTALL_ERROR:\s*(.+)').firstMatch(output);
      AppLogger.instance.error(
        _logSource,
        'Downloaden/installeren van LibreHardwareMonitorLib mislukt: '
        '${errorMatch?.group(1)?.trim() ?? output.trim()}',
      );
      return false;
    } catch (e) {
      AppLogger.instance.error(_logSource, 'Downloaden/installeren van LibreHardwareMonitorLib mislukt: $e');
      return false;
    }
  }

  /// Official installer for PawnIO (namazso/PawnIO.Setup) — the
  /// universal kernel driver LibreHardwareMonitor has needed for real
  /// MSR-based reads (CPU temperature/power) since v0.9.4. A separate,
  /// independently-maintained project, unrelated to LibreHardwareMonitor's
  /// own repo/release — see [pawnIoConfirmedMissing]'s doc for how this
  /// was confirmed as the actual, machine-specific blocker rather than
  /// guessed.
  ///
  /// "/latest/download/..." deliberately resolves to whichever release
  /// is newest at request time, unlike [_pinnedDownloadUrl]'s fixed
  /// version for LibreHardwareMonitor itself: that DLL is a managed
  /// .NET assembly this app loads into its own process, where pinning
  /// avoids an unpinned supply-chain surprise; PawnIO is a signed,
  /// security-sensitive kernel driver, where running an old, possibly-
  /// since-patched build on purpose would be the wrong tradeoff.
  /// Whichever version this resolves to, the download is verified by
  /// Authenticode signature before it's ever executed — see
  /// [installPawnIo] below.
  static const _pawnIoInstallerUrl =
      'https://github.com/namazso/PawnIO.Setup/releases/latest/download/PawnIO_setup.exe';

  /// Downloads the official PawnIO installer and runs it, so
  /// LibreHardwareMonitor's MSR-based CPU temperature/power reads can
  /// actually work — see [pawnIoConfirmedMissing]'s doc for why this
  /// is needed at all. This is not a DarkTask or LibreHardwareMonitor
  /// bug: it's a one-time, machine-wide driver installation the
  /// official LibreHardwareMonitor app normally prompts for through UI
  /// this reflection-based bridge never shows.
  ///
  /// Only ever runs on an explicit button click — same reasoning as
  /// [downloadAndInstall] above, one level more serious: that method
  /// downloads a managed .NET DLL this app then loads into its own
  /// process; this one downloads and runs, *elevated*, a signed
  /// third-party **kernel driver installer**. Nothing here happens
  /// without a person choosing it.
  ///
  /// 1. Downloads PawnIO_setup.exe to a temp file — a one-off
  ///    `powershell.exe` process, same reasoning as [downloadAndInstall]
  ///    for not using the shared [PowerShellSession] (this can take a
  ///    while and must never stall every other sensor reading).
  /// 2. Verifies its Authenticode signature is `Valid` *before* running
  ///    it — a signature that isn't valid aborts here with an error,
  ///    never a "run anyway" fallback, since this file is about to run
  ///    elevated.
  /// 3. Launches it via `Start-Process -ArgumentList '-install','-silent'
  ///    -Verb RunAs -WindowStyle Hidden -Wait` — `-install -silent` is
  ///    PawnIO's own publisher-declared unattended switch combination
  ///    (confirmed against its winget manifest and a maintainer-
  ///    provided script in a LibreHardwareMonitor discussion covering
  ///    this exact "install PawnIO silently from another app" case;
  ///    not guessed), so no installer window or wizard ever appears —
  ///    a person clicking the button in DarkTask's own UI is the only
  ///    consent step, not a second one from PawnIO's installer. DarkTask
  ///    already runs elevated at this point (see this class's own
  ///    "Known requirement" doc), so this normally proceeds without a
  ///    UAC prompt either. `-Wait` still blocks until the install
  ///    actually finishes — bounded by a 2-minute timeout below, ample
  ///    for an unattended install with no one to wait on, matching this
  ///    app's habit of never waiting unboundedly on an external
  ///    process.
  /// 4. Re-checks PawnIO's presence directly (never trusts the
  ///    installer's own exit code as proof — this app never claims a
  ///    reading or a fix succeeded without confirming it) and, only on
  ///    a confirmed-positive result, resets [_initFuture] the same way
  ///    [downloadAndInstall] does so the next sensor read re-runs
  ///    [_doInitialize] (and its driver diagnostics) from scratch
  ///    instead of trusting a now-stale "missing" verdict.
  Future<bool>? _installPawnIoInFlight;

  /// Added 2026-09-13, reproduced live: three independent call sites can
  /// each decide "PawnIO is confirmed missing" around the same moment —
  /// `autoProvisionSensorDependencies()`'s own check, this bridge's own
  /// `readCpuSensors()` self-heal (added the day before specifically to
  /// stop waiting on a screen to be opened), and the manual "Installeer
  /// PawnIO" button — and none of them knew about the others. Before this
  /// wrapper existed, each just called the method below directly, so two
  /// (or three) of them could all start their own independent download to
  /// the exact same fixed temp path (`darktask_pawnio_setup.exe`) at
  /// once — reproduced live as one of them failing outright with "Kan
  /// geen toegang krijgen tot het bestand ... omdat het wordt gebruikt
  /// door een ander proces", right after the newly-added self-heal call
  /// made exactly this race far more likely to actually occur. This
  /// method itself is now the single choke point: every caller — present
  /// or any future one — goes through here, so a second concurrent call
  /// simply awaits the one already in progress instead of starting a
  /// colliding second download, with no per-call-site coordination
  /// required anywhere else.
  Future<bool> installPawnIo({void Function(String status)? onProgress}) {
    final inFlight = _installPawnIoInFlight;
    if (inFlight != null) {
      AppLogger.instance.info(
        _logSource,
        'PawnIO-installatie is al bezig (gestart via een andere aanroep) — wacht op dat resultaat in '
        'plaats van een tweede, botsende download te starten.',
      );
      return inFlight;
    }
    final future = _doInstallPawnIo(onProgress: onProgress);
    _installPawnIoInFlight = future;
    // Whichever way it finishes, the choke point above must be cleared
    // afterward so a genuinely later, non-concurrent retry (a new
    // self-heal cycle, a fresh button press) isn't permanently blocked
    // by an attempt that's long since finished.
    unawaited(future.whenComplete(() => _installPawnIoInFlight = null));
    return future;
  }

  Future<bool> _doInstallPawnIo({void Function(String status)? onProgress}) async {
    final installerPath = '${Directory.systemTemp.path}\\darktask_pawnio_setup.exe';
    // Escaped for embedding inside the single-quoted PowerShell string
    // literals below — same doubling rule as _ensureInitialized/
    // downloadAndInstall use for their own paths.
    final installerPathEscaped = installerPath.replaceAll("'", "''");

    onProgress?.call('PawnIO-installer downloaden...');
    AppLogger.instance.info(_logSource, 'PawnIO-installer downloaden gestart (doel: $installerPath).');

    final downloadScript = '''
\$ErrorActionPreference = 'Stop'
try {
  Invoke-WebRequest -Uri '$_pawnIoInstallerUrl' -OutFile '$installerPathEscaped' -UseBasicParsing
  Unblock-File -Path '$installerPathEscaped' -ErrorAction SilentlyContinue
  \$sig = Get-AuthenticodeSignature -FilePath '$installerPathEscaped'
  Write-Output ('DARKTASK_PAWNIO_DOWNLOAD_OK:' + \$sig.Status + ':' + \$sig.StatusMessage)
} catch {
  Write-Output ('DARKTASK_PAWNIO_DOWNLOAD_ERROR: ' + \$_.Exception.Message)
}
''';

    try {
      final downloadResult = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-Command', downloadScript],
      ).timeout(const Duration(minutes: 2));

      final downloadOutput = '${downloadResult.stdout}\n${downloadResult.stderr}';
      final okMatch = RegExp(r'DARKTASK_PAWNIO_DOWNLOAD_OK:([^:]+):(.*)').firstMatch(downloadOutput);
      if (okMatch == null) {
        final errorMatch = RegExp(r'DARKTASK_PAWNIO_DOWNLOAD_ERROR:\s*(.+)').firstMatch(downloadOutput);
        AppLogger.instance.error(
          _logSource,
          'Downloaden van de PawnIO-installer mislukt: '
          '${errorMatch?.group(1)?.trim() ?? downloadOutput.trim()}',
        );
        return false;
      }

      final sigStatus = okMatch.group(1)!.trim();
      if (sigStatus != 'Valid') {
        AppLogger.instance.error(
          _logSource,
          'PawnIO-installer gedownload, maar de digitale handtekening is niet geldig '
          '(status: $sigStatus — ${okMatch.group(2)?.trim()}). Installatie NIET gestart, '
          'als voorzorg tegen een gemanipuleerd of beschadigd bestand.',
        );
        await _deletePawnIoInstallerQuietly(installerPath);
        return false;
      }

      AppLogger.instance.info(
        _logSource,
        'PawnIO-installer gedownload en handtekening geverifieerd (status: Valid). '
        'Stille installatie wordt nu gestart (geen apart venster).',
      );
      onProgress?.call('PawnIO installeren (stil, op de achtergrond)...');

      // `-install -silent` is PawnIO's own publisher-declared unattended
      // switch combination (confirmed against both its winget manifest
      // and a maintainer-provided script in a LibreHardwareMonitor
      // discussion about this exact scenario — see this method's own
      // doc comment) — not guessed or reverse-engineered. No UI shows
      // at all with these flags; `-WindowStyle Hidden` on top is
      // belt-and-braces for the same "genuinely no visible window"
      // guarantee, not strictly required by the switches themselves.
      // `-Wait` still blocks until the (now near-instant, unattended)
      // install finishes, so the shorter 2-minute timeout below is
      // generous for a silent run rather than one a person has to
      // click through — same defensive habit as elsewhere in this app
      // of never waiting on an external process unboundedly.
      final runScript = '''
\$ErrorActionPreference = 'Stop'
try {
  \$p = Start-Process -FilePath '$installerPathEscaped' -ArgumentList '-install', '-silent' -Verb RunAs -WindowStyle Hidden -PassThru -Wait
  Write-Output ('DARKTASK_PAWNIO_RUN_OK:' + \$p.ExitCode)
} catch {
  Write-Output ('DARKTASK_PAWNIO_RUN_ERROR: ' + \$_.Exception.Message)
}
''';

      final runResult = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-Command', runScript],
      ).timeout(const Duration(minutes: 2));

      final runOutput = '${runResult.stdout}\n${runResult.stderr}';
      await _deletePawnIoInstallerQuietly(installerPath);

      if (!runOutput.contains('DARKTASK_PAWNIO_RUN_OK')) {
        final errorMatch = RegExp(r'DARKTASK_PAWNIO_RUN_ERROR:\s*(.+)').firstMatch(runOutput);
        AppLogger.instance.error(
          _logSource,
          'Starten van de PawnIO-installer mislukt: '
          '${errorMatch?.group(1)?.trim() ?? runOutput.trim()}',
        );
        return false;
      }

      // Added 2026-09-13, reproduced live: the installer's exit code was
      // captured (`\$p.ExitCode` above) but never actually surfaced
      // anywhere — only whether `Start-Process` itself threw was
      // checked. That leaves a real, reproduced failure mode completely
      // invisible: "-install -silent" running to completion (no
      // exception, some exit code) while the functional re-check right
      // below still finds no driver at all afterward — happened three
      // times on the same machine in one evening, each time with zero
      // information about *why* beyond "it didn't work". Logging the raw
      // exit code here, unconditionally, doesn't fix that by itself, but
      // it's the one piece of evidence that can actually distinguish "the
      // installer's own logic rejected something" (a non-zero code) from
      // "it reported success yet the driver still isn't there" (zero) —
      // the next time this happens, this line is what tells us which.
      final exitCodeMatch = RegExp(r'DARKTASK_PAWNIO_RUN_OK:(-?\d+)').firstMatch(runOutput);
      final pawnIoInstallerExitCode = exitCodeMatch != null ? int.tryParse(exitCodeMatch.group(1)!) : null;
      AppLogger.instance.info(
        _logSource,
        'PawnIO-installer ("-install -silent") uitgevoerd, exitcode: '
        '${pawnIoInstallerExitCode?.toString() ?? '(niet te ontleden uit: ${runOutput.trim()})'}. Dit zegt '
        'op zichzelf nog niets over echt succes — de functionele her-check hieronder is doorslaggevend — '
        'maar is waardevol als die her-check alsnog "niet aanwezig" meldt.',
      );

      onProgress?.call('Controleren of PawnIO nu aanwezig is...');
      // Never trusts the installer's own exit code as proof of
      // success (it might be a user-cancel, or a code this app simply
      // doesn't know the meaning of for this particular installer) —
      // a fast, standalone re-check of the same two signals
      // _doInitialize's own driver diagnostic uses, run right here.
      const verifyScript = r'''
try {
  $found = $false
  $scOut = @(sc.exe query type= driver state= all 2>&1)
  if ($scOut -match 'pawn') { $found = $true }
  if (-not $found) {
    $svc = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match 'pawn' })
    if ($svc.Count -gt 0) { $found = $true }
  }
  Write-Output ('DARKTASK_PAWNIO_VERIFY:' + $found)
} catch {
  Write-Output ('DARKTASK_PAWNIO_VERIFY_ERROR: ' + $_.Exception.Message)
}
''';
      // Added 2026-09-13, same lesson already applied to the self-heal
      // elsewhere in this file: a single check run immediately after the
      // installer returns can catch PawnIO's service registration
      // mid-flight — not yet visible to sc.exe/Get-Service for a moment
      // even though the install itself is fine, and a check moments
      // later would find it present. Polling a few times with a short
      // pause, instead of trusting one immediate Process.run, absorbs
      // that startup lag instead of reporting a false "niet aanwezig"
      // the instant the installer process exits. Costs nothing in the
      // common case (stops at the first successful check) and at most
      // ~6 extra seconds in the worst case — cheap next to the alternative
      // of telling someone to reboot over a check that just ran too soon.
      var verified = false;
      var verifyOutput = '';
      for (var attempt = 0; attempt < 4 && !verified; attempt++) {
        if (attempt > 0) await Future.delayed(const Duration(seconds: 2));
        final verifyResult = await Process.run(
          'powershell.exe',
          ['-NoProfile', '-NonInteractive', '-Command', verifyScript],
        ).timeout(const Duration(seconds: 15));
        verifyOutput = '${verifyResult.stdout}\n${verifyResult.stderr}';
        verified = verifyOutput.contains('DARKTASK_PAWNIO_VERIFY:True');
      }

      // Either way, whatever was true before this install attempt is
      // now stale — force the next sensor read to re-run
      // _doInitialize() (and its driver diagnostics) from scratch
      // rather than keep trusting an outdated verdict, successful
      // install or not.
      _initFuture = null;
      _status = LhmStatus.notChecked;
      _driverDiagFindings = const [];
      // Same reasoning as the identical reset after a fresh DLL
      // download above: a successful PawnIO install means the next
      // init builds an entirely new Computer/Hardware object (this is
      // what finally gives it working MSR access), so the one-shot
      // sensor dumps and the RAPL-power stuck-at-zero streak need a
      // clean slate too, instead of staying silent/latched from
      // whatever they last saw against the old, pre-PawnIO object.
      _cpuSensorDiagnosticLogged = false;
      _gpuSensorDiagnosticLogged = false;
      cpuPowerStuckAtZero = false;
      _consecutiveZeroPowerWithRealTemp = 0;

      if (!verified) {
        AppLogger.instance.error(
          _logSource,
          'De stille PawnIO-installatie is afgerond, maar de driver is nog steeds niet aantoonbaar '
          'aanwezig op dit systeem. Mogelijk is een herstart nodig voordat de driver actief wordt — '
          'probeer het na een herstart eventueel opnieuw, of controleer het Log-tabblad op een '
          'foutmelding van de installer zelf.',
        );
        return false;
      }

      // `verified` above only proves the Service Control Manager has a
      // PawnIO entry — reproduced live on a real machine: `-install
      // -silent` left a registered (even briefly RUNNING) service
      // there, sc.exe/Get-Service happily confirmed it, yet every MSR
      // read through it stayed empty regardless — while the official,
      // interactive PawnIO installer on that exact same machine fixed
      // it instantly. A registered service is evidently not proof the
      // driver is actually *functional*, so this does one more, real
      // check before ever claiming success: force a fresh
      // _doInitialize() against the driver that was just installed,
      // then genuinely try to read a temperature through it — the only
      // check that can't be fooled by a service that merely exists
      // without working.
      onProgress?.call('Controleren of PawnIO écht werkt...');
      // Added 2026-09-13: the exact same false-negative timing race
      // documented and fixed for the SCM-registration check just above
      // applies here too, and was in fact the originally-reported one —
      // a captured log once showed this single readCpuSensors() call
      // reporting empty moments before an unrelated, independent
      // LibreHardwareMonitor re-init succeeded against the very same
      // just-installed driver. A short retry absorbs that instead of
      // sending someone to manually reinstall PawnIO over a check that
      // just ran a beat too soon.
      Map<String, dynamic>? functionalCpu;
      var functionallyWorking = false;
      for (var attempt = 0; attempt < 3 && !functionallyWorking; attempt++) {
        if (attempt > 0) await Future.delayed(const Duration(seconds: 2));
        functionalCpu = await readCpuSensors();
        functionallyWorking = functionalCpu?['temperatureC'] != null;
      }

      if (!functionallyWorking) {
        AppLogger.instance.error(
          _logSource,
          'PawnIO-service is geregistreerd (en soms zelfs actief) volgens Windows, maar levert nog '
          'geen werkende CPU-temperatuur op via deze stille installatie — een bekend patroon op '
          'sommige systemen waar "-install -silent" een onvolledige of niet-functionele driver '
          'achterlaat, terwijl de gewone (interactieve) PawnIO-installer op datzelfde systeem wél '
          'werkt. Download en installeer PawnIO handmatig via '
          'https://github.com/namazso/PawnIO.Setup/releases/latest als dit blijft gebeuren — '
          'DarkTask pakt de sensoren daarna vanzelf op, zonder verdere actie.',
        );
        return false;
      }

      AppLogger.instance.info(
        _logSource,
        'PawnIO-driver bevestigd aanwezig én functioneel na installatie (echte temperatuurwaarde '
        'gelezen). CPU-temperatuur/-vermogen werken nu via LibreHardwareMonitor.',
      );
      return true;
    } catch (e) {
      AppLogger.instance.error(_logSource, 'PawnIO-installatie mislukt: $e');
      await _deletePawnIoInstallerQuietly(installerPath);
      return false;
    }
  }

  /// Best-effort cleanup of the downloaded installer — a leftover
  /// temp file is harmless, so failures here are swallowed rather than
  /// surfaced as if the install itself had failed.
  Future<void> _deletePawnIoInstallerQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best-effort only.
    }
  }

  Future<bool>? _initFuture;

  /// Returns the *same* in-flight (or already-completed) Future to
  /// every caller — concurrent callers (e.g. `readCpu()` and
  /// `readGpus()` racing during the splash screen's parallel sensor
  /// warm-up) all await the one real initialization attempt, instead
  /// of a second caller seeing a too-early "already attempted" flag
  /// and concluding initialization had already finished
  /// (unsuccessfully) while it was actually still in progress. That
  /// exact race was reproduced in testing: a concurrent GPU read
  /// during warm-up got an empty result purely from this timing issue,
  /// visible in the UI as a brief "n/a" GPU load flash right after
  /// startup — not a hardware/driver problem, a bug in this bridge's
  /// own guard. `??=` is what makes this safe: Dart resolves an
  /// already-completed Future immediately and a still-pending one by
  /// genuinely waiting, so every caller gets the correct final result
  /// regardless of arrival order.
  Future<bool> _ensureInitialized() => _initFuture ??= _doInitialize();

  Future<bool> _doInitialize() async {
    String? foundPath;
    for (final path in _candidateDllPaths()) {
      try {
        if (await File(path).exists()) {
          foundPath = path;
          break;
        }
      } catch (_) {
        // Inaccessible path candidate — try the next one.
      }
    }

    if (foundPath == null) {
      _status = LhmStatus.dllMissing;
      AppLogger.instance.info(
        _logSource,
        'LibreHardwareMonitorLib.dll niet gevonden (gezocht op: ${_candidateDllPaths().join(', ')}). '
        'CPU-temperatuur/-vermogen en AMD/Intel-GPU-belasting/-temperatuur blijven onbeschikbaar tot dit '
        'bestand op een van die plekken staat. Download: '
        'https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases — dit bericht komt niet terug.',
      );
      return false;
    }

    // PowerShell single-quoted strings escape an embedded ' by
    // doubling it — unrelated to (and not affected by) Dart's own
    // string-escaping rules, since this text becomes literal
    // PowerShell source once written to the session's stdin.
    final escapedPath = foundPath.replaceAll("'", "''");
    final script = "try { "
        // Strips the NTFS "Zone.Identifier" alternate data stream
        // (Windows' Mark-of-the-Web) from every DLL in this folder,
        // not just LibreHardwareMonitorLib.dll itself — its
        // dependencies (HidSharp.dll, several System.* polyfills, ...)
        // get lazily LoadFrom'd from the same directory too, and any
        // one of them being blocked can produce the same failure.
        //
        // Why this exists: a DLL that Windows considers downloaded
        // from the internet gets this flag stamped on it, and
        // [Reflection.Assembly]::LoadFrom refuses to load a blocked
        // assembly from a local path in that state — a well-known
        // .NET behavior, not specific to this bridge. The bundled
        // copies in windows/runner/lhm/ genuinely did come from the
        // internet (an official GitHub release, downloaded once to
        // populate that folder — see NOTICE.md there) and can carry
        // that flag all the way from the original download, through a
        // zip transfer, into a person's own project folder, and then
        // simply get copied as-is next to the built .exe — nothing in
        // that chain strips it on its own. Reported and reproduced:
        // this bridge worked on a machine where the DLL had been
        // sitting around long enough to already be unblocked, but
        // failed to load — silently, from the app's perspective, since
        // it's an OS-level block rather than a missing-file or
        // wrong-format error — on a freshly set up machine where it
        // hadn't been. `-ErrorAction SilentlyContinue` because
        // Unblock-File itself can fail on a filesystem that doesn't
        // support alternate data streams (e.g. some network shares) —
        // in that case there was never anything to unblock in the
        // first place, so a failure here is not itself a problem.
        r"Get-ChildItem -Path (Split-Path -Parent '" +
        escapedPath +
        r"') -Filter '*.dll' -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue; " +
        // [Reflection.Assembly]::LoadFrom instead of `Add-Type -Path`
        // for the same already-compiled DLL — both end up with
        // LibreHardwareMonitorLib's types resolvable via the
        // [LibreHardwareMonitor.Hardware.___] syntax used everywhere
        // below, but `Add-Type` does meaningfully more work even when
        // pointed at a precompiled assembly: it additionally generates
        // and compiles a small PowerShell type-accelerator wrapper
        // around it, on top of the plain reflection load. For a
        // ready-made .dll (as opposed to `Add-Type -TypeDefinition`
        // compiling raw C# source, which still needs `Add-Type`),
        // `Assembly.LoadFrom` is the documented faster path — it's the
        // same technique .NET/PowerShell performance guides recommend
        // for exactly this "load a precompiled managed DLL and call
        // into it by full type name" case. Loading the return value
        // into `Out-Null` just discards the `Assembly` object handle;
        // nothing here needs to hold onto it directly.
        "[Reflection.Assembly]::LoadFrom('$escapedPath') | Out-Null; "
        // Added 2026-09-14: on a recreate (the NOT_STOPPABLE self-heal
        // path further down calling this a second/third time within
        // the same session), $global:__darktaskLhm already holds a
        // previous Computer object whose Open() was called earlier and
        // whose Close() was never called — the old object was simply
        // overwritten below, orphaning it for the garbage collector
        // instead of releasing it. Computer.Close() is LibreHardware-
        // Monitor's own documented way to release whatever it opened in
        // Open() (including, per its source, actually closing its
        // handle(s) to PawnIO); skipping it meant every recreate left a
        // stale handle behind on top of the new one instead of a clean
        // handoff. Not confirmed yet to be the actual fix for the
        // "recreate ran, reads are still empty" case reproduced live on
        // the i5-1135G7 machine (see the VBS/Memory Integrity check
        // added just below for the leading theory there), but it is a
        // real resource leak either way and a correct recreate should
        // never skip it. `-ErrorAction SilentlyContinue` plus the
        // surrounding try/catch: on the very first init this session,
        // $global:__darktaskLhm doesn't exist yet, and calling .Close()
        // on a Computer that was never Open()'d could itself throw —
        // neither case should block creating the new object.
        r"try { if ($global:__darktaskLhm) { $global:__darktaskLhm.Close() } } catch { } "
        r"$global:__darktaskLhm = New-Object LibreHardwareMonitor.Hardware.Computer; "
        r"$global:__darktaskLhm.IsCpuEnabled = $true; "
        r"$global:__darktaskLhm.IsGpuEnabled = $true; "
        r"$driverDiag = New-Object System.Collections.Generic.List[string]; "
        // Added 2026-09-11, same i7-6700 machine, after the v0.9.5 →
        // v0.9.6 bump alone didn't fix it: a fresh capture confirmed
        // PawnIO's *service* was still `STATE : 1 STOPPED` (WIN32_EXIT_
        // CODE 1077 — "never started since last configured") even
        // *after* `Open()` had already run and returned — despite the
        // comment below this block assuming `Open()` reliably triggers
        // that start itself. On this machine, evidently, it doesn't:
        // a kernel-driver service's demand start isn't triggered just
        // by a usermode client opening its device path the way a
        // regular Win32 service can be — something has to explicitly
        // call StartService (or `sc start`) first, and whatever
        // PawnIO's own client-library code inside LibreHardwareMonitorLib
        // does for that apparently isn't succeeding here (no exception
        // surfaces either way — Open() just silently proceeds with
        // ring-0 access unavailable). The official, standalone
        // LibreHardwareMonitor.exe reading this exact machine
        // correctly (confirmed via that user's own uploaded report)
        // is the strongest evidence this bridge's *own* invocation
        // context is the missing piece, not the driver itself — so
        // this explicitly starts the service one step earlier than
        // `Open()`, with its real `sc.exe` output captured (not
        // swallowed — same lesson as the separate reset script's
        // `sc.exe stop`/`delete` fix) so a still-failing attempt shows
        // the actual Win32 reason (e.g. access denied, path not found)
        // instead of another silent gap. Harmless to run unconditionally:
        // starting an already-running service just returns "already
        // started" back through the same captured text.
        r"try { "
        r"  $scStartOut = (Invoke-ScOem start PawnIO | Out-String).Trim() -replace '\s+', ' '; "
        r"  $driverDiag.Add('prestart:' + $scStartOut); "
        r"} catch { $driverDiag.Add('prestart:EXCEPTION ' + $_.Exception.Message) } "
        r"$global:__darktaskLhm.Open(); "
        // Added 2026-09-22: the sc.exe/service-register/filesystem/VBS
        // diagnostic sweep further down used to run unconditionally on
        // every single init, even on a machine where CPU temperature
        // already works fine — pure overhead nobody benefits from, on
        // top of everything else Open() already does. This cheap
        // pre-check (one Update() call plus a sensor-value lookup, not
        // a full re-scan of anything) decides whether that heavier
        // sweep is actually needed this time.
        //
        // Deliberately checked right here, *before* the TjMax=0
        // workaround loop further below has had a chance to run: a
        // machine that's only affected by the TjMax quirk (temperature
        // would work fine once that's corrected) still gets the full
        // sweep below, exactly as before this change — this only skips
        // the sweep on the common case of a machine where PawnIO/MSR
        // access already works outright, which is the case this
        // diagnostic sweep was never actually needed for in the first
        // place.
        r"$needsDriverDiag = $true; "
        r"try { "
        r"  foreach ($hw in $global:__darktaskLhm.Hardware) { "
        r"    if ($hw.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::Cpu) { "
        r"      $hw.Update(); "
        r"      $tempHit = @($hw.Sensors | Where-Object { $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and $null -ne $_.Value }); "
        r"      if ($tempHit.Count -gt 0) { $needsDriverDiag = $false } "
        r"    } "
        r"  } "
        r"} catch { } "
        // Added 2026-09-11, same i5-1135G7 machine: the TjMax=0
        // workaround below now demonstrably works (GetReport() showed
        // TjMax's Value corrected to 100 after it), yet every CPU
        // Temperature-type sensor still stays completely empty
        // afterwards. TjMax is only a calibration constant — the
        // actual reading comes from an MSR (IA32_THERM_STATUS,
        // 0x19C), and reading any MSR requires ring-0 access that even
        // an elevated (Administrator) usermode process cannot do
        // directly. Since LibreHardwareMonitor 0.9.4 that ring-0 access
        // goes through a bundled kernel driver called "PawnIO" (a
        // generic signed loader; earlier versions used "WinRing0"
        // instead) — a separate, one-time OS-level installation step
        // Open() is supposed to trigger. A manual `sc query PawnIO` on
        // this machine came back completely empty, suggesting that
        // install never happened — but that check was run by hand, in
        // a separate PowerShell window, possibly before or after the
        // fact. This block re-checks the same thing from right here, in
        // the same process, immediately after Open() actually ran,
        // three fast, non-WMI ways so a gap in one doesn't hide the
        // answer: `sc.exe query` (the native Service Control Manager
        // driver/service list — authoritative, independent of whether
        // a Windows "service" wrapper shows up anywhere else), Get-
        // Service (in case it does register as a manageable service),
        // and a filesystem sweep for any stray *pawn* file near the
        // DLL, in System32\drivers, %ProgramData%, and %TEMP% (in case
        // the driver file was extracted but never registered as a
        // service at all). Every finding is collected into $driverDiag
        // (declared just before the explicit pre-Open() `sc start`
        // attempt above, so that attempt's own output ends up in this
        // same combined dump too) and reported unconditionally below
        // (never gated on finding "the" answer), same reasoning as the
        // Parameters dump: guessing a fourth time isn't worth another
        // round-trip when the ground truth can just be logged directly.
        // Fixed 2026-09-11, same machine, before this ever reached a
        // real user: the very first version of this diagnostic used
        // Get-CimInstance -ClassName Win32_SystemDriver (WMI, known to
        // be slow — often several seconds just to enumerate every
        // driver on the system) plus a Get-WinEvent System-log scan
        // (rendering every event's .Message property is also slow when
        // there are more than a handful of matches). Both run inside
        // the same single persistent PowerShell session every other
        // sensor in this app shares — so those few slow seconds didn't
        // just delay this one diagnostic, they blocked that entire
        // session's command queue long enough to blow through this
        // bridge's own command timeout, which then cascaded: the init
        // itself came back as "(geen output)", and every other
        // PowerShell-backed sensor queued behind it (network counters,
        // page file, disk space, CPU clock, GPU name, ...) timed out
        // too, all in the same log capture. Replaced both with
        // `sc.exe query` — a thin wrapper over the native Service
        // Control Manager API, not WMI, and normally near-instant even
        // with many drivers installed — and dropped the event-log scan
        // entirely rather than try to make it fast enough to trust
        // inside a shared, latency-sensitive session.
        r"if ($needsDriverDiag) { "
        r"try { "
        r"  $scOut = @(sc.exe query type= driver state= all 2>&1); "
        r"  $scHits = for ($i = 0; $i -lt $scOut.Count; $i++) { if ($scOut[$i] -match 'pawn|ring0') { $endIdx = [Math]::Min($i + 4, $scOut.Count - 1); (($scOut[$i..$endIdx] -join ' | ') -replace '\s+', ' ') } }; "
        r"  if ($scHits) { foreach ($h in $scHits) { $driverDiag.Add('sc:' + $h) } } "
        r"  else { $driverDiag.Add('sc:geen pawn/ring0-vermelding in sc.exe query type= driver state= all') } "
        r"} catch { $driverDiag.Add('sc:EXCEPTION ' + $_.Exception.Message) } "
        r"try { "
        // Get-Service only lists Win32 services, never kernel drivers,
        // so it could not see PawnIO even while it was RUNNING (the
        // log said "geen pawn-service" right next to an sc.exe line
        // showing PawnIO RUNNING). Kernel drivers are registered
        // under this registry key, which is fast and needs no WMI.
        r"  $ms = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match 'pawn' }); "
        r"  if ($ms.Count -gt 0) { foreach ($s in $ms) { $driverDiag.Add('service:' + $s.PSChildName + ' (serviceregister, Start=' + $s.GetValue('Start') + ')') } } "
        r"  else { $driverDiag.Add('service:geen pawn-service in het serviceregister') } "
        r"} catch { $driverDiag.Add('service:EXCEPTION ' + $_.Exception.Message) } "
        r"try { "
        r"  $lhmDir = Split-Path -Parent '" +
        escapedPath +
        r"'; "
        r"  $dirs = @($lhmDir, 'C:\Windows\System32\drivers', ($env:ProgramData + '\LibreHardwareMonitor'), $env:TEMP); "
        r"  foreach ($dir in $dirs) { if ($dir -and (Test-Path $dir)) { $found = Get-ChildItem -Path $dir -Filter '*pawn*' -ErrorAction SilentlyContinue; if ($found) { foreach ($f in $found) { $driverDiag.Add('file:' + $f.FullName) } } } } "
        r"  if (-not ($driverDiag -match '^file:')) { $driverDiag.Add('file:geen *pawn*-bestand gevonden in de onderzochte mappen') } "
        r"} catch { $driverDiag.Add('file:EXCEPTION ' + $_.Exception.Message) } "
        // Added 2026-09-11, same machine: all three checks above came
        // back completely empty — no driver, no service, no stray
        // file anywhere. That's consistent with either (a) something
        // external silently blocking/removing the driver during
        // installation (antivirus quietly quarantining an extracted
        // .sys file is a classic, near-silent cause), or (b) this
        // specific LibreHardwareMonitorLib.dll build never had a
        // PawnIO payload to install in the first place — e.g. a
        // trimmed/partial release asset. This tells the two apart
        // cheaply: GetManifestResourceNames() is a plain .NET
        // reflection call on the assembly already sitting in memory —
        // no external process, no WMI, effectively instant — that
        // lists every resource actually embedded inside the DLL. If a
        // PawnIO-related resource shows up here, the driver payload is
        // present and something later in the chain is blocking it
        // (points at (a)); if nothing like it shows up at all, this
        // copy of the DLL never had it to install (points at (b)).
        r"try { "
        r"  $asm = [LibreHardwareMonitor.Hardware.Computer].Assembly; "
        r"  $resNames = $asm.GetManifestResourceNames(); "
        r"  if ($resNames -and $resNames.Count -gt 0) { foreach ($rn in $resNames) { $driverDiag.Add('resource:' + $rn) } } "
        r"  else { $driverDiag.Add('resource:geen embedded resources in LibreHardwareMonitorLib.dll') } "
        r"} catch { $driverDiag.Add('resource:EXCEPTION ' + $_.Exception.Message) } "
        // Added 2026-09-14, reproduced live on this same i5-1135G7
        // machine, AGAIN, after the NOT_STOPPABLE self-heal above
        // (recreating this Computer/Hardware object in-process) had
        // already run: temperature *and* power both stayed at their
        // empty/zero starting point, immediately, with the driver
        // diagnostics above showing PawnIO's service healthy and
        // RUNNING the entire time. That rules out the failure mode the
        // self-heal above was actually built for (a stale object
        // created before the driver was ready) — a brand-new object
        // talking to an already-healthy, already-running driver has
        // nothing stale left to fix, yet the reads still come back
        // empty. The next most likely explanation, from this file's own
        // long-standing "mogelijke oorzaken"-message further down:
        // Virtualization-Based Security / Memory Integrity (Core
        // Isolation), which can let a legitimately signed, running
        // kernel driver open its device and report success while the
        // hypervisor silently denies the actual RDMSR the driver tries
        // to issue underneath — no exception anywhere in this chain,
        // because from PawnIO's own point of view nothing failed. This
        // checks the exact registry values Windows Security's "Core
        // isolation" toggle reads/writes, the fast way (raw
        // HKLM reads, not the Win32_DeviceGuard WMI class — same
        // "avoid WMI inside this shared session" lesson as the sc.exe
        // switch above) rather than guessing a fourth time: if the next
        // capture from this machine shows both of these as 1/enabled,
        // that confirms VBS/Memory Integrity as the actual blocker, not
        // another self-heal-able state.
        r"try { "
        r"  $vbsEnabled = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name 'EnableVirtualizationBasedSecurity' -ErrorAction SilentlyContinue).EnableVirtualizationBasedSecurity; "
        r"  $hvciEnabled = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name 'Enabled' -ErrorAction SilentlyContinue).Enabled; "
        r"  $driverDiag.Add('vbs:EnableVirtualizationBasedSecurity=' + ($(if ($null -eq $vbsEnabled) { '(niet aanwezig)' } else { $vbsEnabled })) + ' HVCI/MemoryIntegrity.Enabled=' + ($(if ($null -eq $hvciEnabled) { '(niet aanwezig)' } else { $hvciEnabled }))); "
        r"} catch { $driverDiag.Add('vbs:EXCEPTION ' + $_.Exception.Message) } "
        r"} else { $driverDiag.Add('skipped:CPU-temperatuur werkte al direct na Open(), diagnostische sweep overgeslagen') } "
        // Best-effort nudge, not a required step — wrapped in its own
        // swallow-everything try/catch so a failure here never aborts
        // the whole init. Reproduced live on an 11th Gen Intel Core
        // i5-1135G7 (Tiger Lake, family 6 model 0x8C): every CPU
        // temperature sensor stays null while every CPU *power* (RAPL)
        // sensor reads a real (if literally 0) value — and
        // Computer.GetReport()'s own Parameters section showed every
        // core's "TjMax" parameter sitting at 0 instead of a sane
        // ~100°C default, alongside every one of that core's
        // Temperature-type sensors ("CPU Core #1", "... Distance to
        // TjMax", ...) staying unpopulated. LibreHardwareMonitor
        // exposes TjMax as a user-settable Parameter specifically
        // because its own MSR-based auto-detection (IA32_TEMPERATURE_-
        // TARGET, MSR 0x1A2) is documented as unreliable on some
        // CPUs/steppings — its GUI app's own sensor settings page lets
        // a person manually fix exactly this. Doing the same
        // programmatically here, once at init, means a person never
        // has to know this workaround exists. 100°C is Tiger Lake
        // mobile's typical TjMax (matches Intel's published spec for
        // this CPU family) — not a universal constant, but a far
        // better default than 0, and only applied when the
        // auto-detected value is exactly 0 (never overwrites a real,
        // successfully-read TjMax).
        // Fixed 2026-09-10, same machine: the very first attempt at
        // this workaround had zero effect (GetReport() still showed
        // "TjMax : 0 : 0" afterwards) — because it ran immediately
        // after Open(), before this specific hardware class's Sensors
        // (and their Parameters) are actually populated. CPU sensor
        // objects here aren't guaranteed to exist until the first
        // Update() call, so that original foreach found nothing to
        // touch at all — silently, since an empty collection isn't an
        // error. Calling Update() once *before* touching Parameters
        // (to force their creation) and once *after* (to force
        // recomputation using the corrected value) is the fix; $ok
        // tracks how many Parameters this actually changed, reported
        // back below so this can be confirmed from the log instead of
        // guessed at again.
        // Fixed AGAIN 2026-09-10, same machine: adding the extra
        // Update() call still fixed zero Parameters — so the "Sensors
        // don't exist until the first Update()" theory wasn't it
        // either, or wasn't the whole story. Rather than guess a third
        // time, this now dumps every Parameter this loop actually
        // finds on every CPU sensor (name, and its owning sensor's
        // name), unconditionally — not just ones matching "TjMax" —
        // so the next log capture shows the ground truth instead of
        // this code's assumptions about it: whether the Parameters
        // collection is genuinely empty at this point, whether "TjMax"
        // is spelled/cased differently than expected, or whether it's
        // there with a value this comparison isn't matching for some
        // other reason.
        // Found it, 2026-09-11, same machine: the dump confirmed the
        // Parameter is real and sitting at 0 — but its .Name is
        // literally "TjMax [°C]" (LibreHardwareMonitor appends the
        // unit to every Parameter's display name), not bare "TjMax".
        // Both earlier attempts used an exact `-eq 'TjMax'` match,
        // which silently never matched anything, which is the entire
        // reason $tjMaxFixedCount stayed 0 both times even though the
        // value was plainly 0 in the same GetReport() dump. Switched
        // the comparison to `-like 'TjMax*'` so it matches regardless
        // of the trailing unit annotation.
        r"$tjMaxFixedCount = 0; "
        r"$paramDump = New-Object System.Collections.Generic.List[string]; "
        r"try { "
        r"  foreach ($hw in $global:__darktaskLhm.Hardware) { "
        r"    if ($hw.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::Cpu) { "
        r"      $hw.Update(); "
        r"      foreach ($s in $hw.Sensors) { "
        r"        foreach ($p in $s.Parameters) { "
        r"          $paramDump.Add($s.Name + ':' + $p.Name + '=' + $p.Value); "
        r"          if ($p.Name -like 'TjMax*' -and $p.Value -eq 0) { $p.Value = 100; $tjMaxFixedCount++ } "
        r"        } "
        r"      } "
        r"      $hw.Update(); "
        r"    } "
        r"  } "
        r"} catch { $paramDump.Add('EXCEPTION: ' + $_.Exception.Message) } "
        r"Write-Output ('DARKTASK_LHM_OK tjmax_fixed=' + $tjMaxFixedCount + ' params_found=' + $paramDump.Count + ' params=[' + ($paramDump -join ';') + '] driverdiag=[' + ($driverDiag -join ';') + ']') "
        "} catch { "
        // A plain $_.Exception.Message for a ReflectionTypeLoadException
        // (the "kan een of meer van de gevraagde typen niet laden"
        // error — usually a missing dependency DLL sitting next to
        // LibreHardwareMonitorLib.dll) is close to useless: it names
        // the exception, not which dependency actually failed. The
        // real detail lives one level deeper, in LoaderExceptions —
        // check both the exception itself and its InnerException,
        // since which one carries LoaderExceptions has varied across
        // .NET/PowerShell versions in the wild.
        r"$msg = $_.Exception.Message; "
        r"$loaderEx = $null; "
        r"if ($_.Exception.LoaderExceptions) { $loaderEx = $_.Exception.LoaderExceptions } "
        r"elseif ($_.Exception.InnerException.LoaderExceptions) { $loaderEx = $_.Exception.InnerException.LoaderExceptions } "
        r"if ($loaderEx) { $msg += ' | LoaderExceptions: ' + (($loaderEx | ForEach-Object { $_.Message }) -join '; ') } "
        r"Write-Output ('DARKTASK_LHM_ERROR: ' + $msg) "
        "}";

    // Retries a bounded number of times, but ONLY when the previous
    // attempt came back completely empty — the specific signature of
    // this exact command's client-side 8-second PowerShellSession
    // timeout firing (see PowerShellSession.run's doc) rather than any
    // real failure. Reproduced live: this script is easily the
    // heaviest single command in the shared session (Assembly.LoadFrom
    // + Computer.Open()'s PawnIO driver load + hardware enumeration +
    // the full driver diagnostic sweep), and cold app-startup fires
    // several *other* PowerShell-backed reads (page-file usage,
    // network counters, video controller CIM, ...) at nearly the same
    // instant — all serialized through the one shared session — so
    // this command can easily still be queued behind them when its own
    // 8-second client timeout fires, even though the real
    // powershell.exe process is working through the backlog just fine
    // and would have produced real output moments later.
    //
    // A non-empty result containing 'DARKTASK_LHM_ERROR:' is a
    // genuinely reported failure (e.g. a ReflectionTypeLoadException)
    // and is NOT retried here — retrying a real error wastes time
    // without changing the outcome; only a timeout is worth retrying.
    //
    // This matters because `_ensureInitialized()`'s `_initFuture` is a
    // single-flight cache: whatever this method returns is permanent
    // for the rest of the app session (see that method's doc) — a
    // scheme with no retry at all would let one unlucky cold-start
    // timeout silently and permanently disable CPU temperature/power,
    // GPU load/temperature, and the PawnIO auto-install/diagnostics for
    // the entire session, with nothing short of restarting the app
    // able to recover it.
    const maxAttempts = 3;
    String trimmed = '';
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      // 30 s instead of the 8 s default: on a cold start this command
      // (assembly load + PawnIO driver start + hardware enumeration +
      // the driver diagnostics) was measured at over 8 s, so it timed
      // out on the first attempt on a slower machine and had to be
      // retried.
      final result = await _shell.run(script, timeout: const Duration(seconds: 30));
      trimmed = result?.trim() ?? '';
      if (trimmed.isNotEmpty) break;
      if (attempt < maxAttempts) {
        AppLogger.instance.debug(
          _logSource,
          'Init-poging $attempt/$maxAttempts kwam zonder output terug (waarschijnlijk de shared '
          'PowerShell-sessie die nog een opstart-drukte van andere commando\'s aan het inhalen is) — '
          'nieuwe poging na een korte pauze.',
        );
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    if (!trimmed.contains('DARKTASK_LHM_OK')) {
      _status = LhmStatus.initFailed;
      final looksLikeMissingDependency = trimmed.contains('LoaderExceptions');
      AppLogger.instance.error(
        _logSource,
        'LibreHardwareMonitorLib.dll gevonden op $foundPath, maar laden/initialiseren mislukte na '
        '$maxAttempts poging(en): '
        '${trimmed.isEmpty ? '(geen output)' : trimmed}. '
        '${looksLikeMissingDependency ? 'Dit patroon (LoaderExceptions) wijst meestal op een ontbrekend '
                'DLL-bestand naast LibreHardwareMonitorLib.dll (bv. HidSharp.dll) — probeer opnieuw '
                'te installeren via de knop, of controleer handmatig of alle .dll-bestanden uit het '
                'gedownloade archief in dezelfde map staan.'
            : 'Kan ook betekenen dat DarkTask als Administrator moet draaien voor deze specifieke '
                'sensor — een bekende LibreHardwareMonitorLib-beperking die deze bridge niet kan '
                'omzeilen.'}',
      );
      return false;
    }

    _status = LhmStatus.ok;
    _loadedDllPath = foundPath;
    AppLogger.instance.info(_logSource, 'LibreHardwareMonitorLib geladen vanaf $foundPath.');

    // Surfaces whether the TjMax=0 workaround (see the init script
    // above) actually found and changed anything — logged explicitly
    // so a future "did that fix help?" question never again needs a
    // guess: 0 means either every core's TjMax was already fine on
    // this machine, or (as happened the first two times this
    // workaround was tried) the Parameters weren't matched at all.
    //
    // `params_found`/`params=[...]` is the unconditional ground-truth
    // dump added after the first two attempts both silently fixed
    // nothing — every Parameter this init script actually saw on every
    // CPU sensor, not just ones matching "TjMax". Always logged (not
    // gated on tjmax_fixed being 0) so the *shape* of what's there is
    // visible even in the success case, in case "TjMax" is present but
    // under a name/casing this bridge isn't matching.
    final tjMaxMatch = RegExp(r'tjmax_fixed=(\d+)').firstMatch(trimmed);
    final tjMaxCount = tjMaxMatch != null ? (int.tryParse(tjMaxMatch.group(1)!) ?? 0) : null;
    if (tjMaxCount != null && tjMaxCount > 0) {
      AppLogger.instance.info(
        _logSource,
        'TjMax-workaround: $tjMaxCount parameter(s) met TjMax=0 gecorrigeerd naar 100°C.',
      );
    }

    final paramsMatch = RegExp(
      r'params_found=(\d+) params=\[(.*)\] driverdiag=\[(.*)\]$',
    ).firstMatch(trimmed);
    if (paramsMatch != null) {
      final foundCount = paramsMatch.group(1);
      final dump = paramsMatch.group(2)!;
      final driverDiagDump = paramsMatch.group(3)!;
      // Stored (not just logged) so pawnIoConfirmedMissing can answer
      // synchronously later, from whatever UI is asking — e.g. the
      // Performance screen deciding whether to offer the "install
      // PawnIO" button — without re-running or re-parsing anything.
      _driverDiagFindings = driverDiagDump.isEmpty ? const [] : driverDiagDump.split(';');
      AppLogger.instance.info(
        _logSource,
        'CPU-sensor Parameters bij init (tjmax_fixed=${tjMaxCount ?? 0}, $foundCount gevonden): '
        '${dump.isEmpty ? '(leeg — geen enkele Parameter gevonden op geen enkele CPU-sensor)' : dump}',
      );
      // See the long comment above the PowerShell block that builds
      // this ($driverDiag) for why: TjMax is now demonstrably fixed
      // (Value corrected to 100) but temperatures still stay empty,
      // which means the actual blocker is one level deeper than TjMax
      // — the PawnIO kernel driver LibreHardwareMonitor needs for the
      // real ring-0 MSR read. This dump is the ground truth on whether
      // that driver ever got installed/loaded on this machine, sourced
      // three fast, non-WMI ways (native `sc.exe query`, service registry)
      // plus a filesystem sweep for a stray driver file that never got
      // registered as a service.
      AppLogger.instance.info(
        _logSource,
        'PawnIO/ring0-driverdiagnose (sc.exe query + serviceregister + bestandssweep + DLL-resourcelijst): '
        '${driverDiagDump.isEmpty ? '(leeg)' : driverDiagDump}',
      );
    }
    return true;
  }

  /// Returns `{'temperatureC': ..., 'powerWatts': ...}` (either may be
  /// null if that specific sensor isn't exposed for this CPU — a real,
  /// hardware-dependent gap per LibreHardwareMonitor's own
  /// maintainers, not a bug in this bridge), or null entirely if the
  /// library itself isn't usable (see [status]).
  ///
  /// Cached for a fraction of a second: [WindowsSensorService] calls
  /// this from up to three independent places per poll tick
  /// (`readCpu()`'s temperature, `readCpuPowerWatts()`, and the
  /// die-shared-temperature fallback for Intel iGPUs) — without this
  /// cache, each of those would trigger its own full PowerShell
  /// round-trip for what is always the exact same underlying reading
  /// at that moment, needlessly stacking up latency on the one shared
  /// [PowerShellSession] every single second. The cache window is
  /// short enough that it never serves genuinely stale data across
  /// separate polls, only across callers within the same tick.
  Map<String, double?>? _cpuSensorCache;
  DateTime? _cpuSensorCacheTime;
  static const _cpuSensorCacheTtl = Duration(milliseconds: 800);

  Future<Map<String, double?>?> readCpuSensors() async {
    final cached = _cpuSensorCache;
    final cachedAt = _cpuSensorCacheTime;
    if (cached != null && cachedAt != null && DateTime.now().difference(cachedAt) < _cpuSensorCacheTtl) {
      return cached;
    }

    if (!await _ensureInitialized()) return null;

    final script = r"$r = @{ tempC = $null; powerW = $null; fanRpm = $null; sensors = @(); tempSensorTotal = 0; tempSensorWithValue = 0 }; "
        r"foreach ($hw in $global:__darktaskLhm.Hardware) { "
        r"  if ($hw.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::Cpu) { "
        r"    $hw.Update(); "
        r"    $allTempSensors = @($hw.Sensors | Where-Object { $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature }); "
        r"    $tempSensors = @($allTempSensors | Where-Object { $null -ne $_.Value }); "
        r"    $powerSensors = @($hw.Sensors | Where-Object { $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Power -and $null -ne $_.Value }); "
        r"    $fanSensors = @($hw.Sensors | Where-Object { $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Fan -and $null -ne $_.Value }); "
        r"    $r.tempSensorTotal = $allTempSensors.Count; "
        r"    $r.tempSensorWithValue = $tempSensors.Count; "
        r"    $tempPick = $tempSensors | Where-Object { $_.Name -like '*Package*' } | Select-Object -First 1; "
        r"    if (-not $tempPick) { $tempPick = $tempSensors | Select-Object -First 1 } "
        r"    if ($tempPick) { $r.tempC = [double]$tempPick.Value } "
        r"    $powerPick = $powerSensors | Where-Object { $_.Name -like '*Package*' } | Select-Object -First 1; "
        r"    if (-not $powerPick) { $powerPick = $powerSensors | Select-Object -First 1 } "
        r"    if ($powerPick) { $r.powerW = [double]$powerPick.Value } "
        // CPU fan sensors are exposed by LibreHardwareMonitor through
        // the motherboard/Super I/O chip, not the CPU hardware node
        // itself, on most boards — but a handful of vendors' Embedded
        // Controller sensors DO surface a "Fan" sensor directly under
        // the Cpu HardwareType too, so this is a real, if inconsistent,
        // reading rather than one this bridge fabricates from nothing.
        // Left null (never a fabricated 0) when the CPU node exposes no
        // Fan-type sensor at all, same "no fake data" rule as every
        // other reading in this file.
        r"    $fanPick = $fanSensors | Select-Object -First 1; "
        r"    if ($fanPick) { $r.fanRpm = [double]$fanPick.Value } "
        r"    foreach ($s in $hw.Sensors) { $r.sensors += ($s.Name + ' [' + $s.SensorType + ']=' + $s.Value) } "
        r"  } "
        r"}; "
        r"$r | ConvertTo-Json -Compress";

    final result = await _shell.run(script);
    if (result == null) return null;
    final trimmed = result.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed) as Map<String, dynamic>;

      // Same one-time raw diagnostic dump as readGpuSensors() — the
      // only way to tell, for CPU hardware this bridge hasn't been
      // tested against, whether "no reading" means "no sensor exists"
      // or "exists under an unexpected name". Deliberately still
      // one-shot (unlike the flag logic just below, which is NOT
      // one-shot any more) — this is purely a log-spam guard, logging
      // the full sensor list on every single poll would drown out
      // everything else in the Log tab for no benefit.
      if (!_cpuSensorDiagnosticLogged) {
        _cpuSensorDiagnosticLogged = true;
        final sensorList = (decoded['sensors'] as List?)?.join(', ') ?? '(geen sensoren)';
        AppLogger.instance.info(_logSource, 'LHM-sensordump voor CPU: $sensorList');
      }

      // LibreHardwareMonitor enumerating temperature sensors (it knows
      // they should exist) but every one having a null Value is a
      // specific, recognizable pattern — distinct from "this hardware
      // genuinely has no temperature sensor" (which shows as zero
      // enumerated sensors, like the earlier Intel HD 530 GPU case).
      // Historically this always meant "needs Administrator elevation"
      // — but that's only true when this process isn't already
      // elevated. On a process that IS already elevated (see
      // NativeElevationCheck, logged once at startup), the identical
      // symptom instead points at Memory Integrity / Core Isolation
      // (Virtualization-Based Security) — increasingly the default on
      // new Windows 11 OEM machines — or at running inside a VM,
      // either of which blocks MSR access for every process regardless
      // of elevation. Telling someone who's already elevated to "start
      // as Administrator" would send them to redo something that
      // provably didn't help, so the two cases get different flags and
      // different messages.
      //
      // **Re-evaluated on every call, not just once** — this used to
      // live inside the one-shot diagnostic-dump block above and never
      // ran again after the very first poll. That meant a single
      // transient empty read right after LibreHardwareMonitor's cold
      // start (Computer.Open()/the first Update() call sometimes needs
      // a moment before MSR reads actually populate — a real,
      // reproduced race, not hypothetical) could permanently latch
      // needsElevation/msrBlockedByVbs to true for the rest of the
      // session, even once every subsequent read came back with real
      // values — exactly the "warning banner stuck even though the
      // number is right there working" symptom this was reported with.
      // Recomputing every call, and explicitly clearing both flags the
      // moment a real reading shows up, makes this self-healing instead
      // of a one-shot snapshot that can never recover from a bad first
      // read.
      final tempTotal = (decoded['tempSensorTotal'] as num?)?.toInt() ?? 0;
      final tempWithValue = (decoded['tempSensorWithValue'] as num?)?.toInt() ?? 0;
      if (tempTotal > 0 && tempWithValue == 0) {
        if (NativeElevationCheck.isElevated() == true) {
          // Self-heal, once per session, before falling through to the
          // generic warning below. Reproduced live on a real machine:
          // elevated, PawnIO's service already confirmed `RUNNING`
          // (proven by the same `sc.exe start` diagnostic elsewhere in
          // this file returning "already started"), and Memory
          // Integrity/VBS confirmed OFF by the person on that exact
          // machine — every condition this bridge knows how to check
          // was fine, yet temperature stayed empty regardless. A bare
          // `sc start` against an already-running service is a no-op
          // (that's the whole reason it reports "already started"), so
          // it can never fix a driver that's running but stuck in some
          // bad internal state — but an actual stop/start CYCLE of that
          // same service can, the same way toggling any stuck Windows
          // service sometimes clears whatever wedged it, and this
          // bridge already has precedent (the separate reset script
          // built earlier in this project) that stop-then-start is a
          // meaningfully different operation than start-alone for this
          // exact driver. Gated to once per session, not retried every
          // poll: a stop/start cycle briefly interrupts ring-0 access
          // for every process using PawnIO on the machine, not just
          // this one, so it's worth paying for once, not repeatedly,
          // when it either fixes things immediately or the real cause
          // is something this bridge can't fix by itself anyway (a
          // hypervisor, a driver genuinely incompatible with this
          // machine, ...).

          // Added 2026-09-12, reproduced live: this check sits ahead of
          // (and independent from) `_attemptedPawnIoRestartRecovery`
          // below on purpose. That flag is permanently true after its
          // first run this session, so a PawnIO that only becomes
          // confirmed-missing *as a result of* the recovery below (e.g.
          // its stop/start cycle happens to clear a stale, half-torn-down
          // registration, revealing on the very next read that PawnIO is
          // now genuinely gone) would otherwise just get logged and left
          // there — `autoProvisionSensorDependencies()` only ever checks
          // this once, right at app startup, so it can't catch a
          // mid-session change like this either. Reproduced live: sensors
          // stayed empty for the rest of that session until the user
          // happened to open a screen whose own init logic re-checked and
          // triggered the install — 8 minutes later in one captured log,
          // and potentially never, if that screen is never opened. This
          // installs silently the moment this method itself notices
          // PawnIO confirmed missing, from any path that leads here, and
          // is gated to once per session (`_attemptedAutoPawnIoInstall`)
          // for the same reason as the recovery below: no point retrying
          // every poll once it either fixes things or genuinely can't.
          if (pawnIoConfirmedMissing && !_attemptedAutoPawnIoInstall) {
            _attemptedAutoPawnIoInstall = true;
            AppLogger.instance.info(
              _logSource,
              'CPU-temperatuursensoren blijven leeg ondanks elevatie, en PawnIO is bevestigd afwezig op '
              'dit systeem — de stille installatie wordt nu automatisch gestart, zonder te wachten tot '
              'iemand zelf een scherm opent of een knop indrukt.',
            );
            final autoInstalled = await installPawnIo();
            if (autoInstalled) {
              // installPawnIo() already resets _initFuture/_status/caches
              // on success — recurse for a genuinely fresh read against
              // the just-installed driver.
              return readCpuSensors();
            }
            // installPawnIo() already logged the specific failure reason
            // itself — falls through to the rest of this method (the
            // recovery below, then the generic diagnostic further down)
            // exactly as if this check didn't exist.
          }

          if (!_attemptedPawnIoRestartRecovery) {
            _attemptedPawnIoRestartRecovery = true;

            // **Corrected 2026-09-12, reproduced live on two separate
            // machines**: this recovery originally always tried
            // `sc.exe stop PawnIO` unconditionally, on the assumption
            // that a stop/start cycle is always possible for a
            // service that's merely "running" rather than "stopped".
            // Wrong — PawnIO's driver registers itself as
            // NOT_STOPPABLE while running (visible right in `sc.exe
            // query`'s own output: "STATE : 4 RUNNING |
            // (NOT_STOPPABLE, NOT_PAUSABLE, IGNORES_SHUTDOWN)"), which
            // means Windows rejects the stop control code outright —
            // confirmed live: `sc.exe stop PawnIO` came back
            // "ControlService FAILED 1052: Het aangevraagde
            // besturingselement is niet geldig voor deze service" on
            // both machines this happened on. The old code didn't
            // check for this, so it logged a confident "PawnIO wordt
            // nu écht herstart" message and then silently did nothing
            // useful — the "restart" never actually restarted
            // anything, it just re-confirmed the same already-running
            // service and recursed into a read that was doomed to
            // come back exactly as empty as before. Checking for
            // NOT_STOPPABLE up front avoids that false confidence: a
            // driver that refuses to stop while running can only be
            // cleared by a reboot (nothing at the Win32 service layer
            // can force-unload it), so this now says that plainly
            // instead of pretending a fix was attempted.
            //
            // **Confirmed effective in practice, 2026-09-12**: the
            // matching offline procedure this class can't perform from
            // inside a running process (nothing here can force-unload a
            // NOT_STOPPABLE driver) is a full removal via
            // `reset_darktask_dependencies.ps1` followed by an actual
            // reboot, then relaunching DarkTask. Reproduced on both
            // machines this deadlock was found on: after the reboot,
            // `sc.exe query type= driver state= all` showed PawnIO
            // completely absent (not merely "deleted but still
            // resident"), DarkTask's own auto-provisioning silently
            // reinstalled it from scratch, and CPU temperature/power
            // worked immediately on the very first read — no manual
            // steps beyond the reboot itself. That also means this
            // whole NOT_STOPPABLE branch is narrower than it might look
            // at first glance: a genuinely first-time install on a
            // machine that has never had PawnIO before starts from a
            // stoppable, freshly-registered service (both confirming
            // logs show `STATE : 4 RUNNING | (STOPPABLE, ...)` right
            // after that fresh install), so an ordinary customer would
            // only hit this specific deadlock by already having a
            // leftover, half-torn-down PawnIO install on their machine
            // — e.g. from an earlier manual reset/testing cycle without
            // a reboot afterward — not from a normal first run of
            // DarkTask.
            //
            // **Superseded, same day**: the paragraph above concluded
            // "only a reboot fixes this" from two machines where a
            // reboot happened to be the thing that was tried — but a
            // reboot was never actually the mechanism. Proven on a
            // third machine: with PawnIO still NOT_STOPPABLE and
            // DarkTask's own reading still empty, a freshly launched
            // LibreHardwareMonitor.exe (and a separate tool, TMOG) read
            // real CPU temperature/power from that exact same driver at
            // that exact same moment, with no reboot at all. So the
            // driver was never actually stuck — this bridge's own
            // long-lived Computer/Hardware object was (built once per
            // PowerShellSession lifetime via `_initFuture ??=
            // _doInitialize()` and never rebuilt, unlike a standalone
            // tool that always starts with a fresh one). What actually
            // fixed things after a reboot was never the driver being
            // cleared — it was this process itself being restarted,
            // which forced a fresh Computer/Hardware object as a side
            // effect. Rebuilding just that object in-process (below)
            // reaches the same result directly, without needing the
            // driver, the service, or the machine touched at all.
            // Added 2026-09-12, reproduced live: on a machine where
            // PawnIO was never installed at all yet, this self-heal
            // used to still run the full stop + 750ms sleep + start
            // cycle below against a service that doesn't exist —
            // both calls simply fail with 1060 ("De opgegeven service
            // is geen geinstalleerde service"), so that 750ms sleep
            // bought nothing — right before WindowsSensorService's own
            // auto-install kicked in moments later anyway.
            // [pawnIoConfirmedMissing] already tells us this exact case
            // in advance (see its own doc comment for how), so it's
            // checked first and the doomed stop/start attempt — and
            // even the `sc.exe query PawnIO` call that would precede it
            // — is skipped entirely: there's nothing running to cycle.
            if (pawnIoConfirmedMissing) {
              AppLogger.instance.info(
                _logSource,
                'CPU-temperatuursensoren blijven leeg ondanks elevatie, maar PawnIO is nog helemaal '
                'niet geinstalleerd op dit systeem (sc.exe/serviceregister/bestandssweep zien er niets '
                'van) — een stop/start-cyclus wordt overgeslagen, want er draait niets om te '
                'herstarten. De automatische PawnIO-installatie regelt dit vanzelf, zonder verdere '
                'actie hier.',
              );
              // Deliberately falls through to the normal logging below
              // (no recursive retry, no early return) — same reasoning
              // as the NOT_STOPPABLE branch just below: nothing was
              // actually changed here, so retrying the same read would
              // just reconfirm the same empty result.
            } else {
              final stopCheckResult = await _shell.run(
                r"(Invoke-ScOem query PawnIO | Out-String).Trim() -replace '\s+', ' '",
              );
              final notStoppable = stopCheckResult?.contains('NOT_STOPPABLE') ?? false;

              if (notStoppable) {
              AppLogger.instance.info(
                _logSource,
                'CPU-temperatuursensoren blijven leeg ondanks elevatie, en de PawnIO-service draait al — '
                'deze driver staat geregistreerd als NOT_STOPPABLE zolang hij draait '
                '(${stopCheckResult?.trim()}), dus een stop/start-cyclus van de service zelf is hier '
                'onmogelijk (Windows weigert het stop-commando). Dat is echter geen teken dat de driver '
                'zelf vastloopt — het betekent alleen dat DarkTask zijn eigen, al eerder binnen dit '
                'proces aangemaakte Computer/Hardware-object niet via een servicecyclus kan vervangen. In '
                'plaats daarvan wordt dat object nu rechtstreeks opnieuw aangemaakt (zoals een losse tool '
                'als LibreHardwareMonitor.exe of TMOG dat vanzelf ook doet bij elke start) en wordt meteen '
                'opnieuw gelezen, zonder dat de PawnIO-service of de computer zelf hoeft te worden '
                'aangeraakt.',
              );

              // Corrected 2026-09-12, reproduced live: this branch used
              // to log a message telling the user to reboot the whole
              // computer, and then permanently give up for the rest of
              // the session — on the (now falsified, see the paragraph
              // above) assumption that a NOT_STOPPABLE driver can only
              // be un-stuck by a reboot. With the driver itself proven
              // healthy in that same test (a standalone
              // LibreHardwareMonitor.exe/TMOG read real values from it,
              // no reboot involved), the actual fix doesn't need the
              // service touched at all — only this bridge's own
              // Computer/Hardware object needs rebuilding, exactly like
              // the successful-restart branch just below already does
              // after a stop/start cycle.
              //
              // **Superseded again, 2026-09-14**: the rebuild above is
              // still correct and worth doing (it's free, and it does
              // fix the exact "stale pre-driver object" case it was
              // built for) — but it is not a universal fix. Reproduced
              // live on two separate machines (an i7-6820HQ and the
              // i5-1135G7 discussed at length in `_doInitialize`'s own
              // driver-diagnostic comments) where the rebuild ran, then
              // the very next read — immediately, not after any delay —
              // came back just as empty as before. On a machine where
              // the driver itself is the thing refusing real MSR reads
              // (leading theory: Virtualization-Based Security/Memory
              // Integrity silently blocking RDMSR underneath an
              // otherwise-healthy, RUNNING PawnIO — see the new
              // `vbs:`/HVCI registry check added to `_doInitialize`'s
              // diagnostics), a brand-new Computer object talking to
              // that same still-blocked driver has nothing to gain from
              // being new. This branch has no way to fix that from
              // inside the process — VBS/Memory Integrity is a boot-time
              // Windows setting (Windows Security -> Device security ->
              // Core isolation), not something a service cycle or
              // object rebuild can touch — so this only ever gets one
              // rebuild attempt per session, same as before, and the
              // person is left with the diagnostic log rather than a
              // false "fixed" message. If the next capture from an
              // affected machine confirms VBS/HVCI is actually on, the
              // right next step is telling that person specifically to
              // turn Memory Integrity off (Windows, not DarkTask, asks
              // for a reboot to apply that) rather than continuing to
              // chase this as an in-process bug.
              _initFuture = null;
              _status = LhmStatus.notChecked;
              _driverDiagFindings = const [];
              _cpuSensorDiagnosticLogged = false;
              _gpuSensorDiagnosticLogged = false;
              cpuPowerStuckAtZero = false;
              _consecutiveZeroPowerWithRealTemp = 0;
              // Cache would otherwise short-circuit the recursive call
              // below straight back to this same empty result.
              _cpuSensorCache = null;
              _cpuSensorCacheTime = null;

              // Recurses into this same method for a genuinely fresh
              // read against a brand-new Computer/Hardware object,
              // without ever touching the (already fine) PawnIO
              // service. Safe from infinite recursion:
              // `_attemptedPawnIoRestartRecovery` is already true by
              // this point, so if this retry still comes back empty,
              // the recursive call takes the normal logging/diagnostic
              // path below instead of trying again.
              return readCpuSensors();
            } else {
              AppLogger.instance.info(
                _logSource,
                'CPU-temperatuursensoren blijven leeg ondanks elevatie — eenmalige herstelpoging: de '
                'PawnIO-service wordt nu écht herstart (stop, dan pas weer start — een kale start doet '
                'niets bij een service die al draait) en de sensoren worden daarna vanaf nul opnieuw '
                'geïnitialiseerd.',
              );
              final restartScript = r"try { "
                  r"$stopOut = (Invoke-ScOem stop PawnIO | Out-String).Trim() -replace '\s+', ' '; "
                  r"Start-Sleep -Milliseconds 750; "
                  r"$startOut = (Invoke-ScOem start PawnIO | Out-String).Trim() -replace '\s+', ' '; "
                  r"Write-Output ('DARKTASK_PAWNIO_RESTART stop=[' + $stopOut + '] start=[' + $startOut + ']') "
                  r"} catch { Write-Output ('DARKTASK_PAWNIO_RESTART_ERROR: ' + $_.Exception.Message) }";
              final restartResult = await _shell.run(restartScript);
              AppLogger.instance.info(
                _logSource,
                'PawnIO-herstart resultaat: ${restartResult?.trim().isEmpty ?? true ? '(geen output)' : restartResult!.trim()}',
              );

              // Same reset as after a successful installPawnIo() — nothing
              // about the old Computer/Hardware object is trustworthy once
              // the driver underneath it has just been cycled.
              _initFuture = null;
              _status = LhmStatus.notChecked;
              _driverDiagFindings = const [];
              _cpuSensorDiagnosticLogged = false;
              _gpuSensorDiagnosticLogged = false;
              cpuPowerStuckAtZero = false;
              _consecutiveZeroPowerWithRealTemp = 0;
              // Cache would otherwise short-circuit the recursive call
              // below straight back to this same empty result.
              _cpuSensorCache = null;
              _cpuSensorCacheTime = null;

              // Recurses into this same method for a genuinely fresh
              // read against the just-restarted driver. Safe from
              // infinite recursion: `_attemptedPawnIoRestartRecovery` is
              // already true by this point, so if this retry still comes
              // back empty, the recursive call takes the normal
              // logging/diagnostic path below instead of trying again.
              return readCpuSensors();
            }
            }
          }
          if (!msrBlockedByVbs) {
            // Softened from an earlier version of this message that
            // named Geheugenintegriteit/VBS as "waarschijnlijkste
            // oorzaak" unconditionally — reproduced and confirmed wrong
            // on at least one real machine hitting this exact symptom
            // (`Win32_DeviceGuard.VirtualizationBasedSecurityStatus`
            // read back 0, i.e. VBS genuinely off, while this pattern
            // still occurred). VBS/Kernisolatie remains A plausible
            // cause on other machines, just no longer asserted as THE
            // most likely one here — see _logCpuRing0DiagnosticReport
            // below for the actual, machine-specific diagnostic this
            // now pulls in automatically instead of guessing.
            AppLogger.instance.info(
              _logSource,
              'CPU-temperatuursensoren zijn bekend bij LibreHardwareMonitor ($tempTotal gevonden) maar geven '
              'allemaal een lege waarde — terwijl dit proces al verhoogd (als Administrator) draait, dus dat '
              'is hier niet de ontbrekende schakel. Mogelijke oorzaken op een modern Windows 11-systeem: '
              'Geheugenintegriteit/Kernisolatie (Virtualization-Based Security, door veel fabrikanten '
              'standaard aan), een virtuele machine/hypervisor met dezelfde beperking, of de PawnIO-driver '
              '(die LibreHardwareMonitor sinds v0.9.4 gebruikt voor MSR-toegang) die nooit is '
              'geïnstalleerd/gestart. Zie de losse GetReport()-dump hieronder voor de daadwerkelijke, '
              'machine-specifieke reden in plaats van dit lijstje met mogelijkheden.',
            );
          }
          msrBlockedByVbs = true;
          if (!_loggedCpuRing0DiagnosticReport) {
            _loggedCpuRing0DiagnosticReport = true;
            await _logCpuRing0DiagnosticReport();
          }
        } else {
          if (!needsElevation) {
            AppLogger.instance.info(
              _logSource,
              'CPU-temperatuursensoren zijn bekend bij LibreHardwareMonitor ($tempTotal gevonden) maar geven '
              'allemaal een lege waarde — dit specifieke patroon wijst op onvoldoende rechten voor de '
              'laagniveau MSR-toegang die deze meting nodig heeft. Probeer DarkTask als Administrator te '
              'starten.',
            );
          }
          needsElevation = true;
        }
      } else if (tempWithValue > 0) {
        // A real reading came through — whatever caused an earlier
        // empty read (cold-start race, or a genuine VBS/elevation
        // block that's since been resolved, e.g. the person disabled
        // Memory Integrity and rebooted mid-session) is no longer
        // happening, so the warning banner should stop showing it as
        // an active problem.
        if (msrBlockedByVbs || needsElevation) {
          AppLogger.instance.info(
            _logSource,
            'CPU-temperatuursensoren geven nu weer een waarde ($tempWithValue/$tempTotal) — eerdere '
            'blokkade-melding (elevatie/VBS) vervalt.',
          );
        }
        msrBlockedByVbs = false;
        needsElevation = false;
      }

      final powerWatts = (decoded['powerW'] as num?)?.toDouble();

      // See [cpuPowerStuckAtZero]'s doc for the full reasoning. Only
      // counts as evidence when temperature proves MSR access itself
      // is working right now (tempWithValue > 0) — a zero power
      // reading while temperature is ALSO blocked is just the
      // already-covered msrBlockedByVbs/needsElevation case above,
      // not this narrower one.
      if (tempWithValue > 0 && powerWatts == 0.0) {
        _consecutiveZeroPowerWithRealTemp++;
        if (_consecutiveZeroPowerWithRealTemp >= 5 && !cpuPowerStuckAtZero) {
          cpuPowerStuckAtZero = true;
          AppLogger.instance.info(
            _logSource,
            'CPU-temperatuur werkt (MSR-toegang is dus actief), maar CPU-vermogen ("CPU Package", RAPL) '
            'blijft al $_consecutiveZeroPowerWithRealTemp metingen op rij letterlijk 0,0 W — een ander, '
            'specifieker patroon dan de eerdere temperatuurblokkade hierboven. LibreHardwareMonitor geeft '
            'deze sensor een expliciete 0,0-startwaarde (in plaats van leeg, zoals temperatuur) totdat er '
            'een echte energie-delta berekend is, dus dit is niet zomaar dezelfde "sensor onbekend"-melding. '
            'Mogelijke oorzaken: dit specifieke CPU-model/-stepping heeft geen RAPL-ondersteuning in deze '
            'versie van LibreHardwareMonitor, of de energie-MSR die hiervoor nodig is wordt (anders dan de '
            'temperatuur-MSR) toch nog geblokkeerd. Geen kant-en-klare fix hiervoor op basis van dit alleen — '
            'een verse GetReport()-dump zou moeten uitwijzen welke van de twee het is.',
          );
        }
      } else if (powerWatts != null && powerWatts > 0.0) {
        if (cpuPowerStuckAtZero) {
          AppLogger.instance.info(
            _logSource,
            'CPU-vermogen geeft nu een echte waarde (${powerWatts.toStringAsFixed(1)} W) — eerdere '
            '"blijft op 0,0 W steken"-melding vervalt.',
          );
        }
        cpuPowerStuckAtZero = false;
        _consecutiveZeroPowerWithRealTemp = 0;
      }

      final parsed = {
        'temperatureC': (decoded['tempC'] as num?)?.toDouble(),
        'powerWatts': powerWatts,
        'fanRpm': (decoded['fanRpm'] as num?)?.toDouble(),
      };
      _cpuSensorCache = parsed;
      _cpuSensorCacheTime = DateTime.now();
      return parsed;
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to parse LHM CPU sensor JSON: $e\nOutput was: $trimmed');
      return null;
    }
  }

  bool _gpuSensorDiagnosticLogged = false;
  bool _cpuSensorDiagnosticLogged = false;
  bool _loggedCpuRing0DiagnosticReport = false;
  bool _attemptedPawnIoRestartRecovery = false;

  /// Added 2026-09-12, reproduced live: `autoProvisionSensorDependencies()`
  /// only calls `installPawnIo()` once, right at app startup, based on
  /// whatever `pawnIoConfirmedMissing` says at that single moment. That
  /// misses a real, reproduced sequence: PawnIO can still look present
  /// (a stale, half-torn-down registration) at startup, only for the
  /// self-heal below to discover — after its own stop/start cycle — that
  /// it's now genuinely gone. `_attemptedPawnIoRestartRecovery` being
  /// permanently true by then means that discovery used to just get
  /// logged and left there: sensors stayed empty until someone happened
  /// to open a screen whose own init logic re-checked and triggered the
  /// install — 8 minutes later in one captured log, and never at all if
  /// that screen is never opened. This flag instead gates a check placed
  /// ahead of/independent from `_attemptedPawnIoRestartRecovery` (see
  /// below) so a confirmed-missing PawnIO gets silently (re)installed the
  /// moment `readCpuSensors()` itself notices it, from any path that
  /// leads here, without waiting on a particular screen or button.
  bool _attemptedAutoPawnIoInstall = false;

  /// One-time deep diagnostic, fired the first time CPU temperature
  /// sensors are known but all empty on an already-elevated process
  /// (see the call site above). The generic VBS/Kernisolatie/PawnIO
  /// message right before this is an educated *guess* among several
  /// possibilities — reproduced and confirmed wrong for VBS
  /// specifically on at least one real machine hitting this exact
  /// symptom, so it's no longer trustworthy on its own.
  /// `Computer.GetReport()` is LibreHardwareMonitorLib's own built-in
  /// diagnostic dump — the same one its GUI app's Help ▸ Save Report
  /// menu item produces for bug reports — and surfaces internal detail
  /// (Ring0/PawnIO initialization outcome, specific exceptions) that
  /// never reaches this bridge's own sensor JSON, which only ever sees
  /// "sensor exists, Value is null" with no explanation attached.
  ///
  /// **Fixed 2026-09-10**: this used to log *either* keyword-matched
  /// lines *or* a raw fallback dump, never both — on a real machine,
  /// "Estimated Time Stamp Counter Frequency Error: ..." (a completely
  /// benign calibration line, not a failure) matched the `error`
  /// keyword by pure substring luck, which counted as "found something"
  /// and suppressed the raw fallback entirely. That one false positive
  /// was the *only* thing that got logged, out of a 526-line report —
  /// worse than logging nothing, since it looked like a real (if
  /// useless) answer instead of an obvious miss. Now: keyword-matched
  /// lines (if any) are logged as a bonus signal, but a raw excerpt is
  /// **always** also logged — specifically a window around wherever the
  /// report's own CPU temperature-sensor listing is (recognizable by
  /// name — "TjMax", "CPU Package" — since [readCpuSensors]'s own dump
  /// already confirmed those names exist), falling back to a plain
  /// bounded prefix if that anchor text isn't found either. A keyword
  /// match can no longer hide the real content.
  Future<void> _logCpuRing0DiagnosticReport() async {
    try {
      final result = await _shell.run(r"$global:__darktaskLhm.GetReport()");
      if (result == null || result.trim().isEmpty) {
        AppLogger.instance.info(
          _logSource,
          'Computer.GetReport() leverde geen output op — kon geen diepere Ring0/PawnIO-diagnose ophalen voor '
          'de lege CPU-temperatuursensoren hierboven.',
        );
        return;
      }

      final lines = result.split('\n');
      AppLogger.instance.info(
        _logSource,
        'Computer.GetReport() opgehaald (${lines.length} regels, ${result.length} tekens totaal).',
      );

      const keywords = [
        'ring0', 'pawnio', 'exception', 'driver', 'msr', 'failed',
        'toegang geweigerd', 'access denied', 'unable', 'not found', 'could not',
        // 'error' deliberately excluded — see this method's doc comment
        // for why a bare "error" substring match caused this whole
        // diagnostic to backfire on real hardware.
      ];
      final relevant = lines.where((l) {
        final lower = l.toLowerCase();
        return keywords.any(lower.contains);
      }).map((l) => l.trim()).toList();
      if (relevant.isNotEmpty) {
        AppLogger.instance.info(
          _logSource,
          'Computer.GetReport() — regels die Ring0/PawnIO/driver/foutmeldingen noemen (${relevant.length} van '
          '${lines.length} totaal): ${relevant.join(' | ')}',
        );
      }

      // Always also log a window around the CPU sensor section —
      // unconditional, precisely so the line above (or the absence of
      // any match) never determines whether this happens.
      final anchorIndex = lines.indexWhere((l) {
        final lower = l.toLowerCase();
        return lower.contains('tjmax') || lower.contains('cpu package') || lower.contains('genericcpu') || lower.contains('intelcpu');
      });
      if (anchorIndex != -1) {
        final start = (anchorIndex - 60).clamp(0, lines.length);
        final end = (anchorIndex + 120).clamp(0, lines.length);
        AppLogger.instance.info(
          _logSource,
          'Computer.GetReport() — venster rond de CPU-temperatuursectie (regels $start-$end van ${lines.length}): '
          '${lines.sublist(start, end).join('\n')}',
        );
      } else {
        const maxChars = 5000;
        final capped = result.length > maxChars ? '${result.substring(0, maxChars)}... (afgekapt op $maxChars tekens)' : result;
        AppLogger.instance.info(
          _logSource,
          'Computer.GetReport() — CPU-temperatuursectie niet gevonden via herkenningstekst (TjMax/CPU Package/'
          'GenericCpu/IntelCpu); ruwe dump in plaats daarvan: $capped',
        );
      }
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Kon Computer.GetReport() niet ophalen voor diepere diagnose: $e');
    }
  }

  /// Returns one entry per AMD/Intel GPU LibreHardwareMonitor detects,
  /// each `{'name', 'hardwareType', 'loadPercent', 'temperatureC'}`.
  /// NVIDIA is deliberately excluded here — nvidia-smi already covers
  /// it (see WindowsSensorService), and querying the same physical card
  /// through two different libraries risks conflicting numbers for no
  /// benefit.
  Future<List<Map<String, dynamic>>> readGpuSensors() async {
    if (!await _ensureInitialized()) return [];

    // Sensor naming for "the main load/temperature reading" isn't as
    // consistent across GPU generations as it is for CPUs — AMD/newer
    // Intel Xe parts commonly expose a sensor literally named "GPU
    // Core", but older Intel iGPUs (pre-Xe, e.g. HD/UHD Graphics) have
    // historically had thinner LibreHardwareMonitor support and may
    // use a different name entirely, or expose no Load/Temperature
    // sensor at all for that hardware. Rather than hard-require
    // "*Core*" and silently return null either way, this prefers a
    // "*Core*"-named sensor when one exists but falls back to whatever
    // Load/Temperature sensor the hardware does expose — a real
    // reading under an unexpected name beats no reading at all.
    final script = r"$results = @(); "
        r"foreach ($hw in $global:__darktaskLhm.Hardware) { "
        r"  if ($hw.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::GpuAmd -or "
        r"      $hw.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::GpuIntel) { "
        r"    $hw.Update(); "
        r"    $entry = @{ name = $hw.Name; hardwareType = $hw.HardwareType.ToString(); load = $null; tempC = $null; powerW = $null; clockMHz = $null; fanRpm = $null; sensors = @() }; "
        r"    $loadSensors = @($hw.Sensors | Where-Object { $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Load -and $null -ne $_.Value }); "
        r"    $tempSensors = @($hw.Sensors | Where-Object { $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and $null -ne $_.Value }); "
        r"    $powerSensors = @($hw.Sensors | Where-Object { $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Power -and $null -ne $_.Value }); "
        r"    $clockSensors = @($hw.Sensors | Where-Object { $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Clock -and $null -ne $_.Value }); "
        r"    $fanSensors = @($hw.Sensors | Where-Object { $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Fan -and $null -ne $_.Value }); "
        r"    $loadPick = $loadSensors | Where-Object { $_.Name -like '*Core*' } | Select-Object -First 1; "
        r"    if (-not $loadPick) { $loadPick = $loadSensors | Select-Object -First 1 } "
        r"    if ($loadPick) { $entry.load = [double]$loadPick.Value } "
        r"    $tempPick = $tempSensors | Where-Object { $_.Name -like '*Core*' } | Select-Object -First 1; "
        r"    if (-not $tempPick) { $tempPick = $tempSensors | Select-Object -First 1 } "
        r"    if ($tempPick) { $entry.tempC = [double]$tempPick.Value } "
        r"    $powerPick = $powerSensors | Where-Object { $_.Name -like '*Core*' } | Select-Object -First 1; "
        r"    if (-not $powerPick) { $powerPick = $powerSensors | Select-Object -First 1 } "
        r"    if ($powerPick) { $entry.powerW = [double]$powerPick.Value } "
        r"    $clockPick = $clockSensors | Where-Object { $_.Name -like '*Core*' } | Select-Object -First 1; "
        r"    if (-not $clockPick) { $clockPick = $clockSensors | Select-Object -First 1 } "
        r"    if ($clockPick) { $entry.clockMHz = [double]$clockPick.Value } "
        // Unlike Load/Temperature/Clock above, fan sensors have no
        // "*Core*"-named variant to prefer — a GPU exposes at most one
        // or two Fan sensors (sometimes none at all on a passively-
        // cooled or blower-less card), so the first one with a value
        // is simply the fan speed, no picking-the-right-one-among-many
        // needed.
        r"    $fanPick = $fanSensors | Select-Object -First 1; "
        r"    if ($fanPick) { $entry.fanRpm = [double]$fanPick.Value } "
        r"    foreach ($s in $hw.Sensors) { $entry.sensors += ($s.Name + ' [' + $s.SensorType + ']=' + $s.Value) } "
        r"    $results += [PSCustomObject]$entry; "
        r"  } "
        r"}; "
        r"$results | ConvertTo-Json -Compress";

    final result = await _shell.run(script);
    if (result == null) return [];
    final trimmed = result.trim();
    if (trimmed.isEmpty) return [];
    try {
      final decoded = jsonDecode(trimmed);
      final rows = decoded is List ? decoded : [decoded];

      // One-time raw dump of every sensor LibreHardwareMonitor actually
      // exposes for each detected AMD/Intel GPU — the only way to tell,
      // for hardware this bridge hasn't been tested against, whether
      // "no reading" means "no sensor exists at all" or "exists under
      // a name this bridge doesn't recognize yet".
      if (!_gpuSensorDiagnosticLogged) {
        _gpuSensorDiagnosticLogged = true;
        for (final row in rows) {
          final map = row as Map<String, dynamic>;
          final sensorList = (map['sensors'] as List?)?.join(', ') ?? '(geen sensoren)';
          AppLogger.instance.info(
            _logSource,
            'LHM-sensordump voor "${map['name']}" (${map['hardwareType']}): $sensorList',
          );
        }
      }

      return rows.map<Map<String, dynamic>>((r) {
        final row = r as Map<String, dynamic>;
        return {
          'name': row['name'] as String?,
          'hardwareType': row['hardwareType'] as String?,
          'loadPercent': (row['load'] as num?)?.toDouble(),
          'temperatureC': (row['tempC'] as num?)?.toDouble(),
          'powerWatts': (row['powerW'] as num?)?.toDouble(),
          'clockMHz': (row['clockMHz'] as num?)?.toDouble(),
          'fanRpm': (row['fanRpm'] as num?)?.toDouble(),
        };
      }).toList();
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to parse LHM GPU sensor JSON: $e\nOutput was: $trimmed');
      return [];
    }
  }

  /// Per-core current clock speed, in MHz, ordered by core index — for
  /// the Power & Freq screen's Windows equivalent of Linux's
  /// `scaling_cur_freq` per-core files. A separate query from
  /// [readCpuSensors] (which is cached with a much shorter TTL tuned
  /// for high-frequency polling) since this screen doesn't poll nearly
  /// as often and doesn't need that cache's tighter freshness window.
  Future<List<double?>> readPerCoreClocksMHz() async {
    if (!await _ensureInitialized()) return [];

    final script = r"$clocks = @{}; "
        r"foreach ($hw in $global:__darktaskLhm.Hardware) { "
        r"  if ($hw.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::Cpu) { "
        r"    $hw.Update(); "
        r"    foreach ($s in $hw.Sensors) { "
        r"      if ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Clock -and $s.Name -match 'Core #(\d+)' -and $null -ne $s.Value) { "
        r"        $clocks[$matches[1]] = [double]$s.Value "
        r"      } "
        r"    } "
        r"  } "
        r"}; "
        r"$clocks | ConvertTo-Json -Compress";

    final result = await _shell.run(script);
    if (result == null) return [];
    final trimmed = result.trim();
    if (trimmed.isEmpty) return [];
    try {
      final decoded = jsonDecode(trimmed) as Map<String, dynamic>;
      if (decoded.isEmpty) return [];
      // Keys are 1-based core numbers as strings ("1", "2", ...) —
      // sorted numerically and returned as a plain 0-indexed list to
      // match how the Linux side already orders perCoreFrequencyMHz.
      final coreNumbers = decoded.keys.map(int.parse).toList()..sort();
      return coreNumbers.map((n) => (decoded[n.toString()] as num?)?.toDouble()).toList();
    } catch (e) {
      AppLogger.instance.debug(_logSource, 'Failed to parse LHM per-core clock JSON: $e\nOutput was: $trimmed');
      return [];
    }
  }
}
