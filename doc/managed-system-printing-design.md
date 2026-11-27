# Managed System.Printing for LibreWPF — design note

Status (2026-11-27): implemented and pushed. The release pin is LibreWPF `5ad647e34` with PrintingTools `f07b24b`; sections 6 and 7 record the slices and what is left. Originally: design only (2026-11-26). Scope: replace the C++/CLI `src/Microsoft.DotNet.Wpf/src/System.Printing`
(174 files, ~75k lines of C++) with managed code that builds and runs on Windows, macOS and Linux.

## 1. What exists today (verified in the `LibreWPF` submodule at `2139ab8e0`)

* The C++/CLI project only builds with `-p:LibreWpfUseCppCli=true`. The shipped `System.Printing.dll` is the
  C# cycle-breaker `cycle-breakers/System.Printing/System.Printing.PrintQueue.cs` (an empty `PrintQueue`) plus
  the reference assembly `System.Printing/ref/System.Printing.cs` (785 lines) and `System.Printing.internals.cs` (86).
  So **no real print system is shipped**; this work adds one rather than porting a shipped feature.
* `PrintTicket` and `PrintCapabilities` are **not** part of this assembly's implementation: they are managed
  C# in `ReachFramework/PrintConfig/PrtTicket_Public_Simple.cs` / `PrtCap_Public_Simple.cs`, and the Windows
  conversion helpers (`PTManager`, `PTProvider`, `UnsafeNativeMethods`) already P/Invoke `prntvpt.dll`.
* Public types in `System.Printing` that the C++/CLI assembly implements: `PrintSystemObject`, `PrintServer`,
  `LocalPrintServer`, `PrintQueue`, `PrintQueueCollection`, `PrintQueueStream`, `PrintJobInfoCollection`,
  `PrintSystemJobInfo`, `PrintDriver`, `PrintPort`, `PrintProcessor`, `PrintFilter`, `PrintJobSettings`,
  `PrintDocumentImageableArea`, `XpsDocumentWriter`, `VisualsToXpsDocument`, `XpsWriterException`, ~25
  `IndexedProperties.*Property` classes plus `PrintPropertyDictionary`, and ~20 enums.
* Consumer counts (files in `PresentationFramework`, `PresentationUI`, `ReachFramework`, `PresentationCore`):
  `PrintTicket` 79, `PrintQueue` 15, `PrintCapabilities` 13, `XpsDocumentWriter` 11,
  `PrintDocumentImageableArea` 4, `LocalPrintServer` 2, `VisualsToXpsDocument` 2; the rest are unused by the framework.
  The framework-facing core is therefore **PrintQueue + XpsDocumentWriter + LocalPrintServer**, not the 25 property classes.

## 2. Target design

One managed `System.Printing` implementation, one backend interface, three backends:

```text
System.Printing (public API = ref/System.Printing.cs, unchanged)
 └─ internal IPrintSystemBackend            enumerate queues/drivers/ports, read queue state and defaults,
     │                                       create/enumerate/cancel jobs, open a job stream, get/merge tickets
     ├─ WindowsSpoolerBackend               winspool.drv (EnumPrinters, OpenPrinter, GetPrinter, StartDocPrinter,
     │                                       WritePrinter, EnumJobs, SetJob) + prntvpt.dll (existing PTProvider)
     ├─ CupsIppBackend                      IPP/1.1 over HTTP to localhost:631 (Get-Printers, Get-Printer-Attributes,
     │                                       Print-Job, Get-Jobs, Cancel-Job); managed encoder/decoder, no libcups
     └─ InMemoryBackend (tests)             deterministic fake used by the unit tests
```

Decisions:
* **Fully managed, AOT-safe**: `LibraryImport` source-generated P/Invokes for winspool, no `DllImport` reflection,
  no C++/CLI, no `System.Management`. IPP is plain HTTP + a small binary codec (RFC 8010/8011).
* **Why IPP instead of libcups on macOS/Linux**: both ship CUPS, listening on `localhost:631`; IPP needs no native
  dependency per RID, which is the property this project is chasing. `libcups` stays a possible later fallback.
