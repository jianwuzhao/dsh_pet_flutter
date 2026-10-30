# dsh_pet_flutter

[简体中文](README.md) | [English](README.en.md)

## About

A Flutter cross-platform desktop pet forked from dsh-pet: transparent always-on-top window, sprite animations, and a local event server that links with AI tools such as Trae CN / ChatGPT / WorkBuddy. The goal is to evolve it into a "local-first personal assistant with its own brain" (four-layer core architecture: Gateway → AI → Persona → Learning).

Key features:

- **Pet**: transparent frameless always-on-top window, 100+ sprite animations, physics-based roaming and dragging, click-through outside hit areas
- **Interaction**: double-click input panel, context menu, bubbles (status / thinking / memes)
- **Linkage**: local event server (HTTP port 7341 + token auth) receives status pushes from AI tools; input can be dispatched to the linked app (Trae extension bridge)
- **macOS tray**: resident menu bar with show/hide, click-through toggle, quit; accessibility permission detection
- **Toolchain**: petctl CLI, asset fetch/convert scripts, Trae skill installer

Local data directory: `~/.dsh_pet_flutter/` (config.jsonc, token, logs/).

## Installation & Usage

### macOS (Supported)

```bash
flutter pub get
flutter run -d macos          # dev run
flutter test                  # full test suite
flutter build macos --release # release build
```

App Sandbox is disabled in `DebugProfile.entitlements` / `Release.entitlements`; grant the "Accessibility" permission in System Settings for cross-app linkage.

### Windows (Not yet supported)

> Native click-through / tray / input injection are not implemented yet. Installation instructions will be added here.

### Web (Not yet supported)

> Platform degradation verification is pending. Installation instructions will be added here.

### Android (Not yet supported)

> Platform degradation verification is pending. Installation instructions will be added here.

### petctl CLI

Once the pet is running, use `tools/petctl.sh` to push status or dispatch text:

```bash
tools/petctl.sh health                    # is the pet running
tools/petctl.sh status thinking "working" # thinking|working|result|waiting|success|error
tools/petctl.sh say "hello"               # bubble only, no status change
tools/petctl.sh dispatch "write a func"   # dispatch to the linked app
tools/petctl.sh bridge                    # Trae extension bridge diagnostics
```

### Trae CN Extension

Load `trae-extension/` as an extension directory into Trae CN (or install the pet-broadcast skill via `tools/install_trae_skill.sh`), reload the window, and it will receive dispatches from the pet.

## Directory Structure

```
lib/
  app/          # Assembly & stage (pet_app / pet_stage / flyout_layout)
  core/         # Infrastructure: jsonc config, paths, single instance, Result
  platform/     # Native channels: click-through / cursor / frontmost app / content read / input injection / tray
  features/
    pet/        # Physics / roaming / pose machine / sprite rendering / hit-test
    linkage/    # Adapter registry, BridgeHub, Dispatcher, event server, status aggregator
    ai/         # Existing LLM config (extended into the ai/ layer in M2)
    chat/       # Input panel (currently pure forwarding)
    bubble/     # Bubbles
    menu/       # Context menu & action picker
    settings/   # Settings page
tools/          # petctl.sh, asset scripts, gen_manifest.dart, install_trae_skill.sh
trae-extension/ # Trae CN bridge extension (dsh-pet-bridge)
vendor/         # Upstream dsh-pet source assets (webm + config, with LICENSE)
assets/         # Converted webp animations, memes, fonts, default config
docs/           # Doc resources (sponsor QR codes, etc.)
```

## Remaining Work

| Feature | Status | Updated | Contributor |
|---|---|---|---|
| Windows platform (click-through / tray / input injection) | Not supported yet | 2026-10-30 | zhaodaye2022 |
| Web platform degradation verification | Not supported yet | 2026-10-30 | zhaodaye2022 |
| Android platform degradation verification | Not supported yet | 2026-10-30 | zhaodaye2022 |
| M1 Infrastructure & config extension (local profile store) | Not started | 2026-10-30 | zhaodaye2022 |
| M2 AI layer (three LLM providers & fallback chain) | Not started | 2026-10-30 | zhaodaye2022 |
| M3 Gateway layer (unified entry / privacy center / global hotkey) | Not started | 2026-10-30 | zhaodaye2022 |
| M4 Persona layer · emotion loop & interruption budget | Not started | 2026-10-30 | zhaodaye2022 |
| M5 Persona layer · memory store & conversation service | Not started | 2026-10-30 | zhaodaye2022 |
| M6 Learning layer (feedback loop / policy versioning) | Not started | 2026-10-30 | zhaodaye2022 |
| M7 Final verification (integration & memory regression) | Not started | 2026-10-30 | zhaodaye2022 |

Explicitly deferred: ASR/TTS (interface only), retrieval/knowledge learning (interface only), parameter learning, streaming replies, automatic focus-mode detection.

## Sponsor

If this project helps you, buy the author a coffee~

| Alipay | WeChat |
|:---:|:---:|
| ![Alipay](docs/sponsor/zfb.jpg) | ![WeChat](docs/sponsor/wx.png) |

## License

Free for personal use; **commercial use is prohibited**. For commercial licensing, contact the author. See [LICENSE](LICENSE).

Animation and config assets come from the upstream dsh-pet project (PC2005-cloud, MIT), under its original license, see [vendor/LICENSE-dsh-pet.txt](vendor/LICENSE-dsh-pet.txt).
