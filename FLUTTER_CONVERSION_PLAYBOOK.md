# Electron → Native Flutter (Ubuntu / Yaru) Conversion Playbook

A battle-tested recipe for converting an Electron desktop app into a **native GTK Flutter
app** styled like a first-party Ubuntu application (GNOME *Resources*-style). This is the
exact process used to build **Iwatch** (https://github.com/papito0x1/Iwatch) from an
Electron + Chart.js app — it worked end to end, so follow it closely.

> Hand this file to the next Claude session along with the Electron repo and say:
> *"Convert this Electron app to a native Flutter Ubuntu app following FLUTTER_CONVERSION_PLAYBOOK.md."*

---

## 0. Environment (this machine)

- Flutter (stable) with Linux desktop enabled; toolchain: `clang cmake ninja pkg-config libgtk-3-dev`.
  Verify: `flutter doctor`, `flutter devices` (expect "Linux (desktop)").
- Python 3 + **Pillow** (`python3 -c "import PIL"`) for icon generation.
- `imagemagick` + `x11-utils` for screenshots (see §8).
- See `~/.claude/CLAUDE.md` for the machine-wide screenshot recipe (it survives repo deletion).

---

## 1. Understand the Electron app first

Read everything before writing Dart. Map each piece to its Flutter home:

| Electron piece | Inspect | Flutter destination |
| --- | --- | --- |
| `main.js` (main process) | IPC handlers, network/RPC, file/OS calls | a plain Dart **service** class (runs in-isolate; no IPC, no CORS) |
| `preload.js` | the `contextBridge` API surface | delete — call the service directly |
| `renderer.js` | state, polling, persistence, DOM updates | a `ChangeNotifier` **model** + widgets |
| `index.html` / CSS | layout, colours, components | Flutter widgets + a theme file |
| Chart.js / canvas | chart configs | **fl_chart** |
| `localStorage` | keys + shapes | **shared_preferences** (keys get a `flutter.` prefix on disk) |
| `BrowserWindow` | size, min size, maximize | **window_manager** |
| `shell.openExternal` | external links | **url_launcher** |

Note polling cadences, retry/backoff, chunking, caches, default-state logic — port them faithfully.

---

## 2. Scaffold + dependencies

```bash
# In the Electron repo root (keeps git history). Hyphenated dir names need --project-name.
flutter create --project-name <appname> --platforms=linux --org io.github.<ghuser> .
flutter pub add yaru fl_chart provider http shared_preferences url_launcher intl window_manager
rm -f test/widget_test.dart            # remove the counter test
```

`flutter create` does **not** overwrite an existing `.gitignore` — append Flutter ignores:
```
.dart_tool/
build/
.flutter-plugins*
linux/flutter/ephemeral/
/dist/
.idea/
*.iml
```
Move the old Electron sources into `legacy-electron/` (via `git mv`) instead of deleting — keeps provenance and is non-destructive.

---

## 3. Suggested file layout

```
lib/
  main.dart               entry, YaruTheme, window setup
  theme.dart              Ubuntu/Yaru palette + buildTheme(yaru.darkTheme)
  models/models.dart      plain data classes
  services/<x>_service.dart   port of main.js (http via package:http, in-isolate)
  state/<x>_model.dart    ChangeNotifier: state, polling timers, persistence, derived getters
  utils/format.dart       number/date formatters (use package:intl)
  screens/                home (layout), welcome (empty state), detail views
  widgets/                charts (fl_chart), sidebar tile, sections, dialogs, common
tool/
  make_icon.py            generates the app icon at all sizes (Pillow)
  build-deb.sh            assembles a .deb
  install-desktop.sh      installs icon + .desktop for the current user
legacy-electron/          original Electron app (reference)
```

---

## 4. Native Ubuntu look (the part that makes it feel first-party)

**a. Theme — drop the web app's colours, use the Ubuntu palette** (unless the user says otherwise):
```dart
class AppColors {
  static const windowBg = Color(0xFF1E1E1E);  // detail/content
  static const paneBg   = Color(0xFF242424);  // sidebar
  static const card     = Color(0xFF303030);  // boxed lists / chart cards
  static const border   = Color(0x14FFFFFF);
  static const text = Color(0xFFFFFFFF), muted = Color(0xFFADACAA);
  static const orange = Color(0xFFE95420);     // Ubuntu Orange (accent)
  static const aubergine = Color(0xFF77216F);  // brand gradient
  static const up = Color(0xFF2EC27E), down = Color(0xFFED333B);
}
```
Base the theme on Yaru: `YaruTheme(builder: (ctx, yaru, _) => MaterialApp(theme: buildTheme(yaru.darkTheme)))`,
and in `buildTheme` only override `colorScheme.primary = orange`, surfaces, scaffold bg.

**b. Native window chrome** — hide the GTK header bar and draw the Yaru title bar:
```dart
// main(): before runApp
await YaruWindowTitleBar.ensureInitialized();   // hides the GTK header bar via yaru_window_linux
```
Use `YaruWindowTitleBar` as the `Scaffold.appBar` (gives real close/min/max controls + drag).
For dialogs use `YaruDialogTitleBar` (its close defaults to `Navigator.maybePop`). Use `YaruSwitch`,
`YaruIconButton`. **Gotcha:** `YaruTitleBarGestureDetector` is not exported — for a custom draggable
header region use `window_manager`'s `DragToMoveArea` instead.

**c. GNOME *Resources*-style master–detail layout** (works great for "list of things + detail"):
- A **split header**: app brand over the sidebar (width ~280, wrapped in `DragToMoveArea`) on the left;
  a real `YaruWindowTitleBar` (page title + status + window controls) over the detail pane on the right.
- A **sidebar** of tiles; each tile = icon + label + value + a **live sparkline** (`fl_chart`), selected
  tile highlighted. Build a custom tile and manage selection yourself (don't fight a widget's index API).
- A **detail pane** with: bold `SectionHeader`s, a large area-chart **card** ("Usage"-style: chart + label
  + big value beneath), and an Adwaita **boxed list** of properties (rounded card, label-left/value-right
  rows separated by dividers). An `OptionRow` (label + trailing toggle) mirrors Resources' option rows.

**State gotcha:** keep the sidebar order **stable** across fast polling ticks and track **selection by id**
(not list index) — otherwise tiles reshuffle on each price/data tick and the selection jumps. Rebuild order
only on membership/sort changes.

---

## 5. App icon (Pillow, no SVG tools needed)

Write `tool/make_icon.py` that renders a **rounded-square (squircle)** with a diagonal Ubuntu
gradient (orange→aubergine) and a simple white glyph that says what the app does. Render at
`16,24,32,48,64,128,256,512` into `linux/packaging/icons/hicolor/<size>x<size>/apps/<APP_ID>.png`,
plus a `512`/`1024` master into `assets/icon/` for in-app use (register under `flutter: assets:`).
Supersample 4× then `LANCZOS` downscale for crisp edges. Preview by Reading the PNG; avoid hard
gradient seams (use a smooth alpha fade, not a hard rounded-rect overlay).

---

## 6. Packaging (.deb + desktop integration)

- **App ID / naming:** use `io.github.<ghuser>.<app>` for `APPLICATION_ID` (in `linux/CMakeLists.txt`),
  the `.desktop` filename, the icon filenames, and `StartupWMClass`. Set the window title in
  `linux/runner/my_application.cc` (both header-bar and non-header-bar branches) and add
  `gtk_window_set_icon_name("<APP_ID>")` + `gtk_window_set_default_icon_name(...)`.
- **`tool/build-deb.sh`:** `flutter build linux --release`, copy `build/linux/x64/release/bundle/` →
  `usr/lib/<app>/`, symlink `usr/bin/<app>` → `../lib/<app>/<app>`, install hicolor icons + `.desktop`,
  write `DEBIAN/control` (`Depends: libgtk-3-0, libglib2.0-0, libstdc++6, zlib1g`) and a `postinst` that
  runs `gtk-update-icon-cache` / `update-desktop-database`. Build with `dpkg-deb --build --root-owner-group`.
- **`tool/install-desktop.sh`:** copies icons + `.desktop` into `~/.local/share` for the current user.

---

## 7. Verify

```bash
flutter analyze                 # expect: No issues found
flutter build linux --release   # expect: ✓ Built .../bundle/<app>
timeout 10s ./build/linux/x64/release/bundle/<app> >/tmp/run.log 2>&1; echo $?   # 124 = ran full 10s, OK
```
Benign log lines: `Unable to load … cursor theme`, `Timed out waiting for OpenGL frame of size …`.

---

## 8. Screenshots (for the README) — the method that actually works here

GNOME Wayland blocks most capture paths. **Do NOT** use the GNOME D-Bus screenshot (AccessDenied),
`grim` (not wlroots), `scrot`/root-grab (rootless Xwayland = empty), or headless `xvfb` + software GL
(Flutter renders **pure black**). Instead run on the **real session forcing X11** and grab the window by id:
```bash
export DISPLAY=:0 GDK_BACKEND=x11
./build/linux/x64/release/bundle/<app> >/tmp/app.log 2>&1 &
APP=$!
for i in $(seq 1 15); do sleep 1; \
  WID=$(xwininfo -root -tree 2>/dev/null | grep -iE '"<WindowTitle>"' | grep -oE '0x[0-9a-f]+' | head -1); \
  [ -n "$WID" ] && break; done
sleep 8
import -window "$WID" /tmp/shot.png      # ImageMagick XGetImage on the specific window
kill $APP
convert /tmp/shot.png -format %c histogram:info:   # all-one-colour ⇒ failed render, retry
```
**Populated screen:** pre-seed `~/.local/share/<APP_ID>/shared_preferences.json` with `flutter.`-prefixed
keys (e.g. a default/demo item) before launching. **Privacy:** never screenshot the user's real/personal
data — use a built-in demo/sample. Embed via `docs/screenshot.png` + `<img src="docs/screenshot.png">` in README.

---

## 9. Publish to GitHub (+ identity hygiene)

```bash
gh repo create <App> --public --description "..."
git remote add publish https://github.com/<ghuser>/<App>.git
git push -u publish <branch>:main
gh release create v1.0.0 --repo <ghuser>/<App> --target main --title "<App> 1.0.0" \
  --notes "..." dist/<app>_1.0.0_amd64.deb
```
**Scrub identity if the user cares (they often do):**
- Check authors/committers: `git log --pretty='%an <%ae> | %cn <%ce>'` and commit-message bodies for any
  other name/email/org. Reattribute with `git filter-branch --env-filter` if needed.
- App ID, `.deb` `Maintainer`, and `.desktop` should not embed a personal domain/email.
- **Important:** force-pushing rewritten history does **not** remove old commits — they linger as dangling
  objects fetchable by SHA (and public SHAs from a source repo can link accounts). To truly purge, the repo
  must be **deleted and recreated** (needs the `delete_repo` token scope: `gh auth refresh -s delete_repo`,
  or the user deletes it in Settings), then push the clean single/'s history fresh.

---

## 10. Pitfalls log (things that cost time here)

- Flutter under headless Xvfb + llvmpipe = black frames → screenshot on the real session (§8).
- `window_manager` defers `show()` until a WM maps the window; fine on the real GNOME session.
- `flutter create` won't touch an existing `.gitignore` → add Flutter ignores manually.
- `YaruTitleBarGestureDetector` isn't exported → use `DragToMoveArea`.
- Public-RPC / API throttling: keep the Electron app's retry/backoff + request chunking.
- Don't reshuffle list widgets on every poll tick; stable order + selection-by-id.

---

*Reference implementation: Iwatch — github.com/papito0x1/Iwatch (see lib/, tool/, linux/packaging/).*
