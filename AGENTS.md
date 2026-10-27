# AirStats Architecture

AirStats is a native macOS system monitor with menu bar readouts, a dropdown panel,
and a desktop widget. It is a Swift Package built with AppKit and SwiftUI, without
an embedded web application or a separate backend process. The package targets
macOS 14 or later; building the current UI requires the macOS 26 SDK or later.

## Modules and Dependencies

```text
AirStats (application lifecycle and CLI)
    ├── AirStatUI (AppKit controllers, SwiftUI, Sparkle)
    │       └── AirStatKit
    └── AirStatKit (collection, snapshots, history, settings)
```

- `Sources/AirStats`: `main.swift` handles CLI commands before starting the UI.
  `AppDelegate` and `AppCoordinator` create shared settings, the metrics engine,
  and controllers, and connect UI actions with sleep, lock, and session events.
- `Sources/AirStatKit/Collectors`: data sources using Mach, sysctl, IOKit, Metal,
  CoreWLAN, and local files. Each collector implements `MetricSource`.
- `Sources/AirStatKit/Core`: snapshot models, the `SamplingCore` scheduler,
  observable `MetricsEngine`, availability states, and bounded history.
- `Sources/AirStatKit/Settings`: the Codable configuration model and `SettingsStore`.
- `Sources/AirStatKit/Support`: formatting, fixtures, and the CLI `MetricProbe`.
- `Sources/AirStatUI`: `MenuBar`, `Panel`, `DesktopWidget`, `Settings`, shared
  `Charts` and `Design`, plus notification, update, and hotkey services in `Support`.
- `Tests/AirStatKitTests`: Swift Testing suites covering Kit and pure UI logic in
  one target. Some collector contract tests access the actual hardware.
- `Resources`: Info.plist, the application icon, and disk image artwork. SwiftPM UI
  resources are stored separately in `Sources/AirStatUI/Resources`.
- `Scripts`: application packaging, releases, appcast generation, and benchmarks.

`AirStatKit` never imports SwiftUI or AppKit. It must work without a window server,
in tests, and through `--probe`. Sparkle is the only external SwiftPM dependency,
linked by the UI and executable targets. Targets use Swift 5 language mode with a
Swift 6 toolchain; low-level collectors rely on queue confinement.

## Data Flow and Concurrency

1. `SettingsStore` owns configuration on the main actor. Changes pass through
   `update`, normalization, and the `changes`/`ObservedChanges` observation stream.
2. `MetricsEngine` translates settings and surface visibility into the required
   `CollectorID` set, sampling interval, and `SamplingActivity` on the main actor.
3. `SamplingCore` owns one serial utility queue, a timer, and a `SourceSlot` for
   each collector. Collector state and log offsets change only on this queue;
   the UI never accesses collectors directly.
4. `SourceSlot` handles each source's interval, enabled state, retries, and baseline
   after sleep. Permanently unsupported sources retire; transient failures back
   off; `pending` means waiting rather than failure. `stop` permits a later `start`.
5. New `SystemSnapshot` values reach the main actor. `MetricsEngine` updates
   observable state and history, and controllers and SwiftUI redraw their surfaces.

An open panel takes priority over the desktop widget and normal menu bar activity.
An occluded menu bar samples less frequently; sleep, lock, and inactive sessions
suspend collection. Rates use actual elapsed time rather than nominal cadence.
Source settings reach the sampling queue as one configuration before the first read.

## Snapshots, Availability, and History

`MetricState<T>` distinguishes a value, pending collection, transient failure,
permission denial, and an unsupported metric. Never replace a missing measurement
with zero, an estimate, or a stale reading. Unknown fields remain optional and
render as a dash. Zero is valid only when supported by the source's measurement.

`MetricHistory` keeps frequent samples in fixed-capacity `SampleRing` buffers.
`MinuteHistory` retains the last day in minute buckets with minimum, mean, maximum,
and process notes. Minute history persists to disk; raw rate history resets after
sleep. Missing samples remain gaps. A chart with fewer than two points must not
look like a measured horizontal line.

## Ollama and llama.cpp Monitoring

Each `AIEndpoint` describes one instance: a stable UUID, name, runtime, API base URL
and optional key, local log directory and filename pattern, and enabled sources.
`usesAPI` supports logs-only monitoring. Default API addresses are
`http://localhost:11434` for Ollama and `http://localhost:8080` for llama.cpp.
Default log sources are `~/.ollama/logs` / `server*.log` and
`~/.config/llama-server/logs` / `std*.log`.

`AICollector` reads new log data with bounded work and handles file replacement,
rotation by rename, truncation, and partial lines. Its parser extracts model
metadata, context capacity, generation and prefill timings, and reported memory
allocations. Prompts and generated responses are unnecessary for monitoring and
must not appear in diagnostics or fixtures copied from user logs.

`AIAPIClient` performs GET requests only: Ollama `/api/ps`; llama.cpp `/props`,
`/health`, available `/slots` and `/metrics`, or `/models` for the router. Requests
have time and response-size limits. Do not generate responses, load models, or wake
sleeping models for monitoring; downloaded inventory is not loaded inventory.
`AIAPICache` owns responses on a separate serial queue, permits one poll per
instance, backs off after failures, cancels requests when sources change, and
ignores late responses. `SamplingCore` never waits for network requests.

