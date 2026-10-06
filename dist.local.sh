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
# The feed is built for the host: Git for Windows Bash prepares the Windows release feed
# (win-x64 + win-arm64), macOS prepares the Apple silicon feed (osx-arm64). 'all' is the
# upstream every-RID lane and needs natively staged binaries for every platform.
case "$(uname -s)" in
  Darwin) host_platform=macos ;;
  MINGW*|MSYS*|CYGWIN*) host_platform=windows ;;
  *) host_platform=all ;;
esac
target_platform="${DIST_LOCAL_TARGET_PLATFORM:-${host_platform}}"

# Expensive stages whose inputs have not changed since their last successful run are skipped
# (see "Stage receipts" below). --force, or DIST_LOCAL_FORCE=1, rebuilds everything.
force_rebuild="${DIST_LOCAL_FORCE:-0}"
for argument in "$@"; do
  case "${argument}" in
    --force) force_rebuild=1 ;;
    *) echo "Unknown argument '${argument}'. Usage: $0 [--force]" >&2; exit 1 ;;
  esac
done

# Versions match the newest release on nuget.org (LibreWPF/LibreWinForms and ProGPU ship
# together at the same number). Update both lines when nuget.org moves on.
dev_package_version="0.1.0-preview.65"
progpu_package_version="0.1.0-preview.65"
for version in "${dev_package_version}" "${progpu_package_version}"; do
  if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z.]+$ ]]; then
    echo "Invalid package version '${version}'." >&2
    exit 1
  fi
done

