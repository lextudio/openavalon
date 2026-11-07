# OpenAvalon

OpenAvalon publishes the coordinated LibreWPF, LibreWinForms, and ProGPU NuGet
package closure used by OpenDevelop and other preview consumers.

This is an integration and packaging repository. The framework source is pinned
through the `LibreWPF` submodule; OpenAvalon builds, verifies, and publishes one
version-aligned closure to lextudio GitHub Packages.

## What's published

The closure includes:

- `LibreWPF.Sdk`, `LibreWPF.Transport`, `LibreWPF.ProGPU`, and
  `LibreWPF.Interop`;
- LibreWinForms compatibility packages;
- ProGPU managed, native, text, media, and rendering packages; and
- the mobile host packages `ProGPU.Android`, `ProGPU.iOS`,
  `ProGPU.Android.Media`, and `ProGPU.Apple.Media`.

All packages are preview software. A successful publication proves that the
coordinated closure built, was packaged, and passed its release gates. It does
not promise source compatibility for every WPF application or full maturity of
every native graphics, accessibility, printing, NativeAOT, or mobile-rendering
path.

## Consuming the closure

Packages are published under the `lextudio` GitHub organization:

```xml
<add key="lextudio_github"
     value="https://nuget.pkg.github.com/lextudio/index.json" />
```

Use one aligned preview version for the SDK and the ProGPU closure; do not mix
versions from separate publications.

OpenDevelop CI restores from GitHub Packages. For local OpenDevelop work, use
its synchronized project-local feed instead of adding a GitHub token to NuGet
configuration:

```powershell
pwsh ./sync-openavalon-feed.ps1
```

See OpenDevelop's `AGENTS.md` for consumer pinning, authentication, and local
feed rules.

## Repository layout

| Path | Purpose |
| --- | --- |
| `LibreWPF/` | Pinned LibreWPF, LibreWinForms, and ProGPU source graph. |
| `dist.local.sh` | Canonical closure build run by the publication workflow. |
| `.github/workflows/publish-librewpf-github-packages.yml` | Serialized build, verification, and GitHub Packages publication workflow. |
| `dev-overlay.sh` | Temporarily overlays one locally built assembly into an OpenDevelop output. |
| `dev-patch-feed.sh` | Temporarily patches one assembly in OpenDevelop's local package feed. |

## Publishing

Pushes to `main` that change the source graph or publication workflow start the
publication workflow. It builds Windows, Linux, macOS, Android, and iOS native
inputs; packages and verifies the closure; then publishes it to GitHub Packages.

Publication is serialized and normally takes 1.5–2 hours. Do not use a local
feed-to-feed copy or a workstation `dist.local.sh` run as a substitute for a
consumer release. The workflow is the authoritative publication path.

## Developing a LibreWPF change

1. Make and verify the source change in `LibreWPF/`.
2. Commit the updated submodule pointer and any packaging changes here.
3. Push to `main` and wait for the publication workflow to succeed.
4. Move the consumer's aligned version pins and closure receipt to that publish.
5. Synchronize the consumer-local feed and run its relevant tests.

For a short-lived OpenDevelop experiment, use `dev-overlay.sh` or
`dev-patch-feed.sh`. Never hand-copy assemblies: a consumer rebuild or restore
would erase the change and can conceal a mismatched package closure.

## Support boundaries and further reading

Read [LibreWPF's README](LibreWPF/README.md) for framework goals, supported
scenarios, migration guidance, and package details. Read [AGENTS.md](AGENTS.md)
before changing versions, native inputs, submodule pins, or publishing logic.

The closure is intentionally version-aligned. A package, SDK, or consumer pin
must not advance independently of its matching publication.

## License and security

License and security information for the framework source is maintained in the
[`LibreWPF` submodule](LibreWPF/).
