#!/usr/bin/env bash
# Builds and publishes ProGPU, LibreWPF, and LibreWinForms NuGet packages
# into a local NuGet feed folder for cross-repo dev consumption.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wpf_root="${repo_root}/LibreWPF"
progpu_root="${wpf_root}/external/ProGPU"
winforms_root="${wpf_root}/external/LibreWinForms"

local_feed="${DIST_LOCAL_FEED:-${repo_root}/artifacts/local-feed}"
local_feed_name="${DIST_LOCAL_FEED_NAME:-openavalon-local}"
# This workstation prepares the Windows release feed by default.  The explicit
# platform selector retains the upstream macOS and full cross-platform paths.
target_platform="${DIST_LOCAL_TARGET_PLATFORM:-windows}"

dev_package_version="${PROGPU_WPF_DEV_PACKAGE_VERSION:-0.1.0-preview.57}"
progpu_package_version="${PROGPU_WPF_PROGPU_PACKAGE_VERSION:-0.1.0-preview.62}"

wpf_dotnet="${wpf_root}/.dotnet/dotnet"
if [[ ! -x "${wpf_dotnet}" && -x "${wpf_dotnet}.exe" ]]; then
  wpf_dotnet="${wpf_dotnet}.exe"
elif [[ ! -x "${wpf_dotnet}" ]]; then
  wpf_dotnet="dotnet"
fi

mkdir -p "${local_feed}"

if [[ "${target_platform}" != "all" && "${target_platform}" != "macos" && "${target_platform}" != "windows" ]]; then
  echo "DIST_LOCAL_TARGET_PLATFORM must be 'windows', 'macos', or 'all'." >&2
  exit 1
fi

# A Windows-only feed deliberately validates and publishes win-x64 and
# win-arm64 native payloads, without claiming that Linux/macOS assets exist.
# Keep the default upstream behavior for the explicit macOS/all modes.
if [[ "${target_platform}" == "windows" ]]; then
  export PROGPU_PACKAGE_WINDOWS_ONLY="${PROGPU_PACKAGE_WINDOWS_ONLY:-1}"
  export ProGpuNativePackageWindowsOnly="${ProGpuNativePackageWindowsOnly:-true}"
  # MSBuild's /m switch does not constrain cl.exe's own /MP workers.  The
  # System.Printing PCH is large enough to exhaust this workstation otherwise.
  export CL="${CL:-} /MP1"
  # dotnet msbuild does not discover Visual C++ targets by itself.  Supply the
  # installed VS targets so LibreWPF's native projects can restore and build.
  if [[ -z "${VCTargetsPath:-}" ]]; then
    vs_vc_targets='C:/Program Files/Microsoft Visual Studio/18/Community/MSBuild/Microsoft/VC/v180'
    if [[ -f "${vs_vc_targets}/Microsoft.Cpp.Default.props" ]]; then
      export VCTargetsPath="$(cygpath -w "${vs_vc_targets}")\\"
    fi
  fi
  wpf_msbuild='C:/Program Files/Microsoft Visual Studio/18/Community/MSBuild/Current/Bin/MSBuild.exe'
  if [[ ! -x "${wpf_msbuild}" ]]; then
    echo "Visual Studio MSBuild.exe is required for LibreWPF validation graphs." >&2
    exit 1
  fi
else
  export PROGPU_PACKAGE_WINDOWS_ONLY="${PROGPU_PACKAGE_WINDOWS_ONLY:-0}"
  export ProGpuNativePackageWindowsOnly="${ProGpuNativePackageWindowsOnly:-false}"
fi

run_wpf_msbuild() {
  if [[ "${target_platform}" == "windows" ]]; then
    "${wpf_msbuild}" "$@" \
      -m:1 \
      -property:Platform=x64 \
      -property:IjwHostSourcePath="${wpf_root}/.dotnet/packs/Microsoft.NETCore.App.Host.win-x64/11.0.0-preview.7.26381.103/runtimes/win-x64/native/ijwhost.dll"
  else
    "${wpf_dotnet}" msbuild "$@"
  fi
}