`AIMerge` treats fresh API inventory as authoritative for currently loaded models.
Current log timings take priority for generation speed; an API rate is used only
when no usable matching log timing is available. Matching requires explicitly
reported aliases, paths, or digests; similar model family names do not establish
identity. Log collection continues when an API is unavailable. Status and freshness
are tracked separately for both sources. `isLoaded` and `isActive` are distinct:
a loaded model may be idle.

Ollama's API manifest digest and its GGUF blob digest identify different objects.
Link the public tag from an observed load's `template selection` event to its GGUF
path; strip only the explicit default registry/library prefixes. A `loaded runners`
count of one retires previous unlabelled runner states, while multiple loaded
runners must keep unlabelled timing output ambiguous.

`AIPrefillProgress` tracks prompt reading separately for each slot and task. Its
fraction comes directly from the runtime's `progress` field, not from context-window
occupancy. Keep processed tokens, elapsed time, and reading speed as reported; do
not infer total prompt tokens from a rounded percentage. Clear progress when the
request finishes, starts decoding, is replaced, or becomes stale. API merging must
preserve fresh matching log progress without reviving a completed request.

`AISlotInfo` keeps each model's slot ID, task, phase, context usage, answer rate,
prefill rate, and progress independent. Slot reuse resets current request fields;
delayed completion from a previous task must not replace its successor. Expire
each slot's rates and phase independently, even when another slot stays busy.
`AIModelInfo.historyID` identifies the log stream across metadata names and API
aliases. Token observations carry that model identity, slot ID and task ID.
`AIHistory` filters both Answer and Prefill series by model and slot. An unlabelled
measurement may appear in All slots, never in an arbitrarily selected slot.
The panel and widget's Slot picker filters readouts and both token histories;
memory remains at the model/instance level and is never divided between slots.
Their Instance picker displays all instances or one stable instance UUID. Retain
slot selections by instance UUID while switching. Removing the selected instance
falls back to All instances. Presentation choices must not stop collection or erase
the other instances' history.

`AISnapshot` keeps instances and their models separate; identical model names on
two servers never merge. An old model-load event alone does not prove that the
server is still running. `AIProcessMemoryCollector` replaces API/log memory fields
with process RSS before publishing the snapshot or recording its memory history.
It locates a local listener by the configured API port, traverses its descendants,
and matches model workers by explicit model names or paths. Router overhead and
unrelated instances are excluded. Discovery is cached; RSS is read each sample.
PID start times are checked to reject exits and PID reuse. Missing or ambiguous
process measurements remain unavailable, with no fallback to API sizes or buffers.
`NativeAIProcessInspector` uses libproc for listeners, parentage, RSS and physical
footprint; never run lsof, ps or vmmap in the sampling loop. Shared pages may count
in multiple RSS values, so do not describe the summed RSS as unique physical RAM.

The panel renders AI metrics with `PanelDetailGrid`, matching the Memory module.
Source problems use a warning icon and tooltip beside the instance name; general
measurement notes are a tooltip rather than a block of diagnostic prose.

`AIHistory` retains bounded history by instance UUID, with 1, 5, and 15 minute
buckets. Live `n_gen` / `tg` / `tg_3s` log lines produce generation samples:
prefer the reported rolling `tg_3s` rate, falling back to `tg`. These rates are
averaged within each bucket; cumulative `n_gen` must not become a fresh token count.
For requests without live samples, aggregate completed timings as total tokens
divided by total generation time. Track streamed requests by model, slot and task
so their final cumulative timing cannot count the same work again. Repeated
snapshots must not create samples. Never derive token throughput from ordinary
HTTP access logs: HTTP request duration is not generation duration.

## Settings and UI

`SettingsStore` persists JSON atomically with debouncing and a backup, and publishes
a revision only when settings actually change. Decoding and normalization must
remain compatible with existing files. Tests must pass a temporary `directory:`;
changing `HOME` does not isolate Application Support.

AppKit controllers own windows, system status items, and their lifecycles. SwiftUI
owns their contents. `DesignSystem.swift` defines shared colors, dimensions, and
typography; `MetricFormatter` defines number formatting. For a new metric, first
add its model and collector to Kit, then settings and rendering on the relevant
surfaces. Check exhaustive switches over metric and module enums.

## Building and Verification

```sh
swift build
swift test
Scripts/build.sh                    # .build/debug/AirStats.app
Scripts/build.sh release            # optimized .app bundle
.build/debug/AirStats --probe       # real collectors, without UI
.build/debug/AirStats --render      # fixture-based PNGs in render/
```

`Scripts/build.sh` assembles the `.app`, copies SwiftPM resources and
Sparkle.framework, updates the SDK marker, and signs the bundle ad hoc.
`Scripts/release.sh` handles distribution with Developer ID signing and
notarization. Verify UI changes through offscreen renders; materials and
transparency require an on-screen check. Hardware test results depend on the
machine's sensors and current state.

Test log parsing with small synthetic files in temporary directories: timings,
missing fields, partial lines, separate instances, rotation, and truncation. Real
logs help verify local formats, but tests must not require installed Ollama or
llama servers or change user settings and logs. API tests use URLProtocol and
controlled mock clients to cover HTTP errors, response limits, cancellation,
staleness, fallback, and instance isolation without network requests.

See `CONTRIBUTING.md` for additional project rules. Commit messages follow
Conventional Commits. Preserve the application's lightweight profile: do not add
per-render timers or reread entire large files on each redraw.