* **Property model**: keep the public `PrintSystemObject`/`PrintPropertyDictionary`/`*Property` classes, but make the
  properties lazy views over a backend snapshot, as the original does (`PrintSystemObjectLoadMode`,
  property filters). Only the properties a backend can fill are populated; others throw `PrintQueueException` like the
  original on unsupported access, never silently return defaults.
* **XpsDocumentWriter** is a thin adapter over the existing managed `XpsSerializationManager` in ReachFramework:
  write to a file stream or `PrintQueueStream`; for a queue, the backend receives the XPS bytes (Windows: spooler
  XPS_PASS data type; CUPS: convert XPS to PDF is **out of scope**, so IPP submission of XPS only works for queues
  that accept `application/oxps`; otherwise the writer reports a clear `PrintingNotSupportedException`).
* **PrintTicket/PrintCapabilities** stay in ReachFramework. The backend interface only moves tickets as Print Schema XML
  streams, which both sides already produce. On non-Windows the Print Schema is built from IPP attributes
  (`media-supported`, `sides-supported`, `print-color-mode-supported`, `printer-resolution-supported`,
  `copies-supported`, `orientation-requested-supported`).

## 3. Slices

1. **Slice 1 (this Mac can test it)**: public hierarchy + `InMemoryBackend` + `CupsIppBackend` read side
   (`LocalPrintServer`, `GetPrintQueues`, `PrintQueue` name/description/status/default ticket), IPP codec with golden
   byte tests, graceful "no CUPS" result. Windows backend is written against the same interface but marked **unverified**.
2. **Slice 2**: job submission (`PrintQueue.AddJob`, `PrintQueueStream`, `XpsDocumentWriter` to a queue), job enumeration/cancel.
3. **Slice 3**: ticket merge/validate via IPP on non-Windows (`MergeAndValidatePrintTicket`, `GetPrintCapabilities`).
4. **Slice 4**: `PrintDriver`/`PrintPort`/`PrintProcessor`/`PrintServer` events, `PrintQueueStream` edge cases, performance.

## 4. Wiring and packaging

* Replace the cycle-breaker output in `packaging/Microsoft.DotNet.Wpf.GitHub/Directory.Build.targets` (the
  `_SystemPrintingRuntimeRoot` / `_SystemPrintingRefRoot` items) with the new assembly, keep `System.Printing-ref`
  as the reference assembly (API unchanged), and keep the C++/CLI sources only behind `LibreWpfUseCppCli=true`.
* The managed assembly must not reference `PresentationFramework`; `PresentationFramework`, `PresentationUI` and
  `ReachFramework` keep compiling against `System.Printing-ref`, so there is no new project cycle.

## 5. Risks and what will not be claimed

* No Windows run is possible on this Mac: the Windows backend is compile-checked only. Spooler semantics
  (`PrintQueueStatus` flags, `PrintJobStatus`, driver-specific tickets) need a Windows machine with real queues.
* IPP quality depends on the CUPS version/queue; macOS driverless queues are the primary target.
* Parity with the original's 25 property classes is intentionally lazy; unused properties will throw until needed.

## 6. Status after slice 1 (2026-11-27; superseded by section 7)

Done (pushed; release pin LibreWPF `5ad647e34`, PrintingTools `f07b24b`):
* PrintingTools fork (`lextudio/PrintingTools`, branch `claude/neutral-core`): UI-neutral Core, Windows (Win32) adapter,
  managed CUPS/IPP adapter (PDF submission), WPF layer (compiles against LibreWPF, not run), old Linux/macOS adapters and
  Avalonia samples removed.
* LibreWPF `e6a04a0a2`: submodule `external/PrintingTools`; `src/Microsoft.DotNet.Wpf/src/System.Printing/managed`
  (generated public surface + hand-written `PrintServer`, `LocalPrintServer`, `PrintQueue`, `PrintQueueCollection`);
  transport packaging takes it instead of the empty cycle-breaker stub; 17 tests; read-only smoke run against real CUPS.

