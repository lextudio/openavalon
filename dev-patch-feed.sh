#!/usr/bin/env bash
# Inner-loop shortcut for a consumer that restores the OpenAvalon closure from a project-local feed
# (OpenDevelop: artifacts/openavalon-feed, filled by sync-openavalon-feed.ps1 from GitHub
# Packages): rebuild individual LibreWPF assemblies and replace them inside the matching package
# in THAT feed, so one fix is tried in OpenDevelop in minutes instead of a full dist.local.sh.
#
#   ./dev-patch-feed.sh [--feed <dir>] <AssemblyName>...   build and patch (e.g. PresentationCore)
#   ./dev-patch-feed.sh [--feed <dir>] --status            list patched packages
#   ./dev-patch-feed.sh [--feed <dir>] --restore           put the original packages back
#
# Feed: --feed, else $OPENDEVELOP_FEED, else <OPENDEVELOP_ROOT or ../OpenDevelop>/artifacts/openavalon-feed.
#
# Only lib/net10.0/<Name>.dll inside the package that already ships it is replaced, and only when
# the built PE architecture matches the packaged one (a wrong-architecture managed assembly fails
# to load rather than falling back to JIT). Per-RID copies under runtimes/ cannot be built here and
# stay as published, so this patches the lane the host actually loads (macOS/Linux use lib/).
# The package's `.verified` receipt is kept on purpose: sync-openavalon-feed.ps1 then treats the
# patched file as already present and does not overwrite it (-Force does). The first original of
# every package is kept in <feed>/.patch-backup for --restore. The consumer's global NuGet cache
# entry for the patched package is dropped (the folder its NuGet.config's globalPackagesFolder names,
# else $NUGET_PACKAGES / ~/.nuget/packages), because NuGet serves the first copy it ever extracted
# for a given version string; rebuild the consumer afterwards to pick the patch up.
#
# This is local iteration ONLY. Publish through CI / dist.local.sh once the change is right.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wpf_root="${repo_root}/LibreWPF"
wpf_dotnet="${wpf_root}/.dotnet/dotnet"
[[ -x "${wpf_dotnet}" ]] || { [[ -x "${wpf_dotnet}.exe" ]] && wpf_dotnet="${wpf_dotnet}.exe"; } || wpf_dotnet=dotnet

usage() {
  echo "Usage: $0 [--feed <dir>] <AssemblyName>... | $0 [--feed <dir>] --status | $0 [--feed <dir>] --restore" >&2
  exit 1
}

for tool in unzip zip; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "dev-patch-feed.sh needs '${tool}' on PATH." >&2; exit 1; }
done

feed="${OPENDEVELOP_FEED:-}"
mode=patch
names=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feed) [[ $# -ge 2 ]] || usage; feed="$2"; shift 2 ;;
    --status) mode=status; shift ;;
    --restore) mode=restore; shift ;;
    -h|--help) usage ;;
    -*) echo "Unknown option $1" >&2; usage ;;
    *) names+=("$1"); shift ;;
  esac
done
if [[ -z "${feed}" ]]; then
  feed="${OPENDEVELOP_ROOT:-${repo_root}/../OpenDevelop}/artifacts/openavalon-feed"
fi
[[ -d "${feed}" ]] || { echo "Feed directory ${feed} does not exist (run OpenDevelop's sync-openavalon-feed.ps1 first)." >&2; exit 1; }
feed="$(cd "${feed}" && pwd)"
backup_dir="${feed}/.patch-backup"

