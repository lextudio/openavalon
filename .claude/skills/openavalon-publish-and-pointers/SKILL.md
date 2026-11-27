---
name: openavalon-publish-and-pointers
description: Use before pushing or bumping any submodule pointer in openavalon (LibreWPF, LibreWinForms, ProGPU), before anything that touches LibreWPF, dist.local.sh, .gitmodules or the publish workflow, and when a publish run is queued or running. Covers the 1.5-2 hour serialised publish workflow, the ProGPU/LibreWinForms/LibreWPF pointer chain and its same-commit rule, tools/preflight-publish.sh, and the required push order.
---

# openavalon: publish discipline and the pointer chain

Never start or trigger publish runs yourself (they take 1.5-2 hours and queue), and never push on your own:
pushing needs the user's explicit instruction. When the user does push, the order for a chain change is
ProGPU, then LibreWinForms (nested ProGPU pin), then LibreWPF (both pins), then openavalon (LibreWPF pointer).

## Publishing: one run at a time

`publish-librewpf-github-packages.yml` triggers on every push that touches `LibreWPF`,
`dist.local.sh`, `.gitmodules` or the workflow itself, and it is serialised with
`cancel-in-progress: false`: a second run **queues** behind the first instead of superseding
it. It takes 1.5-2 hours, so two submodule bumps half an hour apart start two full runs, the
older one publishes the superseded closure first, and the newest bits reach the feed only after
both have finished.

Bump `LibreWPF` only when the previous publish run has completed. If a stale run is already
queued or running, cancel it by hand - safely while its "Windows, Linux, and macOS package
closure" job is still in the build/verify steps, because nothing is deleted or uploaded before
the "Publish the package closure to GitHub Packages" step, and the superseding run republishes
the whole closure anyway:

```bash
gh run list --repo lextudio/openavalon --workflow publish-librewpf-github-packages.yml --limit 5
gh run cancel <stale-run-id> --repo lextudio/openavalon
```

## Before pushing a pointer bump: run the preflight

The pointers form a chain, and one rule across it is enforced only late in the publish run:

```text
openavalon -> LibreWPF -> external/ProGPU
                       -> external/LibreWinForms -> external/ProGPU   (its own nested pin)
```

LibreWinForms's nested `external/ProGPU` and LibreWPF's `external/ProGPU` must be **the same
commit** (`LibreWPF/eng/progpu-wpf-canonical-winforms-integration.sh`, "LibreWinForms pins ProGPU X,
but LibreWPF has Y"). That gate runs at the end of the macOS closure job, after about 70 minutes of
native staging, so a mismatch costs a full run and publishes nothing. Run 42720059364 (2026-11-09)
failed exactly this way after a ProGPU bump moved only LibreWPF's pin.

So a ProGPU change goes up the chain one repository at a time, each pushed before the next points at it
(every repository has its own review and commit):

1. ProGPU (`lextudio/ProGPU` main).
2. LibreWinForms: bump its `external/ProGPU` (`lextudio/librewinforms`, branch `codex/align-progpu-crossdesktop`).
3. LibreWPF: bump `external/ProGPU` **and** `external/LibreWinForms` (`lextudio/LibreWPF`, its current branch).
4. openavalon: bump `LibreWPF`.

Before the push in step 4, and after committing it, run

```bash
./tools/preflight-publish.sh
```

It reads the pointers committed at `HEAD` of each repository (what CI would check out), prints the chain
and fails with the fix when the two ProGPU pins differ or a pinned commit is not in the checkout (not
pushed). It also validates ProGPU's `eng/progpu-package-list.sh` (the parallel id/project arrays) by
sourcing it. The workflow's first job, `preflight`, runs the same script and every other job
`needs:` it, so a bad pointer now fails in about a minute; do not rely on that to save you the push, a
failed run still occupies the serialised queue.

Rules that follow from the incident:

- **Reproduce a gate locally before pushing something that starts a 1.5-2 hour run.** Read the gate's own
  comparison (the script named in the error) and run it, instead of inferring the rule.
- **A change to the workflow file starts a publish run too** (it is in the trigger paths). Push the
  workflow/preflight change together with the pointer bump, never ahead of it, or the first run uses the
  old pointers and fails again.
- Put any new cross-repository invariant into `tools/preflight-publish.sh`, not only into a late script.