Left, in the order I would do it:
1. `PrintQueue.AddJob` / `PrintQueueStream` / `XpsDocumentWriter(PrintQueue)`: write XPS through ReachFramework's
   `XpsSerializationManager`, then hand the bytes to the backend (Windows: spooler XPS_PASS; CUPS: only if the queue accepts
   `application/oxps`, otherwise `PrintingNotSupportedException`; PDF needs an XPS-to-PDF step that does not exist yet, or the
   WPF layer's raster PDF). Cannot be verified on the Mac until a LibreWPF.Sdk host runs WPF code (a plain test host fails to
   load `WindowsBase` 11.0.0.0 next to the shared framework's identical version).
2. `PrintTicket` / `PrintCapabilities` (`GetPrintCapabilities`, `MergeAndValidatePrintTicket`): IPP attributes to Print Schema on
   non-Windows, `prntvpt` on Windows.
3. The `MS.Internal.PrintWin32Thunk` internals that ReachFramework reaches through `InternalsVisibleTo`.
4. Job members (`GetJob`, `PrintSystemJobInfo`, cancel) and `PrintQueueStatus` flags.

Pushed for this release:
* PrintingTools `f07b24b` -> `lextudio/PrintingTools` (`claude/neutral-core`), then LibreWPF `5ad647e34`.
* openavalon: the LibreWPF pointer moves to `5ad647e34`; `external/PrintingTools` is part of the workflow preflight
  checkout and `tools/preflight-publish.sh`. Pushing openavalon starts the 1.5-2 hour publish run.

## 7. Update (2026-11-27, later): runtime verification and what it found

* The WPF layer is now tested on LibreWPF's real WPF assemblies (PrintingTools `4ab422d`, tests/PrintingTools.Wpf.Tests):
  an isolated `AssemblyLoadContext` avoids the WindowsBase 11.0.0.0 clash; the probe calls
  `ProGpuWpfNativeMediaServices.Initialize()` first. 12 tests pass, 1 skipped.
* LibreWPF `edf7598f1` adds the managed `XpsDocumentWriter` (synchronous, document destination) plus the
  `InternalsVisibleTo("ReachFramework, ...")` grant; `WpfRenderService.CreateXps` now works end to end.
* Open LibreWPF gap, the only skipped test: **`RenderTargetBitmap` has no portable branch.** It is the original MIL/WIC code
  (`FactoryMaker`, `MILFactory2.CreateBitmapRenderTarget`, `CreateBitmapRenderTargetForBitmap`, `BitmapSource.CreateCachedBitmap`)
  and calls native `wpfgfx_cor3`, which does not exist on macOS/Linux. `RenderBitmaps` and `CreatePdf` (raster PDF) of
  `PrintingTools.Wpf` need it. It is fixable, in LibreWPF (never worked around in PrintingTools):
  1. PresentationCore: a portable branch in `RenderTargetBitmap` (pixel store = a Pbgra32 `byte[]` exposed through the existing
     `PortableBitmapSourcePixels` path that `BitmapSource.cs` already has; `Render(Visual)` calls a registered service).
  2. ProGPU.Wpf.Interop: a service interface in the style of `IPortableGeometryOperations` ("rasterize this visual tree into
     this buffer at this DPI"), with `PortableWpfServiceRegistry` registration.
  3. ProGPU.Wpf: implement it with ProGPU's offscreen rendering and pixel readback (`ReadPixels`, used by
     ProGPU.Tests.Headless).
  Unknown until tried: whether ProGPU's headless render and readback work on this Mac (its headless test project does not
  currently build here: ProGPU.Samples needs the full WPF/System.Drawing graph), and whether a software fallback is needed.

## 8. Update (2026-11-27, end of day): the RenderTargetBitmap gap is closed

* LibreWPF `7e8431511` adds a portable `RenderTargetBitmap`: PresentationCore keeps a managed Pbgra32 buffer and calls a new
  `IPortableVisualRasterizer` service (ProGPU.Wpf.Interop), implemented in ProGPU.Wpf over a headless ProGPU composition target
  (replay the visual, render into an offscreen texture, read the pixels back). Exact per-axis scale (fractional and non-square
  DPI), "over" blending onto existing pixels, `Clear`, clone, scene cleared after each render, device recreated after a failure.
  It needs a GPU device (wgpu; Metal on this Mac).
* PrintingTools `2524b44`: tests/PrintingTools.Wpf.Tests now run `RenderBitmaps`, `CreatePdf` and `CreateXps` on real LibreWPF:
  19 pass, 0 skipped. The harness is an isolated `AssemblyLoadContext` (`AlcHost`) that loads the newest Release/Debug build of
  each LibreWPF assembly and copies `libwgpu_native` next to the tests.
