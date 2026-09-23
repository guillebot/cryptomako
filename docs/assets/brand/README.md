# CryptoMako brand pack

Canonical mark for **all platforms**: filled cyan bucket + dark shield + cyan padlock on a dark rounded square.

Locked user pick: `icon-master.png` (source of truth for the lock). App icons are square crops/exports of that mark. Sibling repos (**iOS**, **Android**, Windows tray, Linux desktop) should pull assets from this folder — do **not** invent alternate marks.

## Files

| File | Use |
|------|-----|
| `icon-master.png` | Locked user pick (presentation / master reference) |
| `icon.png` | 1024×1024 app icon (primary) |
| `icon-{16,32,48,256,512,1024}.png` | Sized app icons for stores / installers / docs |
| `menubar-template-white.png` | **Canonical** macOS `NSStatusItem` template (cyan-only style: white bucket + white padlock, dark shield as cutout). Use with `isTemplate = true`. |
| `menubar-template-black.png` | Inverse template for light menu bars / docs |
| `menubar-template-white-silhouette.png` | Optional silhouette variant (not primary) |
| `menubar-template-black-silhouette.png` | Optional silhouette variant (not primary) |
| `menubar-macos-chosen.png` | Reference render of the locked cyan-only menu-bar style |
| `tray-windows.png` | Windows system-tray / docs preview |
| `linux-desktop.png` | Linux `.desktop` / docs preview |
| `readme-hero.png` | GitHub / marketing hero strip |
| `favicon.png` | Web / docs favicon preview |

## Platform integration

| Platform | Path / note |
|----------|-------------|
| **macOS (this repo)** | App icon: `Support/Brand/Assets.xcassets` + `Sources/CryptoMakoApp/Resources/AppIcon.png`. Menu bar: `Sources/CryptoMakoApp/Resources/MenuBarTemplate.png` ← copy of `menubar-template-white.png` (wired in `BrandIcon.templateStatusBarImage()`). |
| **Linux** | Prefer `linux-desktop.png` / `icon.png` for `.desktop` `Icon=` and packaging (see `linux/README.md`). |
| **Windows** | Prefer `tray-windows.png` / `icon.png` for tray and Avalonia window icon when that tree lands. |
| **iOS / Android** | Sibling repos: copy from `docs/assets/brand/` in this monorepo; keep the same cyan-bucket mark. |

## TODO (follow-ups)

- [ ] Refresh `Support/Brand/Assets.xcassets/AppIcon.appiconset/*` and `Resources/AppIcon.png` from `icon-*.png` (dock / About still use the previous mark until that lands).
- [ ] Wire Linux `.desktop` / Windows tray installers to these files when packaging next cuts.
- [ ] Sync iOS + Android sibling app icons from this pack.

## License

Same as the CryptoMako repository (AGPLv3). Brand assets are part of the project tree.
