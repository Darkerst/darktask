cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# The linker generates its own default UAC manifest fragment
# ("asInvoker") independently of runner.exe.manifest's own
# <requestedExecutionLevel> — when the two disagree, mt.exe fails to
# merge them (LNK1327: "failure during running mt.exe", with
# "manifest authoring error c1010001: Values of attribute 'level' not
# equal in different manifest snippets" as the underlying cause). This
# line makes the linker's own setting match what runner.exe.manifest
# now declares, so there's nothing left to conflict.
target_link_options(${BINARY_NAME} PRIVATE "/MANIFESTUAC:level='requireAdministrator' uiAccess='false'")

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# --- Bundle the Visual C++ runtime DLLs, so the built app runs on a
# clean Windows machine that never had the Visual C++ Redistributable
# installed ("VCRUNTIME140.dll was not found" on first launch there).
# This is Flutter's own documented fix, not a workaround — see
# https://docs.flutter.dev/platform-integration/windows/building,
# "Building your own zip file for Windows": msvcp140.dll,
# vcruntime140.dll and vcruntime140_1.dll are exactly the three files
# that page lists for "application-local" deployment. Statically
# linking runner.exe's own CRT would NOT be enough by itself — Flutter's
# prebuilt flutter_windows.dll (built by the Flutter/Google team, not
# by this project) depends on these same three DLLs too, and its own
# build settings aren't something this project's CMake can change.
# Bundling next to the .exe works because Windows searches the .exe's
# own folder before anywhere else.
#
# The three DLLs are Microsoft's own redistributable binaries, not
# something to check into this repo — drop them once into
# windows/runner/runtime_redist/x64/ (see the README there for exactly where
# to get them) and every build from then on bundles them here
# automatically. Missing files just produce a configure-time warning
# below, not a build failure, so a build without them still succeeds —
# it just means that specific build still needs the Redistributable
# pre-installed on whatever machine runs it.
set(DARKTASK_VC_REDIST_DIR "${CMAKE_CURRENT_SOURCE_DIR}/runtime_redist/x64")
set(DARKTASK_VC_REDIST_DLLS "msvcp140.dll" "vcruntime140.dll" "vcruntime140_1.dll")
foreach(darktask_vc_redist_dll ${DARKTASK_VC_REDIST_DLLS})
  set(darktask_vc_redist_dll_path "${DARKTASK_VC_REDIST_DIR}/${darktask_vc_redist_dll}")
  if(EXISTS "${darktask_vc_redist_dll_path}")
    add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
      COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "${darktask_vc_redist_dll_path}" "$<TARGET_FILE_DIR:${BINARY_NAME}>"
      COMMENT "Bundling ${darktask_vc_redist_dll} (VC++ runtime) next to ${BINARY_NAME}.exe"
    )
  else()
    message(WARNING
      "DarkTask: ${darktask_vc_redist_dll} not found in ${DARKTASK_VC_REDIST_DIR} — "
      "the built app will need the Visual C++ Redistributable already "
      "installed on whatever machine runs it. See "
      "windows/runner/runtime_redist/x64/README.txt to bundle it automatically "
      "instead."
    )
  endif()
endforeach()

# --- Bundle LibreHardwareMonitorLib.dll (+ its own runtime
# dependencies), so CPU temperature/power and AMD/Intel GPU sensors
# work from the very first launch on a fresh machine, instead of
# needing the in-app "download LibreHardwareMonitorLib" step first
# (see lib/services/sensors/windows/libre_hardware_monitor.dart's
# downloadAndInstall(), which still exists as a repair/reinstall path
# — e.g. if these files are ever deleted from a running install — but
# is no longer the primary way most people get the DLL).
#
# Unlike the VC++ redist DLLs above, these ARE checked into this repo
# directly (windows/runner/lhm/) rather than needing a manual
# one-time download: LibreHardwareMonitorLib is MPL-2.0 licensed,
# which permits redistributing the compiled binary as-is. See
# windows/runner/lhm/NOTICE.md for the full explanation and the
# license-obligation this satisfies, and LICENSE.txt in that same
# folder for the license text itself. Every file copied here is the
# official, unmodified v0.9.5 release build — see NOTICE.md for where
# it came from.
#
# All .dll files in that folder are bundled (not just
# LibreHardwareMonitorLib.dll itself) for the same reason
# downloadAndInstall()'s PowerShell script copies every sibling DLL:
# .NET's assembly resolution looks for a DLL's own dependencies
# (HidSharp, several System.* polyfills, ...) in the same folder, and
# copying only the one requested file causes a
# ReflectionTypeLoadException at load time.
# CONFIGURE_DEPENDS: without it the glob is evaluated only when CMake
# (re)configures the project. If lhm/ was added or changed after the
# last configure, the list stayed empty and the DLLs were silently
# never bundled — the app then downloaded LibreHardwareMonitorLib from
# GitHub on every fresh machine (seen in the logs of two machines).
# With it, the folder is re-scanned on every build.
file(GLOB DARKTASK_LHM_DLLS CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/lhm/*.dll")
list(LENGTH DARKTASK_LHM_DLLS DARKTASK_LHM_DLL_COUNT)
if(DARKTASK_LHM_DLLS)
  # Loud and unconditional (not hidden behind -v/--verbose) — this is
  # the one line to look for in the build output to confirm the bundle
  # actually happened, since a silently-empty glob (wrong folder, files
  # not actually present on disk despite being expected) would
  # otherwise look identical to a totally successful, silent build.
  message(STATUS
    "DarkTask: found ${DARKTASK_LHM_DLL_COUNT} LibreHardwareMonitorLib DLL(s) in "
    "${CMAKE_CURRENT_SOURCE_DIR}/lhm — will bundle next to ${BINARY_NAME}.exe."
  )
  foreach(darktask_lhm_dll ${DARKTASK_LHM_DLLS})
    add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
      COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "${darktask_lhm_dll}" "$<TARGET_FILE_DIR:${BINARY_NAME}>"
      COMMENT "Bundling ${darktask_lhm_dll} (LibreHardwareMonitorLib) next to ${BINARY_NAME}.exe"
    )
  endforeach()
  # POST_BUILD only runs when the exe itself is relinked, so on a
  # rebuild where the exe is already up to date the copy above would
  # not happen. `flutter build windows` runs the install step on every
  # build, so also install the DLLs from there — same folder as the exe
  # (CMAKE_INSTALL_PREFIX is Flutter's bundle directory).
  install(FILES ${DARKTASK_LHM_DLLS}
    DESTINATION "${CMAKE_INSTALL_PREFIX}"
    COMPONENT Runtime
  )
else()
  # A WARNING (not just STATUS) specifically so this is impossible to
  # miss in the build output even without extra verbosity flags — CMake
  # highlights warnings by default and most CI/IDE integrations surface
  # them separately from ordinary log lines.
  message(WARNING
    "DarkTask: no .dll files found in ${CMAKE_CURRENT_SOURCE_DIR}/lhm/ — "
    "the built app will fall back to its in-app 'download "
    "LibreHardwareMonitorLib' step (Performance screen) on first run "
    "instead of having CPU temperature/power and AMD/Intel GPU sensors "
    "work immediately. If you expected these files to be here, check "
    "that windows/runner/lhm/ (29 files total: 27 .dll files — "
    "LibreHardwareMonitorLib.dll plus its own dependency DLLs — plus "
    "LICENSE.txt and NOTICE.md) was actually copied into this project "
    "— it's easy to miss when merging in only specific files by hand "
    "instead of the whole windows/runner folder."
  )
endif()
