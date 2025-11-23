# AppManager AI Coding Instructions

You are an expert Vala/GTK developer working on AppManager, a Libadwaita utility for managing AppImages on GNOME.

## Architecture & Key Modules
- **Shared core (`src/core/`)**: Compiled into both the main application and the Nautilus extension. Changes here affect UI and extension simultaneously.
- **Entry points**:
   - `src/application.vala` / `src/main.vala`: Wire up `Adw.Application`, parse CLI flags (`--install`, `--uninstall`, `--is-installed`), decide between `DropWindow` and `MainWindow`.
   - `extensions/nautilus_extension.vala`: Nautilus context menus for `.AppImage` files; shells out to the main binary via the same CLI flags.
- **Core modules**:
   - `installer.vala`: Orchestrates install/uninstall, including move vs extract, 7z calls, `.desktop` rewrite, icon installation, and optional terminal symlink creation.
   - `installation_registry.vala`: JSON registry at `~/.local/share/app-manager/installations.json`. This is the single source of truth for install state—prefer it over raw filesystem checks.
   - `installation_record.vala`: Defines `InstallMode` enum (`PORTABLE`, `EXTRACTED`) and record (de)serialization helpers.
   - `app_image_metadata.vala`: Lightweight AppImage inspection (SHA256 checksum, display name, executability, basename helpers).
   - `app_image_assets.vala`: 7z-based helpers for extracting `.desktop` and icon assets into temp directories.
   - `app_paths.vala` / `app_constants.vala`: Centralized path and ID definitions (applications dir, extracted root, icons dir, desktop dir, registry file, application ID, MIME type).
   - `utils/file_utils.vala`: SHA256 checksums, unique path generation, recursive directory removal, temp dir creation, file copy utilities.
- **UI layer (`src/windows/`)**:
   - `drop_window.vala`: macOS-style drag-and-drop installer; allows choosing install mode, checks for upgrades via the registry, and calls `Installer`.
   - `main_window.vala`: Installed apps list backed by `InstallationRegistry`.
   - `dialog_window.vala`: Shared dialog patterns for confirmations and warnings.

## Installation & Desktop Integration Flows
- **Install modes** (`InstallMode` in `installation_record.vala`, logic in `installer.vala`):
   - `PORTABLE`: Copy AppImage into `AppPaths.applications_dir`, ensure executable, and call `finalize_desktop_and_icon()` with the `.AppImage` as both exec target and asset source.
   - `EXTRACTED`: Extract AppImage into `AppPaths.extracted_root` using `run_appimage_extract()`, move `squashfs-root` into a unique directory, copy the AppImage alongside, and point `Exec` to `AppRun` if present (fallback to the AppImage itself).
- **Registry lifecycle** (`InstallationRegistry`):
   1. `AppImageMetadata` computes a checksum; installer checks `registry.is_installed_checksum()` / `lookup_by_source()` before installing.
   2. On success, `registry.register(record)` persists JSON and emits `changed()` (UI listens to refresh views).
   3. `Installer.uninstall()` removes files/dirs, desktop entry, icon, and optional bin symlink, then calls `registry.unregister(record.id)`.
- **Desktop entry + icon handling** (`Installer.finalize_desktop_and_icon()` + `AppImageAssets`):
   - Extract `.desktop` and icons via `AppImageAssets.extract_desktop_entry()` / `extract_icon()` into a temp dir from `Utils.FileUtils.create_temp_dir()`.
   - Parse `Name`, `X-AppImage-Version`, `Terminal`, and `Icon` using `KeyFile` and save into the `InstallationRecord`.
   - Normalize a slug with `slugify_app_name()` and `derive_slug_from_path()`, possibly renaming the install path via `ensure_install_name()`.
   - Strip path + extension from the original `Icon` key to derive an icon name; store the icon file under `AppPaths.icons_dir` with that name + extension, and use only the bare icon name in the rewritten desktop file.
   - Generate `appmanager-<slug>.desktop` in `AppPaths.desktop_dir`, populated by `rewrite_desktop()`; update `record.desktop_file`, `record.icon_path`, and (for terminal apps) `record.bin_symlink` from `create_bin_symlink()`.
   - Temp extraction directories are automatically cleaned after installation completes.

## Conventions & Patterns
- **Language/stack**: Vala targeting GLib 2.74+, GTK4, Libadwaita. Use 4-space indentation and existing namespaces (`AppManager`, `AppManager.Core`, `AppManager.Utils`).
- **Error handling**:
   - Prefer `InstallerError` for install/uninstall failures: `ALREADY_INSTALLED`, `DESKTOP_MISSING`, `EXTRACTION_FAILED`, `SEVEN_ZIP_MISSING`, `UNINSTALL_FAILED`, `UNKNOWN`.
   - Wrap file I/O, JSON parsing, and subprocess spawning (`7z`, AppImage tools) in `try/catch (Error e)`; log via `warning()`, `debug()`, or `critical()`.
- **Temp dirs & cleanup**: Use `Utils.FileUtils.create_temp_dir()` and `DirUtils.mkdtemp()` with prefixes derived from `AppPaths`; temp directories are always auto-deleted after installation.
- **Registry vs filesystem**: For "is installed?" decisions, always consult `InstallationRegistry` (`is_installed_checksum`, `lookup_by_source`, `lookup_by_installed_path`) rather than relying solely on `File.query_exists()`.
- **Nautilus extension**: Links against `core_sources` (see `extensions/meson.build`) and uses the same CLI contract (`--install`, `--uninstall`, `--is-installed`). Any change in registry/CLI behavior must preserve extension compatibility.

## Build, Run, and Local Testing
- Configure and build:
   - `meson setup build`
   - `meson compile -C build`
- Run from the repo root:
   - `./build/src/app-manager`
- Install locally for extension testing:
   - `meson install -C build --destdir "$HOME/.local"`
   - Then restart Nautilus: `killall nautilus && nautilus &`
- CLI helpers used by Nautilus and scripts:
   - `app-manager --install /path/to/app.AppImage`
   - `app-manager --uninstall /path/or/checksum`
   - `app-manager --is-installed /path/to/app.AppImage`

## Testing & Debugging
- Manual flows: drag different AppImages (with/without icons, terminal vs GUI) onto `DropWindow` and verify registry + desktop entries.
- Nautilus: after a local install, confirm context menus on `.AppImage` files and that visibility matches registry state.
- Logging: run with `G_MESSAGES_DEBUG=all ./build/src/app-manager` to surface debug logs.
- Registry inspection: `cat ~/.local/share/app-manager/installations.json | jq` to confirm record schema and fields.

## When Modifying or Adding Code
- Prefer adding shared helpers to `src/core/` or `src/utils/` when behavior is reused between DropWindow, MainWindow, CLI, and the Nautilus extension.
- When altering installer/registry behavior, validate both the desktop UI flows and Nautilus extension behavior (after `meson install`).
- Keep installation paths, desktop naming (`appmanager-<slug>.desktop`), and icon naming (bare icon name, file under `AppPaths.icons_dir`) consistent with `finalize_desktop_and_icon()` rather than reimplementing path logic.
