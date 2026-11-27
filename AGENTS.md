# OpenAvalon packaging notes

## How consumers get these packages

GitHub Actions builds and publishes the whole LibreWPF / LibreWinForms / ProGPU closure to lextudio
GitHub Packages (`publish-librewpf-github-packages.yml`, triggered by a push that touches
`LibreWPF`, `dist.local.sh`, `.gitmodules` or the workflow). Consumers download it; nobody compiles
the closure locally to use it, which is what made the old local-feed route slow.

- **Use the published packages.** OpenDevelop's `sync-openavalon-feed.ps1` downloads the versions it
  pins, with the GitHub CLI's credential (`gh auth refresh -h github.com -s read:packages`), into its
  project-local feed `OpenDevelop/artifacts/openavalon-feed`. CI restores the same packages with its
  own token. A new LibreWPF reaches OpenDevelop when its pins move to a published version.
- **Try a change before publishing.** Build only the assembly you changed and replace it in the
  consumer: `./dev-overlay.sh` (the consumer's `bin`) or `./dev-patch-feed.sh` (the package inside
  OpenDevelop's feed). Both are described in the `librewpf-dist-lanes` skill under "Incremental runs and
  the inner loop".
- **Ship it.** Commit here through the review flow. Pushing starts the publish workflow, so push only when the
  user explicitly instructs it; see the `openavalon-publish-and-pointers` skill ("Publishing: one run at a time").

The `librewpf-dist-lanes` skill documents `dist.local.sh` and the packing rules it enforces. It is what the
publish workflow runs on each platform. Run it on a workstation only to reproduce or debug that workflow;
its `artifacts/local-feed` is not how OpenDevelop gets packages any more.

## Rules that always apply

- Do not start publish runs, do not push (only when the user explicitly instructs it), do not bump a pointer to an unpushed commit (the publish preflight
  then fails on a missing commit). A change to `LibreWPF`, `dist.local.sh`, `.gitmodules` or the publish
  workflow starts a 1.5-2 hour run once pushed.
- Pointer chain `openavalon -> LibreWPF -> external/ProGPU` and `external/LibreWinForms -> its nested external/ProGPU`:
  the two ProGPU pins must be the same commit. Run `./tools/preflight-publish.sh` before pushing a bump.
- Use `/usr/local/share/dotnet`, never Homebrew dotnet. Commit only through the review flow
  (skill `commit-review-flow`).
- Never delete the global NuGet cache to "fix" a restore/build mismatch; first verify the local source, package
  versions, nested-repository commits and architecture-specific feeds.

## Skills (loaded on demand, in `.claude/skills/`)

Read the matching skill file by path before touching the area below if your client does not load skills
automatically (`.claude/skills/<name>/SKILL.md`).

- `openavalon-publish-and-pointers`: publish workflow discipline, pointer chain, preflight, push order.
- `librewpf-dist-lanes`: `dist.local.sh` lanes (Windows/macOS), shared preparation, incremental receipts, packing
  invariants, dual-architecture canonical WinForms feeds, verification and common failures.
