using AppManager.Core;

namespace AppManager {
    public class BackgroundUpdater {
        private static bool version = false;
        private const OptionEntry[] options = {
            { "version", 0, 0, OptionArg.NONE, ref version, "Display version number", null },
            { null }
        };

        public static int main(string[] args) {
            try {
                var opt_context = new OptionContext("- AppManager background updater");
                opt_context.set_help_enabled(true);
                opt_context.add_main_entries(options, null);
                opt_context.parse(ref args);
            } catch (OptionError e) {
                printerr("Error: %s\n", e.message);
                printerr("Run '%s --help' to see available options.\n", args[0]);
                return 1;
            }

            if (version) {
                stdout.printf("AppManager background updater %s\n", Core.APPLICATION_VERSION);
                return 0;
            }

            var settings = new GLib.Settings(Core.APPLICATION_ID);
            
            if (!settings.get_boolean("auto-check-updates")) {
                debug("Auto-check updates disabled; exiting");
                return 0;
            }

            var registry = new InstallationRegistry();
            var installer = new Installer(registry, settings);
            var service = new BackgroundUpdateService(settings, registry, installer);

            if (!service.should_check_now()) {
                debug("Not time to check yet; exiting");
                return 0;
            }

            var loop = new MainLoop();
            var cancellable = new Cancellable();

            service.perform_background_check.begin(cancellable, (obj, res) => {
                service.perform_background_check.end(res);
                loop.quit();
            });

            loop.run();
            return 0;
        }
    }
}