pack_wpf_project() {
  local project="$1"
  local package_id="$2"
  local package_version="$3"
  # Pack AnyCPU. These packages carry their managed assemblies in a RID-NEUTRAL
  # lib/<tfm> folder, so stamping them for one architecture makes them unusable
  # everywhere else: the CLR does not fall back to JIT for a wrong-architecture
  # managed assembly, it simply fails the load. On an ARM64 workstation the old
  # hardcoded "-p:Platform=x64" shipped an x64 ProGPU.Wpf.dll inside
  # LibreWPF.ProGPU/lib/net10.0, and the consumer died at startup with
  # "Could not load file or assembly 'ProGPU.Wpf' ... The system cannot find the
  # file specified" - a message that names the assembly sitting right there on
  # disk, which is what makes it so hard to read.
  #
  # AnyCPU is also what the bait-and-switch arch-neutral packages
  # (LibreWPF.Transport, LibreWPF.Sdk) require: packaging/Directory.Build.props
  # sets IsPackable=false when $(Platform) is an architecture and
  # $(CreateArchNeutralPackage) is true, so a multi-architecture build emits them
  # exactly once. Forcing an architecture turned `dotnet pack` into a silent
  # no-op for those two - and because the previous .nupkg is deleted first, the
  # feed simply lost them.
  #
  # Genuinely architecture-specific payload (the C++/CLI DirectWriteForwarder,
  # PresentationCore) is NOT packed here; it ships under runtimes/<rid>/ and the
  # consumer selects it per RID.
  local pack_platform=AnyCPU
  rm -f \
    "${local_feed}/${package_id}.${package_version}.nupkg" \
    "${local_feed}/${package_id}.${package_version}.snupkg"
  "${wpf_dotnet}" pack "${wpf_root}/${project}" \
    -c Release \
    -o "${local_feed}" \
    -v:minimal \
    -p:Version="${package_version}" \
    -p:PackageVersion="${package_version}" \
    $([[ "${target_platform}" == "windows" ]] && echo "-p:Platform=${pack_platform} -p:IjwHostSourcePath=${wpf_root}/.dotnet/packs/Microsoft.NETCore.App.Host.win-x64/11.0.0-preview.7.26381.103/runtimes/win-x64/native/ijwhost.dll")
  # A skipped pack target still exits 0, so the exit code alone cannot tell a
  # real pack from one that produced nothing.  Verify the artifact instead.
  if [[ ! -f "${local_feed}/${package_id}.${package_version}.nupkg" ]]; then
    echo "pack produced no ${package_id}.${package_version}.nupkg from ${project}." >&2
    echo "Check IsPackable/CreateArchNeutralPackage for Platform=${pack_platform}." >&2
    exit 1
  fi
}

echo "== Packing ProGPU packages =="
PROGPU_PACKAGE_OUTPUT="${local_feed}" \
PROGPU_PACKAGE_GROUP="${PROGPU_PACKAGE_GROUP:-$([[ "${target_platform}" == "macos" ]] && echo opendevelop-macos || echo portable)}" \
  "${progpu_root}/eng/progpu-pack.sh"

echo "== Packing the ProGPU projects LibreWPF.Sdk depends on =="
# LibreWPF.Sdk consumes these under the LibreWPF.* preview version, distinct
# from the plain ProGPU.* packages above (which use ProGPU's own version).
for pair in \
  "external/ProGPU/src/ProGPU.Backend/ProGPU.Backend.csproj:ProGPU.Backend" \
  "external/ProGPU/src/ProGPU.Backend.Dawn/ProGPU.Backend.Dawn.csproj:ProGPU.Backend.Dawn" \
  "external/ProGPU/src/ProGPU.Text.Shaping/ProGPU.Text.Shaping.csproj:ProGPU.Text.Shaping" \
  "external/ProGPU/src/ProGPU.DirectX/ProGPU.DirectX.csproj:ProGPU.DirectX" \
  "external/ProGPU/src/ProGPU.Transpiler/ProGPU.Transpiler.csproj:ProGPU.Transpiler" \
  "external/ProGPU/src/ProGPU.Compute/ProGPU.Compute.csproj:ProGPU.Compute" \
  "external/ProGPU/src/ProGPU.Vector/ProGPU.Vector.csproj:ProGPU.Vector" \
  "external/ProGPU/src/ProGPU.Text/ProGPU.Text.csproj:ProGPU.Text" \
  "external/ProGPU/src/ProGPU.Scene/ProGPU.Scene.csproj:ProGPU.Scene" \
  "external/ProGPU/src/ProGPU.Layout/ProGPU.Layout.csproj:ProGPU.Layout" \
  "external/ProGPU/src/ProGPU.Virtualization/ProGPU.Virtualization.csproj:ProGPU.Virtualization" \
  "external/ProGPU/src/ProGPU.WinRT/ProGPU.WinRT.csproj:ProGPU.WinRT" \
  "external/ProGPU/src/ProGPU.Media/ProGPU.Media.csproj:ProGPU.Media" \
  "external/ProGPU/src/ProGPU.Media.Scene/ProGPU.Media.Scene.csproj:ProGPU.Media.Scene" \
  "external/ProGPU/src/ProGPU.WinUI/ProGPU.WinUI.csproj:ProGPU.WinUI" \
  "external/ProGPU/src/ProGPU.Avalonia/ProGPU.Avalonia.csproj:ProGPU.Avalonia" \
  "external/ProGPU/src/SkiaSharp/SkiaSharp.csproj:ProGPU.SkiaSharp" \
  "external/ProGPU/src/System.Drawing.Common/System.Drawing.Common.csproj:ProGPU.System.Drawing.Common" \
  "external/ProGPU/src/ProGPU.Wpf.Interop/ProGPU.Wpf.Interop.csproj:LibreWPF.Interop" \
