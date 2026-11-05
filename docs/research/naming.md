# Naming research: project, binary/pub package, Zed extension id, debug adapter

Date: 2026-11-03. Read-only research; nothing was created, posted or published. Tags: [verified] = queried/read directly; [unverified] = could not be checked here.

Method notes. pub.dev, crates.io and raw.githubusercontent.com API calls worked (curl with the CA bundle). `formulae.brew.sh` and `flutter.dev`/`docs.flutter.dev` are blocked by the session proxy (403/ENOTFOUND). Homebrew was therefore checked via raw `Formula/<x>/<name>.rb` and `Casks/<x>/<name>.rb` files in homebrew-core and homebrew-cask (404 = absent), and Scoop via raw `bucket/<name>.json` in `ScoopInstaller/Main` and `ScoopInstaller/Extras` (master). `gh api` against GitHub repos worked only for search endpoints (direct repo content calls were refused by the session).

## 1. CLI binary / pub package candidates

| Candidate | pub.dev | crates.io | GitHub repos named this (Flutter/Zed related) | Homebrew formula/cask | Scoop Main/Extras | Verdict |
|---|---|---|---|---|---|---|
| `flutter_rd` | free (404) | free (404) | `Packiyaraj2109/flutter_rd`, `qhqhqhq/flutter_rd` (0 stars, unrelated, Dart/empty); `brainmentorspvtltd/RD_Flutter` (unrelated) | free | free | free in registries, mild GitHub clutter; underscore is awkward to type for a CLI |
| `frd` | free (404) | TAKEN: https://crates.io/crates/frd (Rust "interactive cargo / profile tuning" tool, 76 downloads) | no Flutter repo; many unrelated `FRD*` iOS/Scala repos | free | free | cross-namespace conflict with a Rust CLI called `frd`; also cryptic. Avoid |
| `flrd` | free | free | `sujanan100/flrd`, `r-universe/flrd`, `flrd/*` (R user) - unrelated | free | free | free everywhere; unpronounceable, not guessable |
| `rdflutter` | free | free | only `rhodesRowan/RDFlutterFirebaseAuthentification` (unrelated) | free | free | free, but "flutter" in the package name invites trademark/confusion, reads backwards |
| `fluttrd` | free | free | `bensonk/FluttrDroid` (unrelated, "fluttr") | free | free | free; looks like a typo of "flutter"/"fluttr" |
| `flutter_run_debug` | free | free | `Punlork/flutter_runtime_debugger` (different name), `saadbtch/run-and-debug-flutter` (see note) | free | free | free but long to type; underscore name unsuited for a CLI |

Extra check suggested by the results: none of the six names is in Homebrew core/cask or Scoop Main/Extras [verified via raw 404s, with the caveat that other Scoop buckets and winget were not checked].

Note on `saadbtch/run-and-debug-flutter`: a GitHub repo of exactly the project repo's name, created 2026-11-03T19:19Z, 0 size, no description. It is probably this project's own repo (the task says the repo already exists), so treat it as ours; if it is not, check ownership. [unverified which account owns the project repo]

## 2. Zed extension id candidates

Source: https://raw.githubusercontent.com/zed-industries/extensions/main/extensions.toml fetched 2026-11-03 (6460 lines). [verified]

| Candidate id | In `extensions.toml`? | Notes |
|---|---|---|
| `flutter-run-debug` | free | does not carry the `-debugger` suffix the prerequisites suggest |
| `flutter-run-debugger` | free | follows suffix guidance; reads slightly odd ("run debugger") |
| `flutter-rd-debugger` | free | follows suffix guidance; "rd" is opaque in the registry list |

Existing ids containing "flutter": only `flutter-snippets`, `freezed-dart-flutter-snippets`, `riverpod-dart-flutter-snippets`. Earlier finding (zed-extension-registry.md): `flutter`, `flutter-debug`, `flutter-debugger`, `flutter-dap` are also free. Rules: kebab-case, no "zed"/"extension", debugger-only should end `-debugger` (see docs/research/zed-extension-registry.md section 3).

Unregistered Flutter debug extensions in the wild (GitHub repos, not in the registry as flutter-*): `sgruhier/zed-flutter-debug`, `xdkomel/flutter-zed`, `iWisp360/zed-flutter`, `gusentanan/zed-fl`, `kdbhalala/Flutter`, `Volgar04/flutter_zed_debugger`; plus `HelgeSverre/gh-packages-zed` also matched the code search for `debug_adapters.Flutter` (a seventh holder not in the brief) [verified by `search/code`, 6 hits].

## 3. Debug adapter name candidates

Code search `"debug_adapters.<Name>" filename:extension.toml` [verified]:

| Adapter name | Used in the wild? | Notes |
|---|---|---|
| `Flutter` | TAKEN by 7 repos (list above + `HelgeSverre/gh-packages-zed`; `zed-extensions/dart` also matched the broader query, with its own adapter `Dart`) | collision, silent overwrite |
| `FlutterRD` | free (0 hits) | one token, no spaces/ampersand, typable; looks like the CLI name |
| `flutter-rd` | free (0 hits) | matches kebab style, but the other adapters in the ecosystem use PascalCase (`Dart`, `Xdebug`) |
| `Flutter-RD` | free (not searchable separately since GitHub code search is case-insensitive; same 0 hits as above) | mixed style; easy to mistype case |
| `Flutter Run & Debug` | free (0 hits for `"Flutter Run" "debug_adapters"`) | spaces and `&` are legal TOML keys only when quoted (`[debug_adapters."Flutter Run & Debug"]`), must be JSON-escaped nowhere else but is clumsy to type in debug.json and in schema file names (`debug_adapter_schemas/NAME.json`); not recommended |

Caveat: GitHub code search indexes only a sample of repos; a free result is not proof that nobody uses the name [unverified exhaustiveness].

## 4. Trademark guidance

- Source read: the Flutter brand page source (https://github.com/flutter/website, `sites/www/lib/src/pages/brand_page.dart`, which backs https://flutter.dev/brand), and it links to "Flutter Trademark Guidelines" at https://docs.flutter.dev/brand. The live pages and the linked guidelines page could not be fetched (network blocked), so the guidelines page itself is [unverified]; I read only the brand page source. [verified for the quote below]
- Quote (brand page, Flutter logo section): "Do not use the Flutter mark or any variant of the Flutter mark in conjunction with the overall name of your application, product, service, or website. Do not alter or use the Flutter mark in a way that may be confusing or misleading, and never use Flutter branding as the most prominent element on your page."
- Note this passage is about the logo/mark. It does not recommend a "X for Flutter" naming pattern, nor give an explicit "may/may not put Flutter in a project name" rule in what I could read. Whether "X for Flutter" is endorsed is therefore [unverified]. Practical reading: descriptive, factual use of the word (e.g. "debugger for Flutter apps") is the common nominative-use convention and is widespread (flutter-snippets, Flutter extensions in many stores), but do not use the Flutter logo, and avoid names that imply official status (no "Official", no bare "Flutter Debugger" as a brand, no Flutter-blue logo clone).
- Recommendation derived: put "Flutter" only in descriptive text ("... for Flutter"), keep the actual product/binary/adapter names distinctive and non-Flutter-led, and add a disclaimer line to the README: "Not affiliated with or endorsed by Google or the Flutter team. Flutter and Dart are trademarks of Google LLC." (wording is ours; trademark ownership statement is standard, not quoted from a source).
- Someone with legal interest should read https://docs.flutter.dev/brand once from an unrestricted network; flutter.dev/docs hosts must be allowed in the session network settings to do this from here.

## 5. Recommendation

1. Project display name: **Run & Debug for Flutter**. Matches the repo `run-and-debug-flutter`, describes the VS Code-style feature, and uses "Flutter" only descriptively after "for". Short form in prose: "Run & Debug". Add the not-affiliated disclaimer.
2. Binary / pub package name: **`flutter_rd`** (executable also `flutter_rd`). Free on pub.dev, crates.io, Homebrew and Scoop; shares the "rd" token with the extension id and adapter name; avoids `frd` (taken on crates.io by an unrelated Rust CLI) and the typo-like `fluttrd`. Downside: the underscore is slightly awkward to type and the name leads with the word "flutter" (descriptive use, no logo; common for pub packages). Free fallback if trademark exposure or typing matters more: `flrd`. [judgement]
3. Zed extension id: **`flutter-rd-debugger`**. Free in the registry; ends in `-debugger` per the prerequisites; matches the binary name (`flutter_rd`) so users and reviewers connect them. Runner-up `flutter-run-debugger`, which is more self-explanatory but unrelated to the binary name.
4. Debug adapter name: **`FlutterRD`**. Free in code search (0 hits), single PascalCase token consistent with `Dart`/`Xdebug`, easy to type in `.zed/debug.json` as `"adapter": "FlutterRD"`, needs no quoting in TOML or filesystem-safe schema file name (`debug_adapter_schemas/FlutterRD.json`), and avoids the `Flutter` collision (7 holders). Do not use `Flutter Run & Debug` (clumsy, quoting) or bare `Flutter`.

Open items for a human: confirm the project repo ownership (`saadbtch/run-and-debug-flutter`), re-check all names immediately before publishing (a free name is not reserved), and read docs.flutter.dev/brand directly.

## Correction note (2026-11-05)
This research is historical. On 2026-11-05 the user chose the name **zed-flutter-run**, which replaces the names recommended above (`flutter_rd`, `FlutterRD`, `flutter-rd-debugger`, repo `run-and-debug-flutter`). The new names, with their availability checks, are in [ADR 0008](../decisions/0008-rename-to-zed-flutter-run.md). The availability tables above describe the old candidates only.
