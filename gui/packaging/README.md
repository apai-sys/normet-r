# Building normet-r GUI installers

This is a Qt front-end only — computation runs in R subprocesses via
`normet_r_gui/bridge.R`, executed by the *target machine's* `Rscript` (with
the normet R package installed). R itself is never bundled; only the bridge
script ships inside the app. That keeps the frozen app small and, more
importantly, cross-platform — PySide6 + matplotlib on the Python side, plain
`Rscript` calls on the R side.

PyInstaller **cannot cross-compile** — each OS's installer must be built on
that OS. The supported path is GitHub Actions
(`../.github/workflows/build-gui.yml`), one spec, three OSes.

## Local build (macOS only)

```bash
packaging/macos/build_dmg.sh /path/to/python   # -> dist/macos/normet.app + .dmg
```

## Local build (any OS, onedir — no installer wrapper)

```bash
pip install -e . pyinstaller
pyinstaller --noconfirm packaging/normet_r_gui.spec   # -> dist/normet/
```

## All three platforms via GitHub Actions

The workflow (at the repo root, `working-directory: gui`) runs a matrix on
`macos-latest`, `windows-latest`, `ubuntu-latest`. Each runner installs the
Python/Qt deps (no R), runs PyInstaller (`packaging/normet_r_gui.spec` or, on
macOS, `packaging/macos/build_dmg.sh`), then packages its native installer:

| OS | output |
|----|--------|
| macOS | `normet-<version>-macos-<arch>.dmg` (drag-to-Applications) |
| Windows | `normet-setup-<version>.exe` (Inno Setup installer) |
| Linux | `normet-<version>-x86_64.AppImage` (chmod +x, double-click) |

Trigger it by pushing to `main` (path: `gui/**`), or manually from the
Actions tab (`workflow_dispatch`).

## Packaging files

- `normet_r_gui.spec` — cross-platform PyInstaller spec (macOS `.app` BUNDLE;
  Windows/Linux ship the COLLECT onedir `dist/normet/`). Version is read from
  `gui/pyproject.toml` at build time. Bundles `normet_r_gui/bridge.R` as a
  data file.
- `assets/normet.icns` / `normet.ico` / `normet.png` — per-OS icons, generated
  by `assets/make_icon.py` (Pillow). Re-run it if the design should change.
- `packaging/windows/installer.iss` — Inno Setup script.
- `packaging/linux/build_appimage.sh` — AppDir + appimagetool.
- `launcher.py` — the frozen entry point, shared by every OS's build.

## Runtime requirement (all platforms)

Every installer produced here needs R (with the normet R package) already
installed on the machine that *runs* the app — R → Locate Rscript… lets the
user point the app at a non-default install. This is unrelated to the build
machine, which only needs Python + PySide6 + PyInstaller. Transport Studio's
GeoJSON/Shapefile source-region loading additionally needs the R `sf`
package (`install.packages("sf")`) on the machine running the app.

## Notes / caveats

- The CI smoke-test job only constructs `MainWindow` offscreen (Qt/Python
  side) — it does not install R, so it can't exercise the bridge itself.
  Test any bridge.R change locally with real R before relying on CI alone.
- Linux GUI apps occasionally miss system `xcb` libs at runtime on minimal
  distros; the CI smoke-test job installs `libegl1 libgl1 libxkbcommon0
  libdbus-1-3 libxcb-cursor0` — mirror that list if the AppImage fails to
  start on a target distro.
- The Windows/Linux legs have not been run end-to-end (only the macOS spec
  path is verified locally) — the first GitHub Actions run on a pushed branch
  is the real test for those two.