; do
  project="${pair%%:*}"
  package_id="${pair##*:}"
  pack_wpf_project "${project}" "${package_id}" "${progpu_package_version}"
done

# The per-RID managed payload (runtimes/<rid>/lib/net10.0/{PresentationCore,DirectWriteForwarder})
# does NOT come from the transport build: the ArchNeutral project copies it out of
# artifacts/windows-managed-runtime, which only eng/progpu-wpf-windows-managed-runtime.ps1
# produces. dist.local.sh used to consume that directory without ever regenerating it, so the
# package shipped a two-week-old PresentationCore beside a freshly built PresentationFramework.
# Sync-LibreWpfDevelopmentRuntime installs exactly those two per-RID files last, so the stale
# PresentationCore won - and the app died on first text box with
# "MissingMethodException: InputManager.get_UsesPortableInput()", an API the fresh
# PresentationFramework expected and the stale PresentationCore did not have.
if [[ "${target_platform}" == "windows" ]]; then
  echo "== Producing the per-RID Windows managed runtime payload =="
  pwsh -NoProfile -File "${wpf_root}/eng/progpu-wpf-windows-managed-runtime.ps1" -Configuration Release
  # `pwsh -File` reports 0 even when the script dies on a terminating error, so `set -e` never
  # fired: the script deleted the payload directory, threw on its first Join-Path, and the pack
  # step then shipped whatever per-RID files happened to survive from an earlier run. Assert the
  # artifacts this feed actually consumes instead of trusting the exit code - the same lesson as
  # pack_wpf_project below.
  # win-x86 is not produced or shipped; see the comment in the script and in the transport csproj.
  for rid in win-x64 win-arm64; do
    for dll in PresentationCore DirectWriteForwarder; do
      staged="${wpf_root}/artifacts/windows-managed-runtime/${rid}/net10.0/${dll}.dll"
      if [[ ! -f "${staged}" ]]; then
        echo "The per-RID managed runtime payload is missing ${rid}/${dll}.dll." >&2
        echo "progpu-wpf-windows-managed-runtime.ps1 did not complete; do not pack on top of this." >&2
        exit 1
      fi
    done
  done
fi

# LibreWPF.Transport is zipped from a staging tree, not from a project's build output, and that
# tree is additive: RemoveStaleLibreWpfTransportPayload deliberately excludes the CURRENT target
# framework's folder, so a file that once landed in lib/<tfm> and is no longer produced stays
# there forever and keeps getting shipped. That is how the package came to carry a two-week-old
# ProGPU.Wpf.Interop.dll next to a freshly built PresentationFramework.dll that called an interop
# API the stale copy did not have - the consumer then died in
# ProGpuWpfSdkPortableBootstrap.Initialize() with a MissingMethodException that reads like a
# version-pin problem. Clear the staging tree so every pack starts from what this build produced.
transport_staging="${wpf_root}/artifacts/packaging/Release/LibreWPF.Transport"
if [[ -d "${transport_staging}" ]]; then
  echo "== Clearing stale LibreWPF.Transport staging payload =="
  rm -rf "${transport_staging}/lib" "${transport_staging}/ref"
