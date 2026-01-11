using Gee;
using GLib;

namespace AppManager.Core {
    public class BackgroundUpdateService : Object {
        private GLib.Settings settings;
        private InstallationRegistry registry;
        private Updater updater;
        private string update_log_path;

        public BackgroundUpdateService(GLib.Settings settings, InstallationRegistry registry, Installer installer) {
            this.settings = settings;
            this.registry = registry;
            this.updater = new Updater(registry, installer);
            this.update_log_path = Path.build_filename(AppPaths.data_dir, "updates.log");
        }

        /**
         * Writes the autostart desktop file to enable background updates.
         * Public so PreferencesDialog can use it when the user enables auto-updates.
         */
        public static void write_autostart_file() {
            try {
                var autostart_dir = Path.build_filename(Environment.get_user_config_dir(), "autostart");
                DirUtils.create_with_parents(autostart_dir, 0755);
                
                var autostart_file = Path.build_filename(autostart_dir, "com.github.AppManager.desktop");
                var exec_path = AppPaths.current_executable_path ?? "app-manager";
                var content = """[Desktop Entry]
Type=Application
Name=AppManager Background Updater
Exec=%s --background-update
X-GNOME-Autostart-enabled=true
NoDisplay=true
X-XDP-Autostart=com.github.AppManager
""".printf(exec_path);
                FileUtils.set_contents(autostart_file, content);
                debug("Autostart file written to %s", autostart_file);
            } catch (Error e) {
                warning("Failed to write autostart file: %s", e.message);
            }
        }

        /**
         * Removes the autostart desktop file to disable background updates.
         * Public so PreferencesDialog can use it when the user disables auto-updates.
         */
        public static void remove_autostart_file() {
            var autostart_file = Path.build_filename(
                Environment.get_user_config_dir(),
                "autostart",
                "com.github.AppManager.desktop"
            );
            var file = File.new_for_path(autostart_file);
            if (file.query_exists()) {
                try {
                    file.delete();
                    debug("Removed autostart file: %s", autostart_file);
                } catch (Error e) {
                    warning("Failed to remove autostart file: %s", e.message);
                }
            }
        }

        /**
         * Spawns the background daemon process if not already running.
         * Called when user enables auto-updates in preferences.
         */
        public static void spawn_daemon() {
            // Check if daemon is already running
            if (is_daemon_running()) {
                debug("Background daemon already running, not spawning another");
                return;
            }

            try {
                var exec_path = AppPaths.current_executable_path ?? "app-manager";
                string[] argv = { exec_path, "--background-update" };
                Pid child_pid;
                Process.spawn_async(
                    null,
                    argv,
                    null,
                    GLib.SpawnFlags.SEARCH_PATH | GLib.SpawnFlags.DO_NOT_REAP_CHILD,
                    null,
                    out child_pid
                );
                debug("Spawned background daemon with PID %d", (int) child_pid);
                
                // Don't wait for the child - let it run independently
                ChildWatch.add(child_pid, (pid, status) => {
                    Process.close_pid(pid);
                });
            } catch (SpawnError e) {
                warning("Failed to spawn background daemon: %s", e.message);
            }
        }

        /**
         * Kills any running background daemon process.
         * Called when user disables auto-updates in preferences.
         */
        public static void kill_daemon() {
            try {
                // Use pkill with SIGKILL (-9) to ensure the daemon is terminated
                // Match just "--background-update" to avoid issues with path variations
                // Use "--" to indicate end of options since pattern starts with "-"
                string[] argv = { "pkill", "-9", "-f", "--", "--background-update" };
                int exit_status;
                Process.spawn_sync(null, argv, null, GLib.SpawnFlags.SEARCH_PATH, null, null, null, out exit_status);
                debug("Killed background daemon (exit status: %d)", exit_status);
            } catch (SpawnError e) {
                warning("Failed to kill background daemon: %s", e.message);
            }
        }

        /**
         * Checks if the background daemon is already running.
         */
        private static bool is_daemon_running() {
            try {
                // Match just "--background-update" to avoid issues with path variations
                // Use "--" to indicate end of options since pattern starts with "-"
                string[] argv = { "pgrep", "-f", "--", "--background-update" };
                int exit_status;
                Process.spawn_sync(null, argv, null, GLib.SpawnFlags.SEARCH_PATH, null, null, null, out exit_status);
                return exit_status == 0;
            } catch (SpawnError e) {
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

        /**
         * Runs a persistent background daemon that periodically checks for updates.
         * This method blocks and runs a GLib main loop until the process is terminated.
         */
        public void run_daemon() {
            log_debug("background daemon: starting persistent service");

            // Check immediately on startup if interval has elapsed
            if (should_check_now()) {
                log_debug("background daemon: interval elapsed, checking now");
                perform_background_check.begin(null);
            } else {
                log_debug("background daemon: not yet time to check, waiting");
            }

            // Check periodically whether we should perform an update check
            // This allows the daemon to respect interval changes without restart
            Timeout.add_seconds(DAEMON_CHECK_INTERVAL, () => {
                if (!settings.get_boolean("auto-check-updates")) {
                    log_debug("background daemon: auto-check disabled, skipping");
                    return Source.CONTINUE;
                }

                if (should_check_now()) {
                    log_debug("background daemon: interval elapsed, checking now");
                    perform_background_check.begin(null);
                }

                return Source.CONTINUE;
            });

            // Run the main loop - this blocks until the session ends
            var loop = new MainLoop();
            loop.run();
        }

        private void log_debug(string message) {
            debug("%s", message);
            append_update_log(message);
        }

        private void append_update_log(string message) {
            DirUtils.create_with_parents(AppPaths.data_dir, 0755);
            var ts = new GLib.DateTime.now_local().format("%FT%T%z");
            var line = "%s %s\n".printf(ts, message);
            var file = FileStream.open(update_log_path, "a");
            if (file != null) {
                file.puts(line);
                file.flush();
            }
        }
    }
}
