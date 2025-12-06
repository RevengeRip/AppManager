# AppManager Architecture

AppManager is a Libadwaita + GTK4 Vala application that provides a rich, guided workflow for installing and managing AppImages on GNOME 45–49 desktops. The solution consists of three major pieces:

1. **Core Application (`src/`)**
   - `AppManager.Application` (`application.vala`) bootstraps an `Adw.Application`, parses URI/file arguments, and decides whether to show the drop-style install window or the main UI.
   - `MainWindow` (`windows/main_window.vala`) is an `Adw.Window` containing an `Adw.NavigationView`. It displays a list of installed AppImages (grouped by install mode) backed by the registry, and allows navigation to details.
   - `DetailsWindow` (`windows/details_window.vala`) provides a detailed view of a specific installation, allowing the user to uninstall or view metadata.
   - `DropWindow` (`windows/drop_window.vala`) surfaces when the app is launched with an AppImage. It shows a two-column Adwaita card mimicking the macOS drag-to-install sheet: left is the source AppImage icon, right is the `~/Applications` destination icon. Dragging the app icon onto the destination (or clicking an Install button) triggers the installer pipeline.
   - `BackgroundUpdateService` (`core/background_update_service.vala`) wraps the XDG Background portal, schedules lightweight update checks over the registry, and emits a signal when updates are found so `Application` can notify the user.
   - `Installer` (`core/installer.vala`) encapsulates both install flows:
     * **Portable Move** – executable AppImages are chmod-ed (if needed), renamed if collisions occur, moved into `~/Applications`, and their `.desktop` launcher is unpacked with `7z` and rewritten to point the `Exec` line directly at the `.AppImage`.
     * **Extracted Install** – non-executable AppImages are fully extracted with `7z` into `~/Applications/.installed/<name>/`. The `.desktop` file’s `Exec` now targets the `AppRun` entry point inside the extracted tree.
     Both flows also copy icons where available, refresh the desktop database, and emit installation metadata.
   - `InstallationRegistry` (`core/installation_registry.vala`) persists install state inside `~/.local/share/app-manager/installations.json`, enabling detection of “already installed” files for UI and CLI logic. Uses `json-glib-1.0`.
   - `AppImageMetadata` (`core/app_image_metadata.vala`) performs lightweight inspection: derives a user-friendly name, determines whether the file is executable, probes for embedded desktop/icon resources via `7z l`, etc.
   - `AppPaths` & `AppConstants` (`core/`) provide centralized definitions for paths (`~/Applications`, `~/.local/share/applications`, etc.) and constants.
   - `Utils` (`utils/`) contains helpers for file operations (`file_utils.vala`) and UI tasks (`ui_utils.vala`).

2. **Data & Integration Assets (`data/`)**
   - `app-manager.desktop` registers the app as the default handler for the `application/x-iso9660-appimage` MIME type and exposes a regular launcher for opening the main window.
   - `com.github.AppManager.gschema.xml` defines GSettings keys used by the app.
   - `app-manager.metainfo.xml` and icons are also stored here.
   - Background update keys (`auto-check-updates`, `update-check-interval`, `last-update-check`, `background-permission-requested`) live in GSettings to track scheduling and permission state.

3. **Build System (Meson + Ninja)**
   - Top-level `meson.build` orchestrates building the executable, runs `glib-compile-schemas`, and installs desktop/metainfo files.
   - The project assumes `valac`, `libadwaita-1`, `gtk4`, `gio-2.0`, `glib-2.0`, `json-glib-1.0`, `gee-0.8`, and `p7zip-full` at runtime.

## Runtime Flow

1. A user double-clicks an AppImage.
2. Because the `.desktop` file declares the AppImage MIME type, GNOME launches AppManager with the AppImage path argument.
3. `DropWindow` appears displaying the originating AppImage icon and the `~/Applications` folder badge. When the user drags from left to right (or hits Install), Installer kicks in.
4. Installer chooses the correct flow (executable vs. non-executable) and performs: move/extract, `.desktop` rewrite, icon installation, registry update, and sends desktop notifications for success/failure.

## Background Updates

- On first launch with auto-checks enabled, `Application` asks libportal for background permission through `BackgroundUpdateService`. Without consent, no background checks run.
- When the configured interval elapses, `BackgroundUpdateService` iterates registry entries and calls `Updater.check_for_update_async`, which fetches release metadata (no downloads) to determine if newer versions exist.
- The service emits `updates_found` so the application can send a desktop notification that re-activates the app; users still initiate downloads manually from the UI.

## Main Window Content

- List of installed applications grouped by "Portable" and "Extracted".
- Navigation to `DetailsWindow` for each app.
- Settings integration (window size, etc.).

This document should be kept in sync with future enhancements so contributors understand system boundaries quickly.