fi

canonical_feed="${DIST_LOCAL_CANONICAL_WINFORMS_FEED:-${repo_root}/artifacts/canonical-winforms-feed}"

build_canonical_winforms() {
  rm -rf "${canonical_feed}"
  PROGPU_WPF_CANONICAL_WINFORMS_PACKAGE_OUTPUT="${canonical_feed}" \
  PROGPU_WPF_CANONICAL_WINFORMS_PACKAGE_VERSION="${dev_package_version}" \
  PROGPU_WPF_CANONICAL_PROGPU_PACKAGE_VERSION="${progpu_package_version}" \
  PROGPU_WPF_CANONICAL_WINFORMS_PLATFORM="${PROGPU_WPF_CANONICAL_WINFORMS_PLATFORM:-ARM64}" \
  DOTNET_INSTALL_DIR="${wpf_root}/.dotnet" \
  PROGPU_WPF_RUN_DRAWING_QUALITY_GATES="${PROGPU_WPF_RUN_DRAWING_QUALITY_GATES:-0}" \
    "${wpf_root}/eng/progpu-wpf-canonical-winforms-integration.sh"
}

echo "== Building the LibreWPF managed transport and theme payload =="
# On macOS the canonical WinForms integration graph must run before the transport build.
if [[ "${target_platform}" == "macos" ]]; then
  build_canonical_winforms
fi
run_wpf_msbuild \
  "${wpf_root}/eng/ProGPU.Wpf.ValidationGraphs.proj" \
  -target:RestoreManagedTransport \
  -property:Configuration=Release \
  -verbosity:minimal
run_wpf_msbuild \
  "${wpf_root}/eng/ProGPU.Wpf.ValidationGraphs.proj" \
  -target:BuildManagedTransport \
  -property:Configuration=Release \
  -verbosity:minimal
run_wpf_msbuild \
  "${wpf_root}/eng/ProGPU.Wpf.ValidationGraphs.proj" \
  -target:RestoreThemes \
  -property:Configuration=Release \
  -verbosity:minimal
run_wpf_msbuild \
  "${wpf_root}/eng/ProGPU.Wpf.ValidationGraphs.proj" \
  -target:BuildThemes \
  -property:Configuration=Release \
  -verbosity:minimal

echo "== Packing LibreWPF transport, ProGPU bridge, and SDK =="
pack_wpf_project "packaging/Microsoft.DotNet.Wpf.GitHub/Microsoft.DotNet.Wpf.GitHub.ArchNeutral.csproj" "LibreWPF.Transport" "${dev_package_version}"
pack_wpf_project "src/ProGPU.Wpf/ProGPU.Wpf.csproj" "LibreWPF.ProGPU" "${dev_package_version}"
pack_wpf_project "packaging/ProGPU.Wpf.Sdk/ProGPU.Wpf.Sdk.ArchNeutral.csproj" "LibreWPF.Sdk" "${dev_package_version}"

echo "== Packing LibreWinForms packages =="
# librewinforms-pack.sh validates that its output directory holds EXACTLY the LibreWinForms
# preview bundle and nothing else ("Unexpected current-version package artifact: ..."), which is a
# legitimate purity gate for a release bundle but incompatible with pointing it straight at the
# shared dev feed - by this point local-feed also holds LibreWPF.Transport/ProGPU/Sdk. Give it a
# private staging directory and publish the result into the shared feed afterwards.
librewinforms_feed="${DIST_LOCAL_LIBREWINFORMS_FEED:-${repo_root}/artifacts/librewinforms-feed}"
rm -rf "${librewinforms_feed}"
mkdir -p "${librewinforms_feed}"

