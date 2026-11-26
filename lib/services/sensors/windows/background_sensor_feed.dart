import 'dart:convert';
import 'dart:io';

import '../../../core/logging/app_logger.dart';

const _logSource = 'BackgroundSensorFeed';

/// A persistent, once-elevated background reader for CPU/GPU
/// temperature and power — the architectural alternative to
/// per-launch elevation, modeled on how tools like TMOG appear to
/// avoid a UAC prompt on every single start (see the investigation
/// this class came out of: TMOG showed real sensor values with no UAC
/// prompt at launch, which is only possible if the elevated piece was
/// already running persistently from an earlier, one-time setup —
/// not re-elevated fresh every launch the way this app's own
/// [LibreHardwareMonitorBridge] does today).
///
/// **Design, and why this shape specifically:**
///
/// A genuine Windows Service (SCM-integrated, its own signed binary)
/// is the "proper" way to do this, but building and code-signing a
/// real service binary is a substantial new build-and-release
/// pipeline this project doesn't have — a bigger, riskier
/// undertaking than the actual problem calls for. **Windows Task
/// Scheduler with "run with highest privileges" achieves the same
/// practical outcome without it**: a task created with that flag,
/// triggered "at log on," runs elevated automatically on every future
/// login with no UAC prompt at trigger time — the UAC prompt happens
/// once, at task *creation*, not at every run. This reuses
/// infrastructure Windows already has, rather than adding a new kind
/// of artifact to build and maintain.
///
/// **IPC via a plain local JSON file, not named pipes.** The
/// background task writes readings to a file once a second; this app
/// just reads that file. No pipe protocol to get right, no client/
/// server handshake — the same category of risk as everything else in
/// this app's file-based work, not a new one. The trade-off is up to
/// ~1 second of staleness, which is irrelevant for a temperature
/// reading.
///
/// **Never the only path.** If the background task isn't set up, or
/// its feed file goes stale (the task stopped, crashed, or was
/// removed), every read here returns null and callers fall back to
/// the existing per-launch [LibreHardwareMonitorBridge] path — this
/// is purely an optional upgrade layered on top of what already
/// works, never a replacement that could leave temperature reading
/// broken if this specific mechanism has a problem.
class BackgroundSensorFeed {
  static const _taskName = 'DarkTaskSensorService';
  static const _scriptFileName = 'sensor_service.ps1';
  static const _feedFileName = 'sensor_feed.json';

  // A reading older than this is treated as "the background task
  // isn't actually running" rather than trusted as current. Originally
  // 5 seconds (comfortably more than the task's own 1-second write
  // interval for normal scheduling jitter) — widened to 12s after
  // testing showed the "alles tegelijk" combined stress test's own
  // disk benchmark can itself saturate disk I/O enough to delay the
  // background task's file write meaningfully, since that write lands
  // on the same disk being benchmarked. A wider window means a
  // temporarily-delayed-but-still-alive background task keeps being
  // trusted through that contention instead of being declared stale
  // and falling back to the slower PowerShell path, which needs its
  // own disk access (spawning processes, loading assemblies) and so
  // suffers from the exact same contention rather than escaping it.
  static const _freshnessWindow = Duration(seconds: 12);

