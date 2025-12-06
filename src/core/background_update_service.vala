using Gee;
using Xdp;
using GLib;

namespace AppManager.Core {
    public class BackgroundUpdateService : Object {
        private GLib.Settings settings;
        private InstallationRegistry registry;
        private Updater updater;
        private Xdp.Portal? portal;
        private string update_log_path;

        public BackgroundUpdateService(GLib.Settings settings, InstallationRegistry registry, Installer installer) {
            this.settings = settings;
            this.registry = registry;
            this.updater = new Updater(registry, installer);
            this.update_log_path = Path.build_filename(AppPaths.data_dir, "updates.log");
        }

        public async bool request_background_permission(Gtk.Window? parent, Cancellable? cancellable = null) {
            if (settings.get_boolean("background-permission-requested")) {
                return true;
            }

            portal = new Xdp.Portal();

            try {
                var message = I18n.tr("AppManager needs permission to check for updates in the background");
                var granted = yield portal.request_background(null, message, null, Xdp.BackgroundFlags.AUTOSTART, cancellable);
                settings.set_boolean("background-permission-requested", true);
                return granted;
            } catch (Error e) {
                warning("Failed to request background permission: %s", e.message);
                return false;
            }
        }

        public async void perform_background_check(Cancellable? cancellable = null) {
            log_debug("background update: start");

            if (!settings.get_boolean("auto-check-updates")) {
                log_debug("background update: auto-check disabled; skipping");
                return;
            }

            var records = registry.list();
            if (records.length == 0) {
                log_debug("background update: no installed records");
                settings.set_int64("last-update-check", new GLib.DateTime.now_utc().to_unix());
                return;
            }

            var results = updater.update_all(cancellable);

            int updated = 0;
            int skipped = 0;
            int failed = 0;

            foreach (var result in results) {
                switch (result.status) {
                    case UpdateStatus.UPDATED:
                        updated++;
                        log_debug("background update: updated %s".printf(result.record.name ?? result.record.id));
                        append_update_log("UPDATED %s".printf(result.record.name ?? result.record.id));
                        break;
                    case UpdateStatus.SKIPPED:
                        skipped++;
                        append_update_log("SKIPPED %s: %s".printf(result.record.name ?? result.record.id, result.message));
                        break;
                    case UpdateStatus.FAILED:
                        failed++;
                        append_update_log("FAILED %s: %s".printf(result.record.name ?? result.record.id, result.message));
                        break;
                }
            }

            log_debug("background update: finished (updated=%d skipped=%d failed=%d)".printf(updated, skipped, failed));
            settings.set_int64("last-update-check", new GLib.DateTime.now_utc().to_unix());
        }

        public bool should_check_now() {
            if (!settings.get_boolean("auto-check-updates")) {
                return false;
            }

            int64 last_check = settings.get_int64("last-update-check");
            int64 now = new GLib.DateTime.now_utc().to_unix();
            int interval = settings.get_int("update-check-interval");

            return (now - last_check) >= interval;
        }

        private void log_debug(string message) {
            debug("%s", message);
            append_update_log(message);
        }

        private void append_update_log(string message) {
            try {
                DirUtils.create_with_parents(AppPaths.data_dir, 0755);
                var ts = new GLib.DateTime.now_local().format("%FT%T%z");
                var line = "%s %s\n".printf(ts, message);
                var file = FileStream.open(update_log_path, "a");
                if (file != null) {
                    file.puts(line);
                    file.flush();
                }
            } catch (Error e) {
                warning("Failed to write update log: %s", e.message);
            }
        }
    }
}