publish_librewinforms_packages() {
  shopt -s nullglob
  local produced=("${librewinforms_feed}"/*.nupkg "${librewinforms_feed}"/*.snupkg)
  shopt -u nullglob
  if [[ "${#produced[@]}" -eq 0 ]]; then
    echo "librewinforms-pack.sh produced no packages in ${librewinforms_feed}." >&2
    exit 1
  fi
  cp -f "${produced[@]}" "${local_feed}/"
}

if [[ "${target_platform}" == "macos" || "${target_platform}" == "windows" ]]; then
  if [[ "${target_platform}" == "windows" ]]; then
    build_canonical_winforms
  fi
  # WindowsFormsIntegration is built from the LibreWPF tree (it is the WPF<->WinForms bridge), so
  # the canonical WFI package records LibreWPF's commit via SourceLink, and
  # LIBREWINFORMS_CANONICAL_WFI_COMMIT is documented as "the exact LibreWPF source commit that
  # produced canonical WFI". librewinforms-pack.sh checks the LibreWinForms side separately,
  # against its own repo HEAD. Passing the LibreWinForms commit here failed that first check with
  # "Canonical WFI package does not record expected LibreWPF commit ...".
  canonical_commit="$(git -C "${wpf_root}" rev-parse HEAD)"
  LIBREWINFORMS_CANONICAL_WFI_PACKAGE_SOURCE="${canonical_feed}" \
  LIBREWINFORMS_CANONICAL_WFI_COMMIT="${canonical_commit}" \
  LIBREWINFORMS_PACKAGE_OUTPUT="${librewinforms_feed}" \
  LIBREWINFORMS_DEV_PACKAGE_VERSION="${dev_package_version}" \
  LIBREWINFORMS_PROGPU_PACKAGE_VERSION="${progpu_package_version}" \
    "${winforms_root}/eng/librewinforms-pack.sh"
  publish_librewinforms_packages
else
LIBREWINFORMS_PACKAGE_OUTPUT="${librewinforms_feed}" \
LIBREWINFORMS_DEV_PACKAGE_VERSION="${dev_package_version}" \
LIBREWINFORMS_PROGPU_PACKAGE_VERSION="${progpu_package_version}" \
  "${winforms_root}/eng/librewinforms-pack.sh"
publish_librewinforms_packages
fi

# A managed assembly must carry an architecture its consumer can actually load, and three folders
# in these packages each have their own rule:
#
#   lib/<tfm>            RID-neutral, so AnyCPU only. The CLR fails the load outright for a
#                        wrong-architecture assembly (no JIT fallback), and the resulting
#                        "Could not load file or assembly 'X' ... cannot find the file specified"
#                        names a file that is plainly present, so the cause is easy to miss.
#   ref/<tfm>            Reference assemblies, compiled against rather than loaded. An
#                        arch-stamped one does not fail at run time, it fails the BUILD with
#                        "CS8012: Referenced assembly 'X' targets a different processor" - a
#                        warning in most projects and therefore invisible, but an error wherever
#                        TreatWarningsAsErrors is on. That is how an x64 ref/ tree silently broke
#                        OpenDevelop's AvalonDock themes after a local feed rebuild.
#   runtimes/<rid>/lib/  Per-RID, so AnyCPU or that RID's own architecture - never another's. The
#                        packaging duplicates one managed payload into all three RID folders
#                        (StageLibreWpfRidManagedTransportPayload), so an arch-stamped file in it
#                        lands in two folders where it cannot load.
#
# The producing-side rule lives in LibreWPF/eng/WpfArcadeSdk/Sdk/Sdk.props, which forces
# PlatformTarget=AnyCPU for the transport assemblies and, separately, for every *-ref.csproj.
# Report rather than fail: the canonical WinForms graph still emits arm64
# WindowsFormsIntegration/ProGPU.DirectX, which is a separate fix.
echo "== Checking payload architectures =="
probe_pe_machine() {
  local file="$1" off
  off="$(od -An -tu4 -j 60 -N 4 "${file}" 2>/dev/null | tr -d ' ')"
  [[ "${off}" =~ ^[0-9]+$ ]] || return 1
  od -An -tx2 -j $((off + 4)) -N 2 "${file}" 2>/dev/null | tr -d ' '
}

check_anycpu_payload() {
  local scratch offenders=0 pkg entry tmp machine rid expected
  scratch="$(mktemp -d)"
  for pkg in "${local_feed}"/*.nupkg; do
    [[ -e "${pkg}" ]] || continue
    while IFS= read -r entry; do
      [[ -n "${entry}" ]] || continue
      tmp="${scratch}/probe.dll"
      unzip -p "${pkg}" "${entry}" > "${tmp}" 2>/dev/null || continue
      [[ -s "${tmp}" ]] || continue
      machine="$(probe_pe_machine "${tmp}")" || continue
      [[ -n "${machine}" ]] || continue
      # 0x014c is both AnyCPU and x86, and is always acceptable.
      [[ "${machine}" == "014c" ]] && continue
      # DirectWriteForwarder is C++/CLI and therefore CANNOT be AnyCPU, yet it has to appear in
      # lib/<tfm> as well so a RID-neutral restore resolves the reference at all. There is no
      # version of this file that satisfies the lib/ rule, so flagging it forever would only
      # train the reader to ignore this report. Consumers get the right one because
      # ProGPU.Wpf.Sdk.targets prefers runtimes/<rid>/ over lib/ when copying the payload.
      case "${entry}" in
        lib/*/DirectWriteForwarder.dll) continue ;;
      esac
      case "${entry}" in
        runtimes/*)
          rid="${entry#runtimes/}"
          rid="${rid%%/*}"
          case "${rid}" in
            win-x64)   expected="8664" ;;
            win-arm64) expected="aa64" ;;
            win-x86)   expected="014c" ;;
            *)         expected="" ;;
          esac
          [[ -n "${expected}" && "${machine}" == "${expected}" ]] && continue
          echo "  wrong-arch for ${rid}: $(basename "${pkg}") ${entry} (machine 0x${machine})" >&2
          ;;
        *)
          echo "  arch-stamped: $(basename "${pkg}") ${entry} (machine 0x${machine})" >&2
          ;;
      esac
      offenders=$((offenders + 1))
    done < <(unzip -Z1 "${pkg}" 2>/dev/null |
               grep -E '^(lib|ref)/[^/]+/.*\.dll$|^runtimes/[^/]+/lib/[^/]+/.*\.dll$')
  done
  rm -rf "${scratch}"
  if [[ "${offenders}" -gt 0 ]]; then
    echo "  ${offenders} assemblies carry an architecture their folder cannot promise; they will" >&2
    echo "  fail to load, or fail the consumer's build with CS8012 where the entry is under ref/." >&2
    echo "  See OpenDevelop doc/technotes/librewpf.md." >&2
  else
    echo "  lib/, ref/ and every runtimes/<rid>/lib/ entry carry a loadable architecture."
  fi
}
check_anycpu_payload

# NuGet never re-extracts a package whose id+version it already has, and this feed republishes the
# same preview version every run. A corrected package therefore sits in the feed while every
# consumer keeps compiling and running against the stale extracted copy under
# ~/.nuget/packages/<id>/<version>/. That is not a corner case: it is how 25 packages came to serve
# ARM64 assemblies to an x64 process for a full day, surviving several rounds of "fixed and
# verified" because every check looked at the feed rather than the cache. Evict by timestamp - the
# feed file is newer than the extraction directory exactly when the package was republished.
echo "== Evicting stale NuGet cache entries for republished packages =="
evict_stale_cache_entries() {
  local nuget_root evicted=0 pkg base id ver cached
  nuget_root="${NUGET_PACKAGES:-${HOME}/.nuget/packages}"
  [[ -d "${nuget_root}" ]] || { echo "  no global package folder at ${nuget_root}."; return; }
  for pkg in "${local_feed}"/*.nupkg; do
    [[ -e "${pkg}" ]] || continue
    base="$(basename "${pkg}" .nupkg)"
    # "<Id>.<Version>" where the version starts at the first dot followed by a digit.
    ver="$(sed -E 's/^.*\.([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?)$/\1/' <<<"${base}")"
    id="${base%".${ver}"}"
    [[ -n "${ver}" && "${id}" != "${base}" ]] || continue
    cached="${nuget_root}/$(tr '[:upper:]' '[:lower:]' <<<"${id}")/${ver}"
    [[ -d "${cached}" ]] || continue
    if [[ "${cached}" -ot "${pkg}" ]]; then
      rm -rf "${cached}"
      echo "  evicted ${id}/${ver}"
      evicted=$((evicted + 1))
    fi
  done
  echo "  ${evicted} stale cache entr$([[ "${evicted}" == 1 ]] && echo y || echo ies) removed."
}
evict_stale_cache_entries

echo "== Registering local NuGet source '${local_feed_name}' =="
if ! dotnet nuget list source | grep -Fq "${local_feed}"; then
  dotnet nuget add source "${local_feed}" --name "${local_feed_name}"
else
  echo "Source already registered."
fi

echo "== Published packages =="
ls -1 "${local_feed}"/*.nupkg 2>/dev/null || echo "(none)"
