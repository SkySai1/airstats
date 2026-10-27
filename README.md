<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/logo-dark.png">
  <img src="docs/logo-light.png" alt="" width="104">
</picture>

<h3>AirStats</h3>

An ultra lightweight macOS system monitor.

<hr width="140">

</div>

AirStats is a system monitor for the Mac menu bar. It reads CPU, memory, GPU, network,
disk, battery, temperature, process and host statistics from the kernel and shows them in
three places: the menu bar itself, a panel that drops down when you click the status item,
and a desktop widget you can leave on screen.

It can also monitor Ollama and llama.cpp instances by combining their APIs with local server logs.

It is built to be genuinely light. A menu bar monitor runs all day, every day, so AirStats
holds a few megabytes and a fraction of a percent of one core rather than the tens of
megabytes its peers take. It has no Dock icon, and reads the system through Mach, IOKit,
sysctl and CoreWLAN.

## Requirements

- macOS 14 or later
- Apple silicon

## Install

Download it from [airstats.app](https://airstats.app), open the dmg and drag the app to
Applications. It is signed and notarized, so it opens with no warning.

Or with Homebrew:

```sh
brew install --cask airstats
```

AirStats updates itself with [Sparkle](https://sparkle-project.org). It asks airstats.app
once a week whether a newer version exists, and installs one only when you say so. Both of
those can be turned off in General settings.

## Build from source

You need Xcode 26 or later: the app draws Liquid Glass, which needs the macOS 26 SDK.

```sh
Scripts/build.sh release
cp -R .build/release/AirStats.app /Applications/
open /Applications/AirStats.app
```

`Scripts/build.sh` wraps the SwiftPM binary in a `.app` bundle, copies `Sparkle.framework`
into `Contents/Frameworks`, and signs it ad hoc. macOS grants a status item only to a
signed bundle with `LSUIElement` set. Run the script with no argument for a debug build.

An ad-hoc signature is enough to run a build you made yourself, and not enough to travel:
macOS refuses an ad-hoc bundle that arrived over the internet. `Scripts/release.sh` is what
produces the download above, signing with a Developer ID certificate and stapling Apple's
notarization ticket to the `.dmg`.

## Local AI instances

Open **Settings → AI → Add instance**, choose Ollama or llama.cpp, and set a name,
API base URL, log directory and filename pattern for each server. Enter an API key
if the server requires one, or disable API access for logs-only monitoring. Saving an enabled instance adds
AI to the menu bar and desktop widget modules. Enable the desktop widget separately
if you want it on screen; click the menu bar item and expand AI for the panel details.

| Runtime | Default API | Default directory | Filename pattern |
| --- | --- | --- | --- |
| Ollama | `http://localhost:11434` | `~/.ollama/logs` | `server*.log` |
| llama.cpp | `http://localhost:8080` | `~/.config/llama-server/logs` | `std*.log` |

Patterns support filename globs such as `*` and `?`. Include rotated names in the
pattern: for example, use `server*` for `server.log.1` as well as `server.log`.
The reader follows renamed files, replacement and truncation, and reads new data
with a bounded budget instead of rescanning whole logs on every poll.

API polling runs asynchronously with timeouts and bounded responses. Ollama's
running-model inventory and llama.cpp's loaded models and slot state supply current
information. Generation speed uses current log timings first, with an API rate as
a fallback when no usable matching log timing is available. Logs also supply fields
missing from the API. The two sources are matched using reported names, paths or
digests. An API error leaves log collection running; API and log problems appear
as a warning icon beside the instance name, with details on hover. A loaded model
is distinguished from a model currently generating a response.

For Ollama, the public model tag reported during loading links API inventory to
the GGUF paths in logs and process arguments. The scheduler's loaded-runner count
reconciles model reloads so obsolete log states do not hide current measurements.

Each instance has its own models, context size and last reported usage, generation
and prefill speeds, and measured process memory. The panel uses the same column
layout as Memory for supporting metrics. Charts aggregate generation
timings and memory measurements in 1, 5 or 15 minute buckets. Live
generation lines (`n_gen`, `tg`, `tg_3s`) update the chart while a response is being
generated, using the reported rolling `tg_3s` rate when available, otherwise `tg`.
Charts average those rate samples; requests without live samples use total tokens
divided by measured generation time. A final request timing does not duplicate its
live samples. Different instances remain separate even when they serve the same model.

Use the Instance selector in the panel or widget to view All instances or a single
configured instance. Metrics and charts follow that selection; each instance keeps
its own slot selection when switching between instances.

Use the Slot selector to switch between All slots and an
individual reported slot. Each slot keeps its own task ID, Prefill/Answer stage,
context usage, generation speed, prefill speed, and progress. Answer and Prefill
charts follow the selection, using the same 1m, 5m, and 15m steps. Slot IDs are scoped
to their model, so equal slot numbers in different workers never share measurements.
Memory remains measured per model process and shared across its slots. Reusing a
slot for a new task clears the previous task's current measurements while retaining
its historical samples.

While a prompt is being read, the panel and widget show a separate prefill progress
bar with the reported percentage, processed tokens, reading speed, and elapsed time
when available. For example, `n_tokens = 90527, progress = 0.97` shows 97% and
90,527 processed tokens. This percentage describes prompt reading, independently
of context-window utilization. Progress clears when reading finishes or the request
ends; stale logs cannot leave a progress bar running indefinitely.

Only reported or directly measured values appear. Missing measurements show a
dash; old logs show activity as unknown unless fresh API data supplies it. Standard
Ollama access logs may omit generation timings, and detailed runtime logging may be
needed. Memory and its chart use the RSS of local model worker processes identified
by the configured API port, process ancestry, and explicit model names or paths.
The router is excluded when it only manages model workers. Memory tooltips include
PID, RSS, and physical footprint. Inspection uses native macOS APIs without running
`vmmap` on each poll. API sizes and logged buffers are not substituted for process
memory; remote or inaccessible processes show a dash. Shared resident pages may
be counted in more than one process's RSS. Timestamp-less startup logs
can restore model metadata, but their historical timings cannot fill dated charts;
new timing lines are recorded from the time monitoring starts.

Verify the default local sources without starting the UI:

```sh
.build/debug/AirStats --probe ai --repeat 2 --verbose
.build/debug/AirStats --probe ai --logs-only --verbose
.build/debug/AirStats --probe ai --llama-url http://localhost:11436 --verbose
.build/debug/AirStats --render panel desktopWidget --scenario aiMonitoring --open ai
.build/debug/AirStats --render panel desktopWidget --scenario aiSlots --open ai
```

API field definitions are documented by [Ollama](https://github.com/ollama/ollama/blob/main/docs/openapi.yaml)
and [llama.cpp](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md).

## Source layout

| Path | What lives there |
| --- | --- |
| `Sources/AirStatKit` | Collectors, the sampling engine, settings, formatting. No UI. |
| `Sources/AirStatUI` | Menu bar drawing, panel, desktop widget, settings window, charts, design system. |
| `Sources/AirStats` | The executable, app delegate, and the probe and render commands. |
| `Tests/AirStatKitTests` | Contract tests for the collectors, plus settings and formatting. |
| `Scripts/build.sh` | Builds the binary and assembles the `.app`. |
| `Scripts/release.sh` | Signs, notarizes and packages the `.dmg` that ships. |
| `Scripts/appcast.py` | Writes a release into the appcast Sparkle reads. |
| `Scripts/benchmark.py` | Samples the menu bar monitors on your Mac over one shared window. |

`AirStatKit` never imports SwiftUI or AppKit, which is what lets the tests and the probe
run in a windowless process.

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) has the checks to run before a pull request and the
house rules.

## Contact

Bugs and feature requests go on the [issue tracker](https://github.com/byrencheema/airstats/issues).
For anything private, email [hello@airstats.app](mailto:hello@airstats.app).

## License

MIT. See [LICENSE](LICENSE).