# section <title>: prints the stage banner and closes the previous stage's timer; the EXIT trap
# prints the whole table, so a slow run says where its time went. SECONDS is a builtin - no fork.
section_titles=()
section_seconds=()
section_started=${SECONDS}
section() {
  if [[ ${#section_titles[@]} -gt 0 ]]; then
    section_seconds+=($((SECONDS - section_started)))
  fi
  section_titles+=("$1")
  section_started=${SECONDS}
  echo "== $1 =="
}
print_section_times() {
  local i
  [[ ${#section_titles[@]} -gt 0 ]] || return 0
  section_seconds+=($((SECONDS - section_started)))
  echo "== Stage times (total $((SECONDS / 60))m$((SECONDS % 60))s) =="
  for i in "${!section_titles[@]}"; do
    printf '  %4dm%02ds  %s\n' $((section_seconds[i] / 60)) $((section_seconds[i] % 60)) "${section_titles[i]}"
  done
}

section "Package versions:LibreWPF/LibreWinForms ${dev_package_version}, ProGPU ${progpu_package_version}"

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

if [[ "${target_platform}" == "macos" ]]; then
  if [[ "$(uname -m)" != "arm64" ]]; then
    echo "The macOS feed targets Apple silicon (osx-arm64) only; run it on an arm64 Mac." >&2
    exit 1
  fi
  # LibreWPF.Sdk links a small C shim. The default Command Line Tools SDK fails that link with
  # "ld: tapi error: malformed file / unknown architecture", so pin a known-good SDK when the
  # caller has not chosen one.
  if [[ -z "${SDKROOT:-}" ]]; then
    for candidate in MacOSX26.5.sdk MacOSX26.sdk; do
      if [[ -d "/Library/Developer/CommandLineTools/SDKs/${candidate}" ]]; then
        export SDKROOT="/Library/Developer/CommandLineTools/SDKs/${candidate}"
        break
      fi
    done
  fi
fi

run_wpf_msbuild() {
  if [[ "${target_platform}" == "windows" ]]; then
    # One node by default: concurrent native projects were what exhausted memory around the
    # System.Printing PCH (CL=/MP1 above does not parallelize anything - no project enables /MP).
    # DIST_LOCAL_WINDOWS_MSBUILD_NODES raises it on a workstation with the memory to spare.
    "${wpf_msbuild}" "$@" \
      -m:"${DIST_LOCAL_WINDOWS_MSBUILD_NODES:-1}" \
      -property:Platform=x64 \
      -property:IjwHostSourcePath="${wpf_root}/.dotnet/packs/Microsoft.NETCore.App.Host.win-x64/11.0.0-preview.7.26381.103/runtimes/win-x64/native/ijwhost.dll"
  else
    "${wpf_dotnet}" msbuild "$@"
  fi
}

# ---------------------------------------------------------------------------------------------
# Stage receipts. A stage records a fingerprint of everything it consumed plus the files it
# produced; the next run skips the stage when the fingerprint is identical and every recorded
# file still exists. Fingerprints come from git (HEAD tree, uncommitted diff, untracked file
# contents) and from content hashes of staged native payloads - never from timestamps - so a
# checkout that merely touched files does not rebuild, and any real change does. A stage's
# receipt is deleted before it runs, so a failed run can never leave a receipt that matches.
receipts_dir="${repo_root}/artifacts/dist-receipts"

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

# repo_fingerprint <repo> [pathspec...]: the repository's state under the pathspecs (all of it
# when none are given).
repo_fingerprint() {
  local repo="$1" path untracked
  shift
  untracked="$(git -C "${repo}" ls-files -o --exclude-standard -- "$@")"
  {
    if [[ $# -eq 0 ]]; then
      git -C "${repo}" rev-parse 'HEAD^{tree}'
    else
      for path in "$@"; do
        git -C "${repo}" rev-parse "HEAD:${path}" 2>/dev/null || echo "absent:${path}"
      done
    fi
    # Submodules are fingerprinted on their own; =dirty keeps their recorded commit here but skips
    # scanning their work trees, which cost ~20 s per call on LibreWPF.
    git -C "${repo}" diff --no-ext-diff --binary --ignore-submodules=dirty HEAD -- "$@"
    if [[ -n "${untracked}" ]]; then
      printf '%s\n' "${untracked}"
      printf '%s\n' "${untracked}" | git -C "${repo}" hash-object --stdin-paths
    fi
  } | sha256_stdin
}

# files_fingerprint <dir...>: names and contents of every file under the directories.
files_fingerprint() {
  local dir files git_dir
  for dir in "$@"; do
    if [[ ! -d "${dir}" ]]; then
      echo "absent:${dir}"
      continue
    fi
    # One git process per directory, not per file: process creation is slow on Windows.
    # --stdin-paths resolves relative paths against the repository root, and Git for Windows
    # does not translate /c/... paths read from stdin, so hand it absolute native paths.
    files="$(cd "${dir}" && find . -type f | LC_ALL=C sort)"
    [[ -n "${files}" ]] || continue
    git_dir="${dir}"
    if command -v cygpath >/dev/null 2>&1; then git_dir="$(cygpath -m "${dir}")"; fi
    paste -d' ' <(printf '%s\n' "${files}") \
      <(printf '%s\n' "${files}" | sed "s|^\./|${git_dir}/|" | git hash-object --stdin-paths)
  done | sha256_stdin
}

stage_receipt() { printf '%s/%s.receipt' "${receipts_dir}" "$1"; }

# stage_is_current <name> <fingerprint>
stage_is_current() {
  local receipt file
  receipt="$(stage_receipt "$1")"
  [[ "${force_rebuild}" != 1 && -f "${receipt}" ]] || return 1
  [[ "$(head -n 1 "${receipt}")" == "$2" ]] || return 1
  while IFS= read -r file; do
    [[ -s "${file}" ]] || return 1
  done < <(tail -n +2 "${receipt}")
  echo "  $1: inputs unchanged since its last successful run, reusing its output (--force rebuilds)."
}

# record_stage <name> <fingerprint> <produced file...>
record_stage() {
  local receipt
  receipt="$(stage_receipt "$1")"
  mkdir -p "${receipts_dir}"
  { printf '%s\n' "$2"; shift 2; printf '%s\n' "$@"; } > "${receipt}"
}

invalidate_stage() { rm -f "$(stage_receipt "$1")"; }

# ---------------------------------------------------------------------------------------------
# The feed is only ever changed by moving the previously published file aside first. If the run
# fails, every package this run wrote is removed and the previous ones are put back, so a failed
# run leaves the feed exactly as it was instead of without the version being republished.
feed_backup="${repo_root}/artifacts/local-feed-backup"
run_marker="${repo_root}/artifacts/.dist-local-run"
rm -rf "${feed_backup}"
mkdir -p "${feed_backup}"
touch "${run_marker}"
publish_succeeded=0

# retire_feed_files <file...>: move published files aside (the first copy seen in this run is the
# one restored on failure; anything this run itself wrote is simply deleted).
retire_feed_files() {
  local file
  for file in "$@"; do
    [[ -e "${file}" ]] || continue
    if [[ "${file}" -nt "${run_marker}" || -e "${feed_backup}/$(basename "${file}")" ]]; then
      rm -f "${file}"
    else
      mv -f "${file}" "${feed_backup}/"
    fi
  done
}

restore_feed_on_failure() {
  local file restored=0
  print_section_times
  if [[ "${publish_succeeded}" == 1 ]]; then
    rm -rf "${feed_backup}" "${run_marker}"
    return
  fi
  shopt -s nullglob
  for file in "${local_feed}"/*.nupkg "${local_feed}"/*.snupkg; do
    [[ "${file}" -nt "${run_marker}" ]] && rm -f "${file}"
  done
  for file in "${feed_backup}"/*; do
    mv -f "${file}" "${local_feed}/"
    restored=$((restored + 1))
  done
  shopt -u nullglob
  echo "== Run failed: removed this run's packages and restored ${restored} previously published file(s) in ${local_feed} ==" >&2
}
trap restore_feed_on_failure EXIT

pack_wpf_project() {
  local project="$1"
  local package_id="$2"
  local package_version="$3"
  shift 3
  # Remaining arguments are extra MSBuild properties for this one pack.
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
  retire_feed_files \
    "${local_feed}/${package_id}.${package_version}.nupkg" \
    "${local_feed}/${package_id}.${package_version}.snupkg"
  "${wpf_dotnet}" pack "${wpf_root}/${project}" \
    -c Release \
    -o "${local_feed}" \
    -v:minimal \
    -p:Version="${package_version}" \
    -p:PackageVersion="${package_version}" \
    "$@" \
    $([[ "${target_platform}" == "windows" ]] && echo "-p:Platform=${pack_platform} -p:IjwHostSourcePath=${wpf_root}/.dotnet/packs/Microsoft.NETCore.App.Host.win-x64/11.0.0-preview.7.26381.103/runtimes/win-x64/native/ijwhost.dll")
  # A skipped pack target still exits 0, so the exit code alone cannot tell a
  # real pack from one that produced nothing.  Verify the artifact instead.
  if [[ ! -f "${local_feed}/${package_id}.${package_version}.nupkg" ]]; then
    echo "pack produced no ${package_id}.${package_version}.nupkg from ${project}." >&2
    echo "Check IsPackable/CreateArchNeutralPackage for Platform=${pack_platform}." >&2
    exit 1
  fi
}

# pack_wpf_projects_nobuild <version> <project:package-id...>: pack_wpf_project with --no-build
# and PlatformTarget=AnyCPU for every pair, in ONE MSBuild process instead of one `dotnet pack`
# each (~3.5 s apiece, mostly process start and evaluation). --no-build implies --no-restore, so
# a traversal project calling Pack is all `dotnet pack` would have done; global properties flow to
# every project the same as on the per-project command line.
pack_wpf_projects_nobuild() {
  local package_version="$1" pair traversal items="" native_root="${wpf_root}" native_feed="${local_feed}"
  shift
  if command -v cygpath >/dev/null 2>&1; then
    native_root="$(cygpath -m "${wpf_root}")"
    native_feed="$(cygpath -m "${local_feed}")"
  fi
  [[ $# -gt 0 ]] || return 0
  for pair in "$@"; do
    retire_feed_files \
      "${local_feed}/${pair##*:}.${package_version}.nupkg" \
      "${local_feed}/${pair##*:}.${package_version}.snupkg"
    items+="    <PackProject Include=\"${native_root}/${pair%%:*}\" />"$'\n'
  done
  traversal="$(mktemp -d)/pack-nobuild.proj"
  cat > "${traversal}" <<EOF
<Project>
  <ItemGroup>
${items}  </ItemGroup>
  <Target Name="Pack">
    <MSBuild Projects="@(PackProject)" Targets="Pack" BuildInParallel="false" />
  </Target>
</Project>
EOF
  "${wpf_dotnet}" msbuild "${traversal}" \
    -target:Pack \
    -verbosity:minimal \
    -property:Configuration=Release \
    -property:NoBuild=true \
    -property:_IsPacking=true \
    -property:PackageOutputPath="${native_feed}/" \
    -property:Version="${package_version}" \
    -property:PackageVersion="${package_version}" \
    -property:PlatformTarget=AnyCPU \
    $([[ "${target_platform}" == "windows" ]] && echo "-property:Platform=AnyCPU -property:IjwHostSourcePath=${wpf_root}/.dotnet/packs/Microsoft.NETCore.App.Host.win-x64/11.0.0-preview.7.26381.103/runtimes/win-x64/native/ijwhost.dll")
  rm -rf "$(dirname "${traversal}")"
  for pair in "$@"; do
    if [[ ! -f "${local_feed}/${pair##*:}.${package_version}.nupkg" ]]; then
      echo "pack produced no ${pair##*:}.${package_version}.nupkg from ${pair%%:*}." >&2
      exit 1
    fi
  done
}

# ProGPU.Backend.Native packages the platform-native renderer rather than building it as a
# side effect of `dotnet pack`.  The package project validates the staged payload before Pack,
# so prepare both Windows slices first.  Keeping this here (before progpu-pack.sh) makes the
# local-feed lane self-contained and prevents a clean checkout from silently depending on an
# earlier developer build's artifacts/progpu-native tree.
if [[ "${target_platform}" == "windows" ]]; then
  section "Staging ProGPU native Windows runtimes"
  for rid in win-x64 win-arm64; do
    native_stage="native-${rid}"
    native_staged=()
    for native_dll in progpu_native.dll progpu_native_dawn.dll progpu_native_direct2d.dll; do
      native_staged+=("${progpu_root}/artifacts/progpu-native/package/runtimes/${rid}/native/${native_dll}")
    done
    # The renderer is compiled from src/ProGPU.Native; the builder script pins wgpu-native and the
    # headers itself, and the export list is the managed/native contract.
    native_fingerprint="$({ echo "${rid} MSVC"
      repo_fingerprint "${progpu_root}" src/ProGPU.Native eng/build-progpu-native-windows.ps1 eng/progpu-native-exports.txt \
        eng/progpu-native-wgpu.version.json
    } | sha256_stdin)"
    if stage_is_current "${native_stage}" "${native_fingerprint}"; then
      continue
    fi
    invalidate_stage "${native_stage}"
    # The Windows native builder uses a RID-fixed CMake build directory.  It may
    # retain a compiler choice from an interactive ClangCL attempt; this feed
    # explicitly uses the installed MSVC toolchain, so do not reuse that cache.
    rm -rf "${progpu_root}/artifacts/progpu-native/build-${rid}"
    pwsh -NoProfile -File "${progpu_root}/eng/build-progpu-native-windows.ps1" \
      -Rid "${rid}" \
      -Compiler MSVC \
      -BuildOnly
    for staged in "${native_staged[@]}"; do
      if [[ ! -s "${staged}" ]]; then
        echo "The ProGPU native staging step did not produce ${rid}/$(basename "${staged}")." >&2
        exit 1
      fi
    done
    record_stage "${native_stage}" "${native_fingerprint}" "${native_staged[@]}"
  done

  # ProGPU.Backend.Dx12 carries a separately-built WGPU/DXC runtime.  Its
  # production builder verifies the pinned Rust dependency, signed compiler
  # package, binary hashes, PE architecture, and provenance receipts before
  # staging.  An ARM64 host needs an x64 PowerShell/Rust toolchain for the x64
  # slice; accept those explicitly rather than silently building a host slice.
  #
  # Git for Windows Bash is an x64 process, so under emulation on an ARM64 host
  # its PROCESSOR_ARCHITECTURE reads AMD64.  Ask the registry for the native one.
  host_native_arch="$(MSYS2_ARG_CONV_EXCL='*' reg query \
    'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' \
    /v PROCESSOR_ARCHITECTURE 2>/dev/null | awk '/PROCESSOR_ARCHITECTURE/ { print $NF }')"
  # Toolchains isolated under artifacts/tools/{pwsh-x64,rustup-<arch>} are used
  # when present and no explicit override is given.
  tools_root="${repo_root}/artifacts/tools"
  section "Staging ProGPU DX12 Windows runtimes (host ${host_native_arch:-unknown})"
  for rid in win-x64 win-arm64; do
    arch="${rid#win-}"
    arch_upper="$(tr '[:lower:]' '[:upper:]' <<<"${arch}")"
    tool_rustup="${tools_root}/rustup-${arch}"
    dx12_pwsh_var="PROGPU_WPF_${arch_upper}_PWSH"
    rustup_bin_var="PROGPU_WPF_${arch_upper}_RUSTUP_BIN"
    rustup_home_var="PROGPU_WPF_${arch_upper}_RUSTUP_HOME"
    cargo_home_var="PROGPU_WPF_${arch_upper}_CARGO_HOME"
    dx12_pwsh="${!dx12_pwsh_var:-pwsh}"
    if [[ "${rid}" == "win-x64" && "${host_native_arch}" == "ARM64" && -z "${!dx12_pwsh_var:-}" ]]; then
      dx12_pwsh="${tools_root}/pwsh-x64/runtime/pwsh.exe"
      if [[ ! -x "${dx12_pwsh}" ]]; then
        echo "win-x64 DX12 staging on ARM64 needs an x64 pwsh: set ${dx12_pwsh_var} or install one at ${dx12_pwsh}." >&2
        exit 1
      fi
    fi
    rustup_bin="${!rustup_bin_var:-}"
    rustup_home="${!rustup_home_var:-${RUSTUP_HOME:-}}"
    cargo_home="${!cargo_home_var:-${CARGO_HOME:-}}"
    if [[ -z "${rustup_bin}" && -x "${tool_rustup}/cargo-home/bin/rustup.exe" ]]; then
      rustup_bin="${tool_rustup}/cargo-home/bin"
      rustup_home="${!rustup_home_var:-${tool_rustup}/rustup-home}"
      cargo_home="${!cargo_home_var:-${tool_rustup}/cargo-home}"
    fi
    if [[ -z "${rustup_bin}" ]] && ! command -v rustup >/dev/null 2>&1; then
      echo "DX12 ${rid} staging needs rustup: set ${rustup_bin_var} or install one under ${tool_rustup}." >&2
      exit 1
    fi
    # PATH is translated for native children by MSYS; the other two are not.
    dx12_environment=("PATH=${rustup_bin:+$(cygpath -u "${rustup_bin}"):}${PATH}")
    [[ -n "${rustup_home}" ]] && dx12_environment+=("RUSTUP_HOME=$(cygpath -w "${rustup_home}")")
    [[ -n "${cargo_home}" ]] && dx12_environment+=("CARGO_HOME=$(cygpath -w "${cargo_home}")")
    dx12_staged="${progpu_root}/artifacts/progpu-dx12/package/${rid}/native"
    dx12_stage="dx12-${rid}"
    # Every input is pinned under eng/: the JSON pins (dependency, compiler, libclang) and the
    # scripts that verify and stage them. The toolchain choice is part of the fingerprint too.
    dx12_fingerprint="$({ echo "${rid} ${dx12_pwsh} ${rustup_bin}"
      repo_fingerprint "${progpu_root}" eng/wgpu-dxc eng/build-progpu-dx12-runtime-windows.ps1 \
        eng/build-wgpu-native-windows.ps1 eng/stage-wgpu-libclang.ps1 eng/stage-dxc-compiler.ps1 \
        eng/stage-dx12-runtime.ps1 eng/progpu-native-wgpu.version.json
    } | sha256_stdin)"
    dx12_files=()
    for dx12_file in wgpu_native.dll dxcompiler.dll dxil.dll progpu-dx12-runtime.json; do
      dx12_files+=("${dx12_staged}/${dx12_file}")
    done
    if stage_is_current "${dx12_stage}" "${dx12_fingerprint}"; then
      continue
    fi
    invalidate_stage "${dx12_stage}"
    # Every stage refuses an existing output directory ("must be a new directory"), so clear
    # them all.  download/ (pinned archives) and artifacts/wgpu-native-windows (the cargo
    # target) are caches the builder verifies, and keep a rerun incremental.
    for dx12_output in libclang dependency compiler package; do
      rm -rf "${progpu_root}/artifacts/progpu-dx12/${dx12_output}/${rid}"
    done
    env "${dx12_environment[@]}" \
      "${dx12_pwsh}" -NoProfile -File "${progpu_root}/eng/build-progpu-dx12-runtime-windows.ps1" -Rid "${rid}"
    # Same lesson as the managed runtime step below: do not trust pwsh's exit code alone.
    for dx12_file in wgpu_native.dll dxcompiler.dll dxil.dll progpu-dx12-runtime.json; do
      if [[ ! -s "${dx12_staged}/${dx12_file}" ]]; then
        echo "The ProGPU DX12 staging step did not produce ${rid}/${dx12_file}." >&2
        exit 1
      fi
    done
    if ! grep -Fq "\"rid\": \"${rid}\"" "${dx12_staged}/progpu-dx12-runtime.json"; then
      echo "The staged DX12 runtime receipt for ${rid} names a different RID." >&2
      exit 1
    fi
    record_stage "${dx12_stage}" "${dx12_fingerprint}" "${dx12_files[@]}"
  done
fi

# The feed accumulates versions on purpose so older pins keep restoring, but a re-run of the
# same version must not trip the package-group verifier: progpu-verify-packages.sh scans the
# output directory for artifacts of the version being built and rejects any package the
# selected group does not own, so packages left behind by an earlier run of the same version
# look like unexpected output and abort the build. Clear the version being published so each
# run starts from a clean slate for it. Other versions stay in place.
# The macOS lane does not build the ProGPU native renderer; it reuses whatever sits in
# artifacts/progpu-native/package/runtimes/osx-arm64/native and passes
# ProGpuNativeSkipRuntimeValidation=true when packing ProGPU.Backend.Native. Nothing above
# proves that payload matches the managed code, so a stale dylib packs and publishes
# cleanly and fails only at runtime, as an EntryPointNotFoundException from a managed call
# into a native export that was added since the payload was built. Verify the exported
# symbol allowlist before packing so the mismatch stops here instead.
if [[ "${target_platform}" == "macos" ]]; then
  native_dir="${progpu_root}/artifacts/progpu-native/package/runtimes/osx-arm64/native"
  if [[ ! -s "${native_dir}/libprogpu_native.dylib" ]]; then
    echo "The ProGPU osx-arm64 native payload is missing: ${native_dir}/libprogpu_native.dylib" >&2
    echo "Build it first: ${progpu_root}/eng/build-progpu-native.sh --build-only --rid osx-arm64" >&2
    exit 1
  fi
  PROGPU_NATIVE_BUILD_DIR="${native_dir}" \
    "${progpu_root}/eng/progpu-verify-native-exports.sh"
fi

# The whole ProGPU packaging stage (progpu-pack.sh plus the loop below) is skipped when ProGPU's
# sources, the staged native payloads it packs and the requested versions are all unchanged; the
# packages it published last time are then still in the feed and are left exactly as they are.
progpu_package_group="${PROGPU_PACKAGE_GROUP:-$([[ "${target_platform}" == "macos" ]] && echo opendevelop-macos || echo portable)}"
if [[ "${target_platform}" == "macos" ]]; then
  progpu_native_payloads=("${progpu_root}/artifacts/progpu-native/package/runtimes/osx-arm64/native")
else
  progpu_native_payloads=("${progpu_root}/artifacts/progpu-native/package" "${progpu_root}/artifacts/progpu-dx12/package")
fi
progpu_pack_fingerprint="$({
  echo "${progpu_package_version} ${dev_package_version} ${progpu_package_group} ${target_platform}"
  echo "${PROGPU_PACKAGE_WINDOWS_ONLY} ${ProGpuNativePackageWindowsOnly} $("${wpf_dotnet}" --version)"
  repo_fingerprint "${progpu_root}"
  files_fingerprint "${progpu_native_payloads[@]}"
} | sha256_stdin)"
progpu_pack_current=0
if stage_is_current progpu-packages "${progpu_pack_fingerprint}"; then
  progpu_pack_current=1
fi

if [[ "${progpu_pack_current}" == 0 ]]; then
invalidate_stage progpu-packages
section "Clearing ${progpu_package_version} packages from the local feed"
shopt -s nullglob
retire_feed_files "${local_feed}"/*."${progpu_package_version}".nupkg "${local_feed}"/*."${progpu_package_version}".snupkg \
  "${local_feed}"/*."${dev_package_version}".nupkg "${local_feed}"/*."${dev_package_version}".snupkg
shopt -u nullglob

section "Packing ProGPU packages"
PROGPU_PACKAGE_VERSION="${progpu_package_version}" \
PROGPU_PACKAGE_OUTPUT="${local_feed}" \
PROGPU_PACKAGE_GROUP="${progpu_package_group}" \
  "${progpu_root}/eng/progpu-pack.sh"

section "Packing the ProGPU projects LibreWPF.Sdk depends on"
nobuild_pack_pairs=()
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
  # These overwrite the verified progpu-pack.sh output of the same id and version, so pin the
  # PE machine field the same way progpu-pack.sh does: Platform alone does not stamp it.
  #
  # progpu-pack.sh already built and packed this project a moment ago, at the same id and version
  # and with the same AnyCPU pin, so reuse that build instead of compiling it a second time. Only
  # ProGPU.Avalonia and ProGPU.DirectX are outside the opendevelop-macos group; they are the only
  # ones that still have to build here. Keep the pack itself, because the package must be
  # republished with this loop's properties.
  if [[ "${package_id}" != "ProGPU.Avalonia" && "${package_id}" != "ProGPU.DirectX" ]]; then
    nobuild_pack_pairs+=("${pair}")
    continue
  fi
  pack_wpf_project "${project}" "${package_id}" "${progpu_package_version}" -p:PlatformTarget=AnyCPU
done
pack_wpf_projects_nobuild "${progpu_package_version}" "${nobuild_pack_pairs[@]}"

progpu_published=()
while IFS= read -r published; do
  progpu_published+=("${published}")
done < <(find "${local_feed}" -maxdepth 1 -type f -newer "${run_marker}" \
  \( -name "*.${progpu_package_version}.nupkg" -o -name "*.${progpu_package_version}.snupkg" \) | LC_ALL=C sort)
record_stage progpu-packages "${progpu_pack_fingerprint}" "${progpu_published[@]}"
fi

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
  section "Producing the per-RID Windows managed runtime payload"
  # A dozen Arcade builds; skipped when every tree it compiles from is unchanged. System.Private.
  # Windows.Core comes from LibreWinForms and the interop from ProGPU, so all three trees count.
  managed_runtime_dir="${wpf_root}/artifacts/windows-managed-runtime"
  managed_runtime_fingerprint="$({
    echo "Release $("${wpf_dotnet}" --version)"
    repo_fingerprint "${wpf_root}"
    repo_fingerprint "${winforms_root}"
    repo_fingerprint "${progpu_root}"
  } | sha256_stdin)"
  if ! stage_is_current managed-runtime "${managed_runtime_fingerprint}"; then
    invalidate_stage managed-runtime
    pwsh -NoProfile -File "${wpf_root}/eng/progpu-wpf-windows-managed-runtime.ps1" -Configuration Release
    managed_runtime_files=()
    while IFS= read -r staged; do
      managed_runtime_files+=("${staged}")
    done < <(find "${managed_runtime_dir}" -type f -name '*.dll' | LC_ALL=C sort)
  fi
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
  # Recorded only after the payload checks above pass.
  if [[ -n "${managed_runtime_files+x}" ]]; then
    record_stage managed-runtime "${managed_runtime_fingerprint}" "${managed_runtime_files[@]}"
  fi
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
  section "Clearing stale LibreWPF.Transport staging payload"
  rm -rf "${transport_staging}/lib" "${transport_staging}/ref"
fi

# canonical_feed is the one librewinforms-pack.sh qualifies against. On Windows it is the ARM64
# slice, and the x64 peer is built beside it: WindowsFormsIntegration is C++/CLI, and OpenDevelop's
# patch-librewinforms-deps.ps1 takes both feeds (-WindowsArm64PackageRoot / -WindowsX64PackageRoot)
# to fill runtimes/win-arm64 and runtimes/win-x64. On macOS the graph is built without a platform
# (portable AnyCPU managed code, which runs natively on Apple silicon).
canonical_feed="${DIST_LOCAL_CANONICAL_WINFORMS_FEED:-${repo_root}/artifacts/canonical-winforms-feed}"
canonical_feed_x64="${DIST_LOCAL_CANONICAL_WINFORMS_FEED_X64:-${repo_root}/artifacts/canonical-winforms-feed-x64}"

# Canonical WinForms is built from all three trees (WindowsFormsIntegration from LibreWPF, the
# WinForms packages from LibreWinForms, both against ProGPU), so any change in any of them
# rebuilds it; an unchanged slice keeps its private feed directory from the last run.
canonical_sources_fingerprint="$({
  echo "${dev_package_version} ${progpu_package_version} ${PROGPU_WPF_RUN_DRAWING_QUALITY_GATES:-0}"
  repo_fingerprint "${wpf_root}"
  repo_fingerprint "${winforms_root}"
  repo_fingerprint "${progpu_root}"
  files_fingerprint "${progpu_native_payloads[@]}"
} | sha256_stdin)"

build_canonical_winforms_slice() {
  local output="$1" platform="$2" stage fingerprint produced=()
  stage="canonical-winforms-${platform:-anycpu}"
  fingerprint="$(printf '%s %s\n' "${canonical_sources_fingerprint}" "${platform}" | sha256_stdin)"
  if stage_is_current "${stage}" "${fingerprint}"; then
    return 0
  fi
  invalidate_stage "${stage}"
  rm -rf "${output}"
  PROGPU_WPF_CANONICAL_WINFORMS_PACKAGE_OUTPUT="${output}" \
  PROGPU_WPF_CANONICAL_WINFORMS_PACKAGE_VERSION="${dev_package_version}" \
  PROGPU_WPF_CANONICAL_PROGPU_PACKAGE_VERSION="${progpu_package_version}" \
  PROGPU_WPF_CANONICAL_WINFORMS_PLATFORM="${platform}" \
  DOTNET_INSTALL_DIR="${wpf_root}/.dotnet" \
  PROGPU_WPF_RUN_DRAWING_QUALITY_GATES="${PROGPU_WPF_RUN_DRAWING_QUALITY_GATES:-0}" \
    "${wpf_root}/eng/progpu-wpf-canonical-winforms-integration.sh"
  shopt -s nullglob
  produced=("${output}"/*.nupkg)
  shopt -u nullglob
  if [[ "${#produced[@]}" -eq 0 ]]; then
    echo "The canonical WinForms build produced no packages in ${output}." >&2
    exit 1
  fi
  record_stage "${stage}" "${fingerprint}" "${produced[@]}"
}

build_canonical_winforms() {
  if [[ "${target_platform}" == "windows" ]]; then
    # x64 first so the ARM64 slice, which the rest of this run consumes, is built last.
    build_canonical_winforms_slice "${canonical_feed_x64}" x64
    build_canonical_winforms_slice "${canonical_feed}" ARM64
  else
    build_canonical_winforms_slice "${canonical_feed}" "${PROGPU_WPF_CANONICAL_WINFORMS_PLATFORM:-}"
  fi
}

section "Building the LibreWPF managed transport and theme payload"
# On macOS the canonical WinForms integration graph must run before the transport build.
if [[ "${target_platform}" == "macos" ]]; then
  build_canonical_winforms
fi
# Restore must stay in its own process so package-generated properties are reevaluated before
# compiling, but both restores share one process and both builds another: two MSBuild starts and
# graph evaluations instead of four, and the themes reuse the transport projects' cached results.
# Targets run in the listed order, exactly as the four separate invocations did.
run_wpf_msbuild \
  "${wpf_root}/eng/ProGPU.Wpf.ValidationGraphs.proj" \
  "-target:RestoreManagedTransport;RestoreThemes" \
  -property:Configuration=Release \
  -verbosity:minimal
run_wpf_msbuild \
  "${wpf_root}/eng/ProGPU.Wpf.ValidationGraphs.proj" \
  "-target:BuildManagedTransport;BuildThemes" \
  -property:Configuration=Release \
  -verbosity:minimal

section "Packing LibreWPF transport, ProGPU bridge, and SDK"
pack_wpf_project "packaging/Microsoft.DotNet.Wpf.GitHub/Microsoft.DotNet.Wpf.GitHub.ArchNeutral.csproj" "LibreWPF.Transport" "${dev_package_version}"
pack_wpf_project "src/ProGPU.Wpf/ProGPU.Wpf.csproj" "LibreWPF.ProGPU" "${dev_package_version}"
# The SDK records which ProGPU version its consumers restore; keep it in step with this feed
# instead of the default hard-coded in the SDK project.
pack_wpf_project "packaging/ProGPU.Wpf.Sdk/ProGPU.Wpf.Sdk.ArchNeutral.csproj" "LibreWPF.Sdk" "${dev_package_version}" \
  -p:ProGpuPackageVersion="${progpu_package_version}"

section "Packing LibreWinForms packages"
# librewinforms-pack.sh validates that its output directory holds EXACTLY the LibreWinForms
# preview bundle and nothing else ("Unexpected current-version package artifact: ..."), which is a
# legitimate purity gate for a release bundle but incompatible with pointing it straight at the
# shared dev feed - by this point local-feed also holds LibreWPF.Transport/ProGPU/Sdk. Give it a
# private staging directory and publish the result into the shared feed afterwards.
librewinforms_feed="${DIST_LOCAL_LIBREWINFORMS_FEED:-${repo_root}/artifacts/librewinforms-feed}"

# The LibreWinForms bundle is skipped when LibreWinForms, the canonical slices it qualifies
# against and the versions are unchanged: its private staging directory still holds the last
# bundle, which is republished as is.
librewinforms_fingerprint="$({
  echo "${dev_package_version} ${progpu_package_version} ${target_platform} $(git -C "${wpf_root}" rev-parse HEAD)"
  repo_fingerprint "${winforms_root}"
  repo_fingerprint "${progpu_root}"
} | sha256_stdin)"

publish_librewinforms_packages() {
  shopt -s nullglob
  local produced=("${librewinforms_feed}"/*.nupkg "${librewinforms_feed}"/*.snupkg) file
  shopt -u nullglob
  if [[ "${#produced[@]}" -eq 0 ]]; then
    echo "librewinforms-pack.sh produced no packages in ${librewinforms_feed}." >&2
    exit 1
  fi
  for file in "${produced[@]}"; do
    retire_feed_files "${local_feed}/$(basename "${file}")"
  done
  # -p keeps the bundle's own timestamp, so a reused bundle does not look republished to the
  # cache eviction below and consumers keep their already-extracted copy.
  cp -fp "${produced[@]}" "${local_feed}/"
  record_stage librewinforms "${librewinforms_fingerprint}" "${produced[@]}"
}

prepare_librewinforms_feed() {
  invalidate_stage librewinforms
  rm -rf "${librewinforms_feed}"
  mkdir -p "${librewinforms_feed}"
}

if [[ "${target_platform}" == "macos" || "${target_platform}" == "windows" ]]; then
  if [[ "${target_platform}" == "windows" ]]; then
    build_canonical_winforms
  fi
  # Completed only now, when every canonical slice (and so its receipt) is final.
  librewinforms_fingerprint="$({ echo "${librewinforms_fingerprint}"
    for receipt in "$(stage_receipt canonical-winforms-ARM64)" "$(stage_receipt canonical-winforms-x64)" \
                   "$(stage_receipt canonical-winforms-anycpu)"; do
      [[ -f "${receipt}" ]] && head -n 1 "${receipt}"
    done
    true
  } | sha256_stdin)"
  if stage_is_current librewinforms "${librewinforms_fingerprint}"; then
    publish_librewinforms_packages
  else
  prepare_librewinforms_feed
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
  fi
else
prepare_librewinforms_feed
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
section "Checking payload architectures"
# One process for every entry of every package; tools/CheckPayloadArch.cs explains why.
"${wpf_dotnet}" run "${repo_root}/tools/CheckPayloadArch.cs" -- "${local_feed}"

# NuGet never re-extracts a package whose id+version it already has, and this feed republishes the
# same preview version every run. A corrected package therefore sits in the feed while every
# consumer keeps compiling and running against the stale extracted copy under
# ~/.nuget/packages/<id>/<version>/. That is not a corner case: it is how 25 packages came to serve
# ARM64 assemblies to an x64 process for a full day, surviving several rounds of "fixed and
# verified" because every check looked at the feed rather than the cache. Evict by timestamp - the
# feed file is newer than the extraction directory exactly when the package was republished.
section "Evicting stale NuGet cache entries for republished packages"
evict_stale_cache_entries() {
  local nuget_root evicted=0 pkg base id ver cached
  nuget_root="${NUGET_PACKAGES:-${HOME}/.nuget/packages}"
  [[ -d "${nuget_root}" ]] || { echo "  no global package folder at ${nuget_root}."; return; }
  for pkg in "${local_feed}"/*.nupkg; do
    [[ -e "${pkg}" ]] || continue
    base="${pkg##*/}"; base="${base%.nupkg}"
    # "<Id>.<Version>" where the version starts at the first dot followed by a digit.
    # Bash builtins only; a sed/tr per package costs ~0.25 s each on Windows.
    [[ "${base}" =~ ^(.*)\.([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?)$ ]] || continue
    id="${BASH_REMATCH[1]}"
    ver="${BASH_REMATCH[2]}"
    # macOS /bin/bash 3.2 has no ${var,,}; forks are cheap there.
    if (( BASH_VERSINFO[0] >= 4 )); then id="${id,,}"; else id="$(tr '[:upper:]' '[:lower:]' <<<"${id}")"; fi
    cached="${nuget_root}/${id}/${ver}"
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

section "Registering local NuGet source '${local_feed_name}'"
# dotnet prints the registered path in Windows form on Windows; compare both spellings.
local_feed_native="${local_feed}"
command -v cygpath >/dev/null 2>&1 && local_feed_native="$(cygpath -w "${local_feed}")"
registered_sources="$(dotnet nuget list source || true)"
# Builtin case-insensitive match, not grep: grep "Aborted" here at the end of a two-hour run
# (MSYS process start failing under memory pressure), which rolled back the whole feed.
shopt -s nocasematch
source_registered=0
[[ "${registered_sources}" == *"${local_feed}"* || "${registered_sources}" == *"${local_feed_native}"* ]] && source_registered=1
shopt -u nocasematch
if [[ "${source_registered}" == 0 ]]; then
  # Registration is a convenience, never a build gate. `dotnet nuget add source` fails with
  # "The source specified is invalid" in Git for Windows Bash (it wants a native path, and the
  # name may already exist), and that non-zero exit would otherwise trip restore_feed_on_failure
  # and roll back an otherwise-good feed.
  dotnet nuget add source "${local_feed}" --name "${local_feed_name}" \
    || echo "warning: could not register NuGet source '${local_feed_name}' (continuing)" >&2
else
  echo "Source already registered."
fi

publish_succeeded=1

section "Published packages"
ls -1 "${local_feed}"/*.nupkg 2>/dev/null || echo "(none)"