  String? _dataDir;
  String? _dataDirCached() {
    if (_dataDir != null) return _dataDir;
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null) return null;
    _dataDir = '$localAppData\\DarkTask';
    return _dataDir;
  }

  /// Reads the feed file if present and fresh. Returns
  /// `{'cpuTempC': double?, 'cpuPowerW': double?, 'gpus': [{'name':
  /// String, 'tempC': double?, 'loadPercent': double?}, ...]}`, or null
  /// if the background task
  /// isn't running, hasn't produced a fresh reading yet, or the file
  /// is missing/malformed — any of which should be treated as "use the
  /// other path," never as an error to surface.
  Future<Map<String, dynamic>?> readFeed() async {
    final dir = _dataDirCached();
    if (dir == null) return null;

    try {
      final file = File('$dir\\$_feedFileName');
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      if (content.trim().isEmpty) return null;

      final decoded = jsonDecode(content) as Map<String, dynamic>;
      final timestampMs = decoded['timestamp'] as int?;
      if (timestampMs == null) return null;

      final age = DateTime.now().toUtc().difference(DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true));
      if (age > _freshnessWindow || age.isNegative) return null;

      return decoded;
    } catch (e) {
      // Malformed/partially-written JSON is expected occasionally —
      // the background task overwrites this file every second, and a
      // read can land mid-write. Treated as "no fresh reading this
      // time," not logged as an error; the next read a second later
      // will very likely succeed.
      AppLogger.instance.debug(_logSource, 'Feed read failed (likely a benign mid-write race): $e');
      return null;
    }
  }

  /// Checks (without registering anything) whether the background
  /// task appears to be set up and actively producing fresh readings —
  /// used by the UI to decide whether to offer the one-time setup
  /// button at all.
  Future<bool> isActive() async => (await readFeed()) != null;

  /// One-time setup: writes the background script, then requests a
  /// single elevated PowerShell call to register it as a Task
  /// Scheduler task (the one UAC prompt this whole approach needs,
  /// ever — not per launch) and start it immediately for this
  /// session. Returns null on success, or a human-readable error
  /// message on failure (declined UAC prompt, registration failure,
  /// etc.) so the UI can show it rather than silently doing nothing.
  Future<String?> setupBackgroundService({String? fallbackDllPath}) async {
    final dir = _dataDirCached();
    if (dir == null) return 'Kon LOCALAPPDATA niet bepalen.';

    try {
      final dirHandle = Directory(dir);
      if (!await dirHandle.exists()) await dirHandle.create(recursive: true);

      final scriptPath = '$dir\\$_scriptFileName';
      final dllPath = '$dir\\LibreHardwareMonitorLib.dll';
      final feedPath = '$dir\\$_feedFileName';

      if (!await File(dllPath).exists()) {
        // The background task runs standalone, at logon, with no
        // relation to wherever DarkTask's own .exe happens to live —
        // it needs one stable, guaranteed-persistent DLL path to
        // Add-Type against, so this specifically requires its own copy
        // here rather than trusting the main app's (more flexible,
        // three-candidate) search. That copy is genuinely missing on a
        // fresh machine where `installIntelGpuTools()` never ran, but
        // it's *also* "missing" here on every normal install where the
        // DLL simply ships bundled next to the .exe instead (the
        // default since LibreHardwareMonitorBridge's own doc comment)
        // — the main app already has a perfectly good, working DLL in
        // that case, just not at this one specific path. Rather than
        // failing with a confusing "not downloaded yet" message while
        // CPU/GPU sensors are visibly already working, self-heal by
        // copying whatever DLL the caller's own bridge actually loaded
        // (passed in as [fallbackDllPath]) into place first.
        if (fallbackDllPath != null && await File(fallbackDllPath).exists()) {
          await File(fallbackDllPath).copy(dllPath);
          AppLogger.instance.info(
            _logSource,
            'LibreHardwareMonitorLib.dll gekopieerd van $fallbackDllPath naar $dllPath voor de '
            'achtergronddienst (die zijn eigen, stabiele kopie nodig heeft, los van waar de hoofd-app '
            'de zijne vond).',
          );
        }
        if (!await File(dllPath).exists()) {
          return 'LibreHardwareMonitorLib.dll is nog niet gedownload — open eerst het CPU- of '
              'GPU-detailpaneel zodat de app die eerst kan ophalen, en probeer het daarna opnieuw.';
        }
      }

      await File(scriptPath).writeAsString(_buildServiceScript(dllPath: dllPath, feedPath: feedPath));

      // Everything from here runs inside ONE elevated PowerShell
      // process, spawned the same way WindowsSensorService.restartElevated
      // already does — Start-Process -Verb RunAs is what actually
      // triggers the (single, one-time) UAC prompt.
      final scriptPathEscaped = scriptPath.replaceAll("'", "''");
      final registerScript = '''
try {
  \$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-ExecutionPolicy Bypass -WindowStyle Hidden -NoProfile -File "$scriptPathEscaped"'
  \$trigger = New-ScheduledTaskTrigger -AtLogOn
  \$principal = New-ScheduledTaskPrincipal -UserId "\$env:USERNAME" -RunLevel Highest
  \$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
  Register-ScheduledTask -TaskName '$_taskName' -Action \$action -Trigger \$trigger -Principal \$principal -Settings \$settings -Force | Out-Null

  # Stop any instance that's already running BEFORE starting a new
  # one — this is the step a plain re-registration is missing. The
  # background script is an infinite loop that only ever reads the
  # script file's content once, at its own startup; Register-
  # ScheduledTask -Force only replaces the task's stored *definition*,
  # it does not touch a copy already running from an earlier setup.
  # And Task Scheduler's default "IgnoreNew" multiple-instances policy
  # means Start-ScheduledTask below would then silently do nothing at
  # all while an old instance is still alive — this setup call would
  # report success (registration genuinely succeeded) while the
  # process actually serving sensor_feed.json keeps running the stale
  # script forever. Explicitly stopping first guarantees the instance
  # Start-ScheduledTask launches next is a fresh one running whatever
  # was just written to disk above.
  Stop-ScheduledTask -TaskName '$_taskName' -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 750
  Start-ScheduledTask -TaskName '$_taskName'
  Write-Output 'DARKTASK_SETUP_OK'
} catch {
  Write-Output ('DARKTASK_SETUP_ERROR: ' + \$_.Exception.Message)
}
''';
      final tempScriptPath = '$dir\\_setup_temp.ps1';
      await File(tempScriptPath).writeAsString(registerScript);
      final tempScriptPathEscaped = tempScriptPath.replaceAll("'", "''");

      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "try { \$p = Start-Process -FilePath 'powershell.exe' "
            "-ArgumentList '-ExecutionPolicy Bypass -NoProfile -File \"$tempScriptPathEscaped\"' "
            "-Verb RunAs -Wait -PassThru -WindowStyle Hidden; "
            "Write-Output 'DARKTASK_ELEVATE_OK' } catch { Write-Output ('DARKTASK_ELEVATE_ERROR: ' + \$_.Exception.Message) }",
      ]);

      // Best-effort cleanup of the temp registration script — not
      // critical if this fails, so no error handling beyond "don't
      // crash the setup over a leftover temp file."
      try {
        await File(tempScriptPath).delete();
      } catch (_) {}

      final output = '${result.stdout}\n${result.stderr}';
      if (!output.contains('DARKTASK_ELEVATE_OK')) {
        final errorMatch = RegExp(r'DARKTASK_ELEVATE_ERROR:\s*(.+)').firstMatch(output);
        return 'Verhoging geweigerd of mislukt: ${errorMatch?.group(1)?.trim() ?? output.trim()}';
      }

      // Give the newly-started task a moment to produce its first
      // reading before the caller checks isActive()/readFeed() —
      // Add-Type + Computer.Open() inside the background script takes
      // a few seconds the first time, same startup cost this app
      // already sees for its own per-launch LHM init.
      //
      // **Widened from a single flat 5-second sleep to a poll loop,
      // 2026-09-11**, reproduced live on a real (i7-6700) machine: the
      // flat 5-second wait reported failure ("geregistreerd, maar
      // geeft nog geen data") even though the task genuinely was
      // still starting up — a manual re-check moments later (a fresh
      // app launch, which only needs isActive()/readFeed(), not this
      // whole setup dance again) found it already working fine. On
      // that machine this task's own cold PowerShell process has to
      // load the ~1.2MB LibreHardwareMonitorLib assembly, call
      // Computer.Open() (which probes all twelve bundled PawnIO
      // modules — AMD/Intel MSR, SMBus, LPC/EC — even though only one
      // is relevant for this CPU), AND compete for CPU/disk with every
      // other thing this app itself is doing during its own
      // simultaneous cold start — comfortably enough to blow past 5
      // seconds on a slower or busier machine without anything being
      // actually broken. Polling every 1.5s up to a much longer total
      // budget costs nothing in the common case (returns the moment
      // real data shows up, often well under 5s) and gives a
      // genuinely slow first run the room the flat sleep didn't.
      // **Widened again, 2026-09-13**, reproduced live on the same
      // (i7-6700) machine this poll loop was already built for: even 20
      // seconds wasn't always enough — timed out a second time, on a run
      // where this app's own main-process LHM init (competing for the
      // same CPU/disk) took about 5 seconds, so the background task's
      // separate cold PowerShell process plausibly needed meaningfully
      // longer under that same contention. This still only ever costs
      // the extra time on that slow/busy path — the common case still
      // returns the moment real data shows up, same as before.
      const pollInterval = Duration(milliseconds: 1500);
      const maxWait = Duration(seconds: 45);
      final deadline = DateTime.now().add(maxWait);
      Map<String, dynamic>? feed;
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(pollInterval);
        feed = await readFeed();
        if (feed != null) break;
      }
      if (feed == null) {
        return 'De achtergrondtaak is geregistreerd, maar geeft na ${maxWait.inSeconds} seconden nog geen '
            'data — controleer het Log-tabblad, of probeer de app opnieuw te starten (de taak blijft '
            'geregistreerd en heeft dan mogelijk alleen meer tijd nodig gehad om op te starten).';
      }

      AppLogger.instance.info(_logSource, 'Achtergrondtaak "$_taskName" succesvol ingesteld en actief.');
      return null;
    } catch (e, st) {
      AppLogger.instance.error(_logSource, 'setupBackgroundService failed: $e\n$st');
      return 'Onverwachte fout tijdens instellen: $e';
    }
  }

  /// Removes the scheduled task — offered as an explicit "undo" for
  /// the one-time setup above, since it otherwise persists silently
  /// across every future login indefinitely.
  Future<String?> removeBackgroundService() async {
    try {
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "try { \$p = Start-Process -FilePath 'powershell.exe' "
            "-ArgumentList '-NoProfile -Command \"Unregister-ScheduledTask -TaskName \\'$_taskName\\' -Confirm:\\\$false\"' "
            "-Verb RunAs -Wait -PassThru -WindowStyle Hidden; "
            "Write-Output 'DARKTASK_ELEVATE_OK' } catch { Write-Output ('DARKTASK_ELEVATE_ERROR: ' + \$_.Exception.Message) }",
      ]);
      final output = '${result.stdout}\n${result.stderr}';
      if (!output.contains('DARKTASK_ELEVATE_OK')) {
        final errorMatch = RegExp(r'DARKTASK_ELEVATE_ERROR:\s*(.+)').firstMatch(output);
        return 'Verwijderen mislukt: ${errorMatch?.group(1)?.trim() ?? output.trim()}';
      }
      return null;
    } catch (e) {
      return 'Onverwachte fout tijdens verwijderen: $e';
    }
  }

  /// The background script itself — deliberately a close mirror of
  /// LibreHardwareMonitorBridge's own Add-Type + Computer.Open() +
  /// sensor-reading logic, just wrapped in an infinite loop that
  /// writes to a file instead of returning one value to a caller.
  /// Reusing the *already-downloaded* DLL rather than downloading its
  /// own copy — one download location, managed by the existing code
  /// path.
  String _buildServiceScript({required String dllPath, required String feedPath}) {
    final dllPathEscaped = dllPath.replaceAll("'", "''");
    final feedPathEscaped = feedPath.replaceAll("'", "''");
    return '''
\$ErrorActionPreference = 'SilentlyContinue'
\$dllPath = '$dllPathEscaped'
\$feedPath = '$feedPathEscaped'

if (-not (Test-Path \$dllPath)) { exit 1 }

try {
  Add-Type -Path \$dllPath
} catch {
  exit 1
}

try {
  \$computer = New-Object LibreHardwareMonitor.Hardware.Computer
  \$computer.IsCpuEnabled = \$true
  \$computer.IsGpuEnabled = \$true
  \$computer.Open()
} catch {
  exit 1
}

while (\$true) {
  try {
    \$result = @{ timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); cpuTempC = \$null; cpuPowerW = \$null; gpus = @() }
    foreach (\$hw in \$computer.Hardware) {
      \$hw.Update()
      if (\$hw.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::Cpu) {
        foreach (\$s in \$hw.Sensors) {
          if (\$s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and \$s.Name -like '*Package*' -and \$null -ne \$s.Value) {
            \$result.cpuTempC = [double]\$s.Value
          }
          if (\$s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Power -and \$s.Name -like '*Package*' -and \$null -ne \$s.Value) {
            \$result.cpuPowerW = [double]\$s.Value
          }
        }
      } elseif (\$hw.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::GpuAmd -or \$hw.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::GpuIntel) {
        # Same "prefer a *Core*-named sensor, fall back to whatever
        # Load/Temperature sensor exists" pick as
        # LibreHardwareMonitorBridge.readGpuSensors() uses for its own
        # per-launch read — kept identical so a GPU that needs the
        # fallback naming there needs it here too, rather than this
        # feed silently reporting less than the per-launch path would.
        \$gpuLoad = \$null
        \$loadPick = \$hw.Sensors | Where-Object { \$_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Load -and \$null -ne \$_.Value -and \$_.Name -like '*Core*' } | Select-Object -First 1
        if (-not \$loadPick) { \$loadPick = \$hw.Sensors | Where-Object { \$_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Load -and \$null -ne \$_.Value } | Select-Object -First 1 }
        if (\$loadPick) { \$gpuLoad = [double]\$loadPick.Value }

        \$gpuTemp = \$null
        \$tempPick = \$hw.Sensors | Where-Object { \$_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and \$null -ne \$_.Value -and \$_.Name -like '*Core*' } | Select-Object -First 1
        if (-not \$tempPick) { \$tempPick = \$hw.Sensors | Where-Object { \$_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and \$null -ne \$_.Value } | Select-Object -First 1 }
        if (\$tempPick) { \$gpuTemp = [double]\$tempPick.Value }

        \$result.gpus += @{ name = \$hw.Name; tempC = \$gpuTemp; loadPercent = \$gpuLoad }
      }
    }
    \$result | ConvertTo-Json -Compress -Depth 4 | Out-File -FilePath \$feedPath -Encoding utf8 -Force
  } catch {
    # A single failed read cycle shouldn't kill the whole persistent
    # loop — skip this write, try again next second. The main app's
    # own freshness check will correctly treat a gap here as "not
    # fresh" without needing this script to handle every possible
    # hardware-read failure explicitly.
  }
  Start-Sleep -Seconds 1
}
''';
  }
}