* Still open: `PrintQueue.AddJob`/`PrintQueueStream`/queue destination of `XpsDocumentWriter` (needs XPS bytes handed to the
  backend; CUPS takes PDF, and `WpfRenderService.CreatePdf` can now produce it), `PrintTicket`/`PrintCapabilities`,
  `MS.Internal.PrintWin32Thunk`, job members, Windows verification. LibreWPF's own tests cannot run real PresentationCore on
  this Mac, which is why the RenderTargetBitmap tests live in the PrintingTools harness.

## 9. Update (2026-11-27, night): PrintCapabilities and tickets done

* LibreWPF `09f1de285`: `PrintQueue.GetPrintCapabilities` / `GetPrintCapabilitiesAsXml` / `DefaultPrintTicket` / `UserPrintTicket` /
  `MergeAndValidatePrintTicket` over Print Schema XML (`PrintSchema.cs`: Core model <-> XML that ReachFramework's public
  `PrintCapabilities(Stream)` / `PrintTicket(Stream)` parse; validation reuses Core's `MergeWithCapabilities`, conflicts map to
  `ConflictResolved`). Page sizes are named only through unambiguous Print Schema keywords (also from PWG names such as
  `iso_a4_210x297mm`); a size without one is left out, never invented. `PrintTicketScope` is accepted but ignored.
* Tests: 25 in LibreWPF.SystemPrinting.Tests (XML written as text, default load context) and, on the real ReachFramework, 25 in
  PrintingTools `e436c6f` (tests/PrintingTools.Wpf.Tests).
* Still open: `PrintQueue.AddJob` / `PrintQueueStream` / queue destination of `XpsDocumentWriter`, `MS.Internal.PrintWin32Thunk`,
  job members and `PrintQueueStatus` flags, Windows verification (there prntvpt is the faithful ticket engine, not this
  converter). At this slice the PrintingTools gitlink was `e49ac0f` and nothing was pushed; section 10 supersedes it
  (PrintingTools `f07b24b`, pushed with the LibreWPF pin).

## 10. Update (2026-11-28): printing to a queue

* PrintingTools `f07b24b`: `IPrintDocumentSubmitter` (Core) + CUPS implementation: a finished PDF goes through Get-Printer-Attributes,
  ticket merge with the queue defaults (null ticket = the queue's own defaults), Validate-Job and Print-Job; returns
  `SubmittedDocument(JobId, Warnings)` (what the queue forced into another value). The Win32 adapter does not implement it.
* LibreWPF `5ad647e34`: `PrintQueue.CreateXpsDocumentWriter(queue).Write(visual | FixedDocument | FixedDocumentSequence | FixedPage |
  DocumentPaginator)` renders every page with the portable `RenderTargetBitmap` (200 dpi), builds a raster PDF (`RasterPdfWriter`, linked
  from PrintingTools.Wpf) and submits it through the backend's `IPrintDocumentSubmitter`. A never-laid-out element is measured and
  placed at the page origin at its desired size; a page without a usable size uses the queue's default page; a failed submission does
  not use the writer up. Managed `System.Printing` now compiles against `PresentationFramework-ref` (the impl-cycle stub had empty
  FixedDocument/FixedPage).
* Tests: PrintingTools `4779c8a` (31 on real WPF with a GPU device, 48 in Cups.Tests), LibreWPF.SystemPrinting.Tests 25.
* Still open: `PrintQueue.AddJob` / `PrintQueueStream` / the job members (`GetJob`, `PrintSystemJobInfo`, cancel),
  `PrintQueueStatus` flags, `MS.Internal.PrintWin32Thunk`, the Windows submitter (the spooler takes XPS: the Win32 adapter would
  implement `IPrintDocumentSubmitter` for `application/oxps`; cannot be verified on this Mac), a real CUPS queue run, memory for very
  large documents (all pages are rasterized into one PDF), scaling/pagination of content wider than the page, PrintTicket-driven
  page size, caller job names. Pushed: the LibreWPF pin is `5ad647e34`, whose `external/PrintingTools` gitlink is `f07b24b`.
