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
  rm -f \
    "${local_feed}/${package_id}.${package_version}.nupkg" \
    "${local_feed}/${package_id}.${package_version}.snupkg"
  "${wpf_dotnet}" pack "${wpf_root}/${project}" \
    -c Release \
    -o "${local_feed}" \
    -v:minimal \
    -p:Version="${package_version}" \
    -p:PackageVersion="${package_version}" \
    $([[ "${target_platform}" == "windows" ]] && echo "-p:Platform=x64 -p:IjwHostSourcePath=${wpf_root}/.dotnet/packs/Microsoft.NETCore.App.Host.win-x64/11.0.0-preview.7.26381.103/runtimes/win-x64/native/ijwhost.dll")
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

echo "== Building the LibreWPF managed transport and theme payload =="
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
if [[ "${target_platform}" == "macos" || "${target_platform}" == "windows" ]]; then
  canonical_feed="${DIST_LOCAL_CANONICAL_WINFORMS_FEED:-${repo_root}/artifacts/canonical-winforms-feed}"
  rm -rf "${canonical_feed}"
  PROGPU_WPF_CANONICAL_WINFORMS_PACKAGE_OUTPUT="${canonical_feed}" \
  PROGPU_WPF_CANONICAL_WINFORMS_PACKAGE_VERSION="${dev_package_version}" \
  PROGPU_WPF_CANONICAL_PROGPU_PACKAGE_VERSION="${progpu_package_version}" \
  PROGPU_WPF_CANONICAL_WINFORMS_PLATFORM="${PROGPU_WPF_CANONICAL_WINFORMS_PLATFORM:-ARM64}" \
  DOTNET_INSTALL_DIR="${wpf_root}/.dotnet" \
  PROGPU_WPF_RUN_DRAWING_QUALITY_GATES="${PROGPU_WPF_RUN_DRAWING_QUALITY_GATES:-0}" \
    "${wpf_root}/eng/progpu-wpf-canonical-winforms-integration.sh"
  canonical_commit="$(git -C "${winforms_root}" rev-parse HEAD)"
  LIBREWINFORMS_CANONICAL_WFI_PACKAGE_SOURCE="${canonical_feed}" \
  LIBREWINFORMS_CANONICAL_WFI_COMMIT="${canonical_commit}" \
  LIBREWINFORMS_PACKAGE_OUTPUT="${local_feed}" \
  LIBREWINFORMS_DEV_PACKAGE_VERSION="${dev_package_version}" \
  LIBREWINFORMS_PROGPU_PACKAGE_VERSION="${progpu_package_version}" \
    "${winforms_root}/eng/librewinforms-pack.sh"
else
LIBREWINFORMS_PACKAGE_OUTPUT="${local_feed}" \
LIBREWINFORMS_DEV_PACKAGE_VERSION="${dev_package_version}" \
LIBREWINFORMS_PROGPU_PACKAGE_VERSION="${progpu_package_version}" \
  "${winforms_root}/eng/librewinforms-pack.sh"
fi

echo "== Registering local NuGet source '${local_feed_name}' =="
if ! dotnet nuget list source | grep -Fq "${local_feed}"; then
  dotnet nuget add source "${local_feed}" --name "${local_feed_name}"
else
  echo "Source already registered."
fi

echo "== Published packages =="
ls -1 "${local_feed}"/*.nupkg 2>/dev/null || echo "(none)"
