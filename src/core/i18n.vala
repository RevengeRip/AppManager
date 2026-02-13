/**
 * Internationalization support following GNOME/GTK conventions.
 * After calling i18n_init(), use GLib._() for translations.
 */

namespace AppManager.Core {
    public const string GETTEXT_PACKAGE = "app-manager";

    private bool i18n_initialized = false;

    /**
     * Initialize internationalization. Call once at application startup.
     * After this, use _() from GLib for all translations.
     */
    public void i18n_init() {
        if (i18n_initialized) return;
        i18n_initialized = true;

        // Try the user's locale from environment; if unsupported, try common UTF-8 fallbacks
        if (Intl.setlocale(LocaleCategory.ALL, "") == null) {
            if (Intl.setlocale(LocaleCategory.ALL, "C.UTF-8") == null) {
                Intl.setlocale(LocaleCategory.ALL, "C");
            }
        }
        Intl.bindtextdomain(GETTEXT_PACKAGE, get_locale_dir());
        Intl.bind_textdomain_codeset(GETTEXT_PACKAGE, "UTF-8");
        Intl.textdomain(GETTEXT_PACKAGE);
    }

    /**
     * Determine the locale directory with AppImage and development support.
     */
    private string get_locale_dir() {
        // First check if we're running from AppImage
        var appdir = Environment.get_variable("APPDIR");
        if (appdir != null && appdir != "") {
            return Path.build_filename(appdir, "usr", "share", "locale");
        }

        // Check for development/local installation
        try {
            var exe_path = FileUtils.read_link("/proc/self/exe");
            if (exe_path != null) {
                var exe_dir = Path.get_dirname(exe_path);
                var local_locale = Path.build_filename(exe_dir, "..", "share", "locale");
                if (FileUtils.test(local_locale, FileTest.IS_DIR)) {
                    return local_locale;
                }
            }
        } catch (FileError e) {
            // Fall through to default
        }

        // Default system locale directory
        return "/usr/share/locale";
    }
}
