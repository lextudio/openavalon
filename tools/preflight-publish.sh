#!/usr/bin/env bash
# Cheap checks of the committed submodule pointers that the publish workflow would otherwise only
# discover about 70 minutes in, at the end of the Windows/Linux native staging jobs, in
# LibreWPF/eng/progpu-wpf-canonical-winforms-integration.sh ("LibreWinForms pins ProGPU X, but LibreWPF has Y").
#
# Run it BEFORE pushing a change to LibreWPF / .gitmodules / the workflow; the workflow's first job
# runs it too and every other job waits for it. It reads the pointers recorded at HEAD of each
# repository (not whatever happens to be checked out), so it answers "what would CI check out".
#
# Needs these checked out (the workflow's preflight job initializes exactly these):
#   LibreWPF, LibreWPF/external/LibreWinForms        (and LibreWPF/external/ProGPU for the list check)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failed=0

fail() { echo "preflight: $*" >&2; failed=1; }

# The commit a repository records for a submodule path at a revision (empty when none).
gitlink() { git -C "$1" ls-tree "$2" "$3" | awk '$2 == "commit" { print $3 }'; }

librewpf="$(gitlink "$root" HEAD LibreWPF)"
[[ -n "${librewpf}" ]] || { echo "preflight: openavalon records no LibreWPF commit." >&2; exit 1; }
[[ -d "${root}/LibreWPF/.git" || -f "${root}/LibreWPF/.git" ]] || { echo "preflight: LibreWPF is not checked out (git submodule update --init LibreWPF)." >&2; exit 1; }
git -C "${root}/LibreWPF" cat-file -e "${librewpf}^{commit}" 2>/dev/null \
  || { echo "preflight: LibreWPF commit ${librewpf} is not in the checkout (not pushed to its remote, or not fetched)." >&2; exit 1; }

progpu="$(gitlink "${root}/LibreWPF" "${librewpf}" external/ProGPU)"
winforms="$(gitlink "${root}/LibreWPF" "${librewpf}" external/LibreWinForms)"
[[ -n "${progpu}" && -n "${winforms}" ]] || { echo "preflight: LibreWPF ${librewpf} records no external/ProGPU or external/LibreWinForms commit." >&2; exit 1; }

winforms_dir="${root}/LibreWPF/external/LibreWinForms"
[[ -d "${winforms_dir}/.git" || -f "${winforms_dir}/.git" ]] \
  || { echo "preflight: LibreWinForms is not checked out (git -C LibreWPF submodule update --init external/LibreWinForms)." >&2; exit 1; }
git -C "${winforms_dir}" cat-file -e "${winforms}^{commit}" 2>/dev/null \
  || { echo "preflight: LibreWinForms commit ${winforms} (pinned by LibreWPF ${librewpf}) is not in the checkout: push it to lextudio/librewinforms." >&2; exit 1; }

winforms_progpu="$(gitlink "${winforms_dir}" "${winforms}" external/ProGPU)"

echo "openavalon -> LibreWPF ${librewpf}"
echo "  LibreWPF pins ProGPU          ${progpu}"
echo "  LibreWPF pins LibreWinForms   ${winforms}"
echo "    LibreWinForms pins ProGPU   ${winforms_progpu:-missing}"

if [[ "${winforms_progpu}" != "${progpu}" ]]; then
  fail "LibreWinForms ${winforms} pins ProGPU ${winforms_progpu:-missing}, but LibreWPF ${librewpf} pins ${progpu}." \
       "The canonical WinForms integration requires them to be the same commit. Bump external/ProGPU inside LibreWinForms" \
       "(commit and push it to lextudio/librewinforms), then bump external/LibreWinForms inside LibreWPF (push), then LibreWPF here."
fi

# The package-list arrays are validated by sourcing the file (parallel id/project/purpose arrays, order).
progpu_dir="${root}/LibreWPF/external/ProGPU"
if [[ -f "${progpu_dir}/eng/progpu-package-list.sh" ]]; then
  if ! ( cd "${progpu_dir}" && source eng/progpu-package-list.sh ) >/dev/null 2>"${TMPDIR:-/tmp}/preflight-package-list.err"; then
    fail "ProGPU eng/progpu-package-list.sh does not validate: $(tr '\n' ' ' < "${TMPDIR:-/tmp}/preflight-package-list.err")"
  fi
else
  echo "preflight: LibreWPF/external/ProGPU is not checked out; skipping the package-list check." >&2
fi

if [[ "${failed}" -ne 0 ]]; then
  exit 1
fi
echo "preflight: ok"
