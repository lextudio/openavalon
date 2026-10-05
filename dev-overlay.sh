#!/usr/bin/env bash
# Inner-loop shortcut: rebuild individual LibreWPF assemblies and overlay them onto a consumer's
# build output (for example OpenDevelop's bin), so a one-file change can be tried in minutes
# instead of a full dist.local.sh. This is for local iteration ONLY - it never touches the feed,
# and the next restore/build of the consumer from the feed replaces the overlaid files. Publish
# with dist.local.sh once the change is right.
#
#   ./dev-overlay.sh <consumer-bin-dir> <AssemblyName>...   overlay (e.g. PresentationCore)
#   ./dev-overlay.sh --restore <consumer-bin-dir>           put the original files back
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wpf_root="${repo_root}/LibreWPF"
wpf_dotnet="${wpf_root}/.dotnet/dotnet"
[[ -x "${wpf_dotnet}" ]] || { [[ -x "${wpf_dotnet}.exe" ]] && wpf_dotnet="${wpf_dotnet}.exe"; } || wpf_dotnet=dotnet

usage() {
  echo "Usage: $0 <consumer-bin-dir> <AssemblyName>... | $0 --restore <consumer-bin-dir>" >&2
  exit 1
}

restore=0
if [[ "${1:-}" == "--restore" ]]; then
  restore=1
  shift
fi
[[ $# -ge 1 ]] || usage
bin_dir="$(cd "$1" && pwd)"
shift
backup_dir="${bin_dir}/.librewpf-overlay"

if [[ "${restore}" == 1 ]]; then
  [[ -d "${backup_dir}" ]] || { echo "Nothing to restore in ${bin_dir}."; exit 0; }
  for original in "${backup_dir}"/*.dll; do
    [[ -e "${original}" ]] || continue
    cp -f "${original}" "${bin_dir}/"
    echo "restored $(basename "${original}")"
  done
  rm -rf "${backup_dir}"
  exit 0
fi
[[ $# -ge 1 ]] || usage

probe_pe_machine() {
  local off
  off="$(od -An -tu4 -j 60 -N 4 "$1" | tr -d ' ')"
  od -An -tx2 -j $((off + 4)) -N 2 "$1" | tr -d ' '
}

for name in "$@"; do
  target="${bin_dir}/${name}.dll"
  # Overlay only replaces what the consumer already loads; adding a new file would hide a
  # packaging gap that the real feed build would then expose.
  [[ -f "${target}" ]] || { echo "${target} does not exist; overlay replaces existing files only." >&2; exit 1; }
  project="$(cd "${wpf_root}" && git ls-files "src/*/${name}.csproj" "src/*/${name}/${name}.csproj" | grep -v -e '/ref/' -e '/tests/' | head -n 1)"
  [[ -n "${project}" ]] || { echo "No LibreWPF project found for ${name}." >&2; exit 1; }

  echo "== Building ${project} =="
  # The same switches dist.local.sh's local-feed lane uses for the validation graph.
  "${wpf_dotnet}" build "${wpf_root}/${project}" -c Release -v:minimal \
    -p:RunNetFrameworkApiCompat=false -p:RunRefApiCompat=false
  built="${wpf_root}/artifacts/bin/${name}/Release/net10.0/${name}.dll"
  [[ -f "${built}" ]] || { echo "The build did not produce ${built}." >&2; exit 1; }

  # A wrong-architecture managed assembly fails to load rather than falling back to JIT.
  if [[ "$(probe_pe_machine "${built}")" != "$(probe_pe_machine "${target}")" ]]; then
    echo "${name}.dll: built machine 0x$(probe_pe_machine "${built}") differs from the consumer's 0x$(probe_pe_machine "${target}"); refusing." >&2
    exit 1
  fi

  mkdir -p "${backup_dir}"
  # Keep the very first original only, so repeated overlays still restore the feed's file.
  [[ -e "${backup_dir}/${name}.dll" ]] || cp -p "${target}" "${backup_dir}/${name}.dll"
  cp -f "${built}" "${target}"
  echo "overlaid ${name}.dll (restore with: $0 --restore ${bin_dir})"
done
