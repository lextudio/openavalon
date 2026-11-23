#!/usr/bin/env bash
# The same window in the JIT build (the in-box BAML Aero2) and in the NativeAOT build (Aero2 compiled by XSG) must have the same visual
# tree: type and size of every element. Exit 0 when they are identical once the outermost client-area height (the window height minus the native
# frame, which macOS draws by the SDK the binary was linked with: 612 for the JIT apphost, 608 for NativeAOT) is masked; exit 1 and print the diff otherwise.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cd "${here}"
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
out="$(mktemp -d)"
dotnet build -c Release -p:PublishAot=false -o "${out}/jit" > "${out}/jit-build.log" 2>&1
dotnet publish -c Release > "${out}/aot-publish.log" 2>&1
XSGAOT_DUMP=1 "${out}/jit/XsgAot" check 2>&1 | grep -v IMKCFRunLoop > "${out}/jit.txt"
XSGAOT_DUMP=1 "bin/Release/net10.0-windows/osx-arm64/publish/XsgAot" check > "${out}/aot.txt" 2>&1
echo "jit: $(wc -l < "${out}/jit.txt") elements, aot: $(wc -l < "${out}/aot.txt") elements"
# Mask the one expected difference: every element that spans the whole client area has the height of the first (outermost) element.
for run in jit aot; do
  height="$(awk 'NR==2 {split($2, size, "x"); print size[2]; exit}' "${out}/${run}.txt")"
  echo "${run}: client area height ${height}"
  awk -v h="${height}" '{ sub("x" h "$", "xCLIENT"); print }' "${out}/${run}.txt" > "${out}/${run}.masked.txt"
done
if diff "${out}/jit.masked.txt" "${out}/aot.masked.txt" > "${out}/tree.diff"; then
  echo "identical (client-area height masked)"
else
  echo "the visual trees differ:"; cat "${out}/tree.diff"; exit 1
fi
