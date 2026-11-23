#!/usr/bin/env bash
# Builds the LibreWPF assemblies this prototype needs ahead of the published packages (PresentationFramework with the generated
# resource registry and theme lookup, ProGPU.Wpf with explicit Silk.NET platform registration) and patches them into this sample's
# private packages folder (see NuGet.config). Rerun after changing either; `--restore` puts the published files back.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wpf="${here}/../../LibreWPF"
dotnet_exe="${wpf}/.dotnet/dotnet"; [[ -x "${dotnet_exe}" ]] || dotnet_exe=dotnet
version="$(sed -n 's/.*"LibreWPF.Sdk": *"\([^"]*\)".*/\1/p' "${here}/global.json")"
transport="${here}/packages/librewpf.transport/${version}"
progpu="${here}/packages/librewpf.progpu/${version}"

swap() { # swap <package file> <replacement>
  [[ -f "$1" ]] || { echo "missing $1 (run 'dotnet restore' first)" >&2; exit 1; }
  [[ -f "$1.orig" ]] || cp "$1" "$1.orig"
  cp "$2" "$1"; echo "patched $1"
}

if [[ "${1:-}" == "--restore" ]]; then
  for f in "${transport}"/{ref,lib}/net10.0/PresentationFramework.dll "${progpu}"/lib/net10.0/ProGPU.Wpf.dll; do
    [[ -f "$f.orig" ]] && mv "$f.orig" "$f" && echo "restored $f"
  done
  exit 0
fi

export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
(cd "${here}" && dotnet restore >/dev/null)
build=(-c Release -v:minimal -p:RunNetFrameworkApiCompat=false -p:RunRefApiCompat=false)
# From the LibreWPF checkout, so its own global.json picks the SDK, not this sample's.
(cd "${wpf}" && for project in src/Microsoft.DotNet.Wpf/src/PresentationFramework/PresentationFramework.csproj \
                              src/Microsoft.DotNet.Wpf/src/PresentationFramework/ref/PresentationFramework-ref.csproj \
                              src/ProGPU.Wpf/ProGPU.Wpf.csproj; do
  "${dotnet_exe}" build "${project}" "${build[@]}"
done)
swap "${transport}/ref/net10.0/PresentationFramework.dll" "${wpf}/artifacts/bin/PresentationFramework-ref/Release/net10.0/PresentationFramework.dll"
swap "${transport}/lib/net10.0/PresentationFramework.dll" "${wpf}/artifacts/bin/PresentationFramework/Release/net10.0/PresentationFramework.dll"
swap "${progpu}/lib/net10.0/ProGPU.Wpf.dll" "${wpf}/src/ProGPU.Wpf/bin/Release/net10.0/ProGPU.Wpf.dll"
