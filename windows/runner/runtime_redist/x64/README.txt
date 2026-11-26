DarkTask — Visual C++ runtime bundling (fixes "VCRUNTIME140.dll was not
found" on a clean/new Windows machine)
=========================================================================

Status: DONE — the three files are already sitting in this folder
(msvcp140.dll, vcruntime140.dll, vcruntime140_1.dll), supplied from
your own machine's Release build. Nothing left to do here; this file
is just a record of what these are and why they're here, in case that
ever needs revisiting (e.g. after a Flutter/Visual Studio upgrade
changes which exact runtime version is needed).

What this is
-------------
Flutter's own build (flutter_windows.dll) and this app's runner.exe
both depend on these three small Microsoft-supplied DLLs, which are
normally installed system-wide by the "Microsoft Visual C++
Redistributable". Your own development PC already has them (Visual
Studio / Build Tools installs the Redistributable as a side effect),
which is why you never saw this error yourself — but a machine that
never had Visual Studio, a game, or another C++ app installed on it
genuinely won't have them, and DarkTask would refuse to even start
there with "VCRUNTIME140.dll was not found".

Flutter's own documentation (docs.flutter.dev, "Building Windows apps
with Flutter" > "Building your own zip file for Windows") documents
exactly this "application-local" fix: place the three DLLs next to the
.exe, since Windows always looks in the .exe's own folder first.

How it's wired up
-------------------
windows/runner/CMakeLists.txt has a step (right after
`add_dependencies(${BINARY_NAME} flutter_assemble)`) that copies these
three files next to darktask.exe automatically, every time you run
`flutter build windows` or `flutter run -d windows`. You don't need to
copy them by hand into the Release/Debug output folder anymore — that
happens on its own now.

If this ever needs redoing
-----------------------------
Only relevant if these specific DLL versions ever stop matching what a
future Flutter/Visual Studio version expects (rare, and CMake would
still build successfully either way — bundled DLLs are only used if
Windows can't find a newer one already installed system-wide first).
To refresh them: copy the current msvcp140.dll, vcruntime140.dll and
vcruntime140_1.dll from C:\Windows\System32 on your dev machine over
the files in this folder.
