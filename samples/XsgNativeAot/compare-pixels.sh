#!/usr/bin/env bash
# Real pixels, JIT (the in-box BAML Aero2) against NativeAOT (Aero2 compiled by XSG).
# Each build saves its own window with MacWindowCapture (a process may capture its own windows without the Screen Recording
# permission; screencapture and DevFlow's screenshot cannot: the latter needs RenderTargetBitmap, i.e. the Windows-only wpfgfx).
# The title bars are cut off before comparing: macOS draws the window frame of a binary by the SDK it was linked with (JIT: the apphost,
# SDK 15.5; NativeAOT: SDK 27.0), which differs in height and style. Needs ImageMagick (compare, magick).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; cd "${here}"
# While the screen is locked the window server does not composite windows: every capture is a blank image. Say so instead of comparing
# (or saving) blanks.
session="$(ioreg -n Root -d1 -r 2>/dev/null || true)"   # not piped into grep -q: its early exit would SIGPIPE ioreg under pipefail
if grep -q '"CGSSessionScreenIsLocked"=Yes' <<< "${session}"; then
  echo "the screen is locked: windows are not composited, a capture would be blank. Unlock it and run again." >&2
  exit 2
fi
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
out="$(mktemp -d)"
dotnet build -c Release -p:PublishAot=false -o "${out}/jit" > "${out}/jit-build.log" 2>&1
dotnet publish -c Release > "${out}/aot-publish.log" 2>&1
XSGAOT_CAPTURE="${out}/jit.png" "${out}/jit/XsgAot" check > /dev/null 2>&1
XSGAOT_CAPTURE="${out}/aot.png" "bin/Release/net10.0-windows/osx-arm64/publish/XsgAot" check > /dev/null 2>&1
# Align on the content, not on the frame: the top of the first (large) text line is the anchor, found as the first dark pixel in the
# left columns below the title bar.
anchor() { magick "$1" -crop 9x160+0+40 +repage txt:- 2>/dev/null | awk -F'[,:() ]+' 'NR>1 && !found && $3+0 < 128 {print $2; found=1}'; }
jit_top=$(( $(anchor "${out}/jit.png") + 40 - 8 )); aot_top=$(( $(anchor "${out}/aot.png") + 40 - 8 ))
echo "content starts at row: jit ${jit_top}, aot ${aot_top} (device pixels; the title bars differ by $((aot_top - jit_top)))"
# the bottom rows hold the window's rounded corners and edge, which depend on the frame; compare what is inside
height=$(( $(magick identify -format %h "${out}/aot.png" 2>/dev/null) - 180 ))
magick "${out}/jit.png" -crop "840x${height}+0+${jit_top}" +repage "${out}/jit-content.png" 2>/dev/null
magick "${out}/aot.png" -crop "840x${height}+0+${aot_top}" +repage "${out}/aot-content.png" 2>/dev/null
# compare exits 1 when the images differ: that is the answer, not a failure
diff_pixels="$(compare -metric AE "${out}/jit-content.png" "${out}/aot-content.png" "${out}/diff.png" 2>&1 | grep -v iCCP | head -1 | awk '{print $1}' || true)"
fuzzy="$(compare -metric AE -fuzz 1% "${out}/jit-content.png" "${out}/aot-content.png" null: 2>&1 | grep -v iCCP | head -1 | awk '{print $1}' || true)"
maxdiff="$(magick "${out}/jit-content.png" "${out}/aot-content.png" -compose difference -composite -alpha off -format '%[fx:maxima*255]' info: 2>/dev/null || true)"
echo "content area ($((840 * height)) pixels): ${diff_pixels} differ at all, ${fuzzy} differ by more than 1%, largest channel difference ${maxdiff}/255"
cp "${out}/jit.png" screenshots/jit-baml-aero2.png; cp "${out}/aot.png" screenshots/aot-xsg-aero2.png
