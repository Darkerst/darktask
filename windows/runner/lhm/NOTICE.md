# Third-party notice: LibreHardwareMonitorLib

The DLLs in this folder are the official, unmodified `v0.9.6` release
build of **LibreHardwareMonitor**, downloaded directly from its GitHub
releases page:

https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/tag/v0.9.6

Only `LibreHardwareMonitorLib.dll` — the sensor library itself — is
actually used by DarkTask (via `lib/services/sensors/windows/
libre_hardware_monitor.dart`, loaded through a PowerShell bridge). The
other DLLs next to it in this folder are its own runtime dependencies
(HidSharp for HID device access, several `System.*` BCL polyfills,
etc.) — they're bundled alongside it because .NET's assembly resolution
looks for dependencies in the same folder as the DLL that needs them,
the same reasoning already documented in `libre_hardware_monitor.dart`'s
`downloadAndInstall()` method for its on-demand-download fallback path.

None of these files are modified in any way from the official release.

## Why these files are here, not just referenced

`windows/runner/CMakeLists.txt` already has a precedent for bundling
runtime DLLs a fresh Windows machine won't have (the Visual C++
Redistributable, see that file's own comments) — but those are kept
*out* of the repo on purpose, because Microsoft's redistribution terms
for them don't allow just checking the binaries into an arbitrary
GitHub repo.

LibreHardwareMonitorLib is different: it's licensed under the **Mozilla
Public License 2.0** (full text: `LICENSE.txt` in this same folder),
which permits redistributing the compiled binary as-is. That's what
lets these files be checked in directly here and bundled automatically
by every Windows build — no manual "go download this yourself" step
the way the VC++ Redistributable needs.

## License obligation this satisfies

MPL-2.0 §3.3 requires that anyone redistributing Covered Software in
Executable Form (which this is — a compiled DLL, not source) make its
Source Code Form available "in a reasonable manner," which a public
pointer to the upstream project satisfies. That pointer:

- Source repository: https://github.com/LibreHardwareMonitor/LibreHardwareMonitor
- License: Mozilla Public License 2.0 — see `LICENSE.txt` in this folder,
  or https://www.mozilla.org/en-US/MPL/2.0/

DarkTask does not modify LibreHardwareMonitorLib in any way — it's used
exactly as released, loaded at runtime via reflection
(`Add-Type -Path`) from PowerShell. No DarkTask source code links
against it directly.

## Keeping this up to date

`libre_hardware_monitor.dart`'s `_pinnedDownloadUrl` constant records
which release this folder should match (currently v0.9.6 — see that
file's own doc comment for why: v0.9.5 was originally chosen as the
first release using the PawnIO driver instead of WinRing0, which
Windows Defender flags as vulnerable, and it was later bumped to
v0.9.6 after a confirmed compatibility failure where v0.9.5.0 read no
sensors at all against a genuinely working, up-to-date PawnIO install
that the official v0.9.6.0 app read fine). Update both together if
DarkTask ever moves to a newer LibreHardwareMonitor release.