# The consumer's global packages folder(s) the patched package must be dropped from. A consumer that
# sets <add key="globalPackagesFolder" value="..."/> in the NuGet.config next to its feed's artifacts
# directory (OpenDevelop: artifacts/nuget-packages) extracts there, so clearing only
# ~/.nuget/packages would leave the stale copy NuGet keeps serving for a version string. The user
# folder ($NUGET_PACKAGES or ~/.nuget/packages) is cleared too; it is harmless when absent.
nuget_roots=("${NUGET_PACKAGES:-${HOME}/.nuget/packages}")
consumer_root="$(cd "${feed}/../.." 2>/dev/null && pwd || true)"
consumer_config="${consumer_root}/NuGet.config"
if [[ -n "${consumer_root}" && -f "${consumer_config}" ]]; then
  # `{p;q;}` stops at the first match (a pipe into `head -n 1` can SIGPIPE sed and, under pipefail,
  # abort the script when two lines match).
  configured="$(sed -n '/key="globalPackagesFolder"/{s:.*value="\([^"]*\)".*:\1:;p;q;}' "${consumer_config}")"
  configured="${configured//\\//}"
  if [[ -n "${configured}" ]]; then
    case "${configured}" in
      /*|[A-Za-z]:*) nuget_roots+=("${configured}") ;;
      *) nuget_roots+=("${consumer_root}/${configured}") ;;
    esac
  fi
fi

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# "<Id>.<Version>.nupkg" -> Id and Version, using the nuspec the package carries.
package_id_version() {
  local nuspec
  nuspec="$(unzip -p "$1" '*.nuspec' 2>/dev/null | head -c 20000)"
  local id version
  id="$(printf '%s' "${nuspec}" | sed -n 's:.*<id>\([^<]*\)</id>.*:\1:p' | head -n 1)"
  version="$(printf '%s' "${nuspec}" | sed -n 's:.*<version>\([^<]*\)</version>.*:\1:p' | head -n 1)"
  printf '%s %s' "${id}" "${version}"
}

drop_cache() {
  local id version dir
  read -r id version <<<"$(package_id_version "$1")"
  [[ -n "${id}" && -n "${version}" ]] || return 0
  local root dir
  for root in "${nuget_roots[@]}"; do
    dir="${root}/$(lower "${id}")/$(lower "${version}")"
    if [[ -d "${dir}" ]]; then rm -rf "${dir}"; echo "dropped global cache ${dir}"; fi
  done
}

probe_pe_machine() {
  local off
  off="$(od -An -tu4 -j 60 -N 4 "$1" | tr -d ' ')"
  od -An -tx2 -j $((off + 4)) -N 2 "$1" | tr -d ' '
}

if [[ "${mode}" == status ]]; then
  [[ -d "${backup_dir}" ]] || { echo "No patched packages in ${feed}."; exit 0; }
  for original in "${backup_dir}"/*.nupkg; do
    [[ -e "${original}" ]] || continue
    echo "patched: $(basename "${original}")"
  done
  exit 0
fi

if [[ "${mode}" == restore ]]; then
  [[ -d "${backup_dir}" ]] || { echo "Nothing to restore in ${feed}."; exit 0; }
  for original in "${backup_dir}"/*.nupkg; do
    [[ -e "${original}" ]] || continue
    cp -f "${original}" "${feed}/"
    drop_cache "${original}"
    echo "restored $(basename "${original}")"
  done
  rm -rf "${backup_dir}"
  exit 0
fi

[[ ${#names[@]} -ge 1 ]] || usage

work="$(mktemp -d "${TMPDIR:-/tmp}/dev-patch-feed.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

for name in "${names[@]}"; do
  project="$(cd "${wpf_root}" && git ls-files "src/*/${name}.csproj" "src/*/${name}/${name}.csproj" | grep -v -e '/ref/' -e '/tests/' | head -n 1)"
  [[ -n "${project}" ]] || { echo "No LibreWPF project found for ${name}." >&2; exit 1; }

  # The package that already ships lib/net10.0/<name>.dll. Replacing only an existing entry keeps
  # a packaging gap visible to the real feed build instead of hiding it.
  entry="lib/net10.0/${name}.dll"
  package=""
  for candidate in "${feed}"/*.nupkg; do
    [[ -e "${candidate}" ]] || continue
    if unzip -Z1 "${candidate}" "${entry}" >/dev/null 2>&1; then package="${candidate}"; break; fi
  done
  [[ -n "${package}" ]] || { echo "No package in ${feed} contains ${entry}." >&2; exit 1; }

  echo "== Building ${project} =="
  "${wpf_dotnet}" build "${wpf_root}/${project}" -c Release -v:minimal \
    -p:RunNetFrameworkApiCompat=false -p:RunRefApiCompat=false
  built="${wpf_root}/artifacts/bin/${name}/Release/net10.0/${name}.dll"
  [[ -f "${built}" ]] || built="${wpf_root}/$(dirname "${project}")/bin/Release/net10.0/${name}.dll"
  [[ -f "${built}" ]] || { echo "The build did not produce ${name}.dll in artifacts/bin or the project's bin." >&2; exit 1; }

  rm -rf "${work:?}/pkg"; mkdir -p "${work}/pkg"
  unzip -q -o "${package}" "${entry}" -d "${work}/pkg"
  if [[ "$(probe_pe_machine "${built}")" != "$(probe_pe_machine "${work}/pkg/${entry}")" ]]; then
    echo "${name}.dll: built machine 0x$(probe_pe_machine "${built}") differs from the package's 0x$(probe_pe_machine "${work}/pkg/${entry}"); refusing." >&2
    exit 1
  fi

  mkdir -p "${backup_dir}"
  # Keep the very first original only, so repeated patches still restore the published file.
  [[ -e "${backup_dir}/$(basename "${package}")" ]] || cp -p "${package}" "${backup_dir}/$(basename "${package}")"

  cp -f "${built}" "${work}/pkg/${entry}"
  ( cd "${work}/pkg" && zip -q "${package}" "${entry}" )
  drop_cache "${package}"
  echo "patched $(basename "${package}"): ${entry}"
done

echo "Rebuild the consumer to pick it up; undo with: $0 --feed ${feed} --restore"
