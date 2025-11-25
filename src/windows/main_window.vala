using AppManager.Core;
using AppManager.Utils;

[CCode (cname = "adw_about_dialog_new_from_appdata")]
extern Adw.Dialog about_dialog_new_from_appdata_raw(string resource_path, string? release_notes_version);

namespace AppManager {
    public class MainWindow : Adw.Window {
        private Application app_ref;
        private InstallationRegistry registry;
        private Installer installer;
        private Settings settings;
        private Adw.PreferencesGroup extracted_group;
        private Adw.PreferencesGroup portable_group;
        private Adw.PreferencesPage general_page;
        private Gtk.ShortcutsWindow? shortcuts_window;
        private Adw.AboutDialog? about_dialog;
        private Adw.NavigationView navigation_view;
        private const string SHORTCUTS_RESOURCE = "/com/github/AppManager/ui/main-window-shortcuts.ui";
        private const string APPDATA_RESOURCE = "/com/github/AppManager/com.github.AppManager.metainfo.xml";

        public MainWindow(Application app, InstallationRegistry registry, Installer installer, Settings settings) {
            Object(application: app);
            this.title = I18n.tr("AppManager");
            this.app_ref = app;
            this.registry = registry;
            this.installer = installer;
            this.settings = settings;
            add_css_class("devel");
            this.set_default_size(settings.get_int("window-width"), settings.get_int("window-height"));
            load_custom_css();
            build_ui();
            refresh_installations();
            registry.changed.connect(() => {
                refresh_installations();
            });
        }

        private void load_custom_css() {
            var provider = new Gtk.CssProvider();
            string css = """
                .card.accent {
                    background-color: @accent_bg_color;
                    color: @accent_fg_color;
                }
                .card.accent label {
                    color: @accent_fg_color;
                }
                .card.destructive {
                    background-color: @destructive_bg_color;
                    color: @destructive_fg_color;
                }
                .card.destructive label {
                    color: @destructive_fg_color;
                }
                .card.terminal {
                    background-color: #535252ff;
                    color: #ffffff;
                }
                .card.terminal label {
                    color: #ffffff;
                }
            """;
            provider.load_from_data(css.data);
            Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }

        private void build_ui() {
            navigation_view = new Adw.NavigationView();
            navigation_view.pop_on_escape = true;
            this.set_content(navigation_view);

            general_page = new Adw.PreferencesPage();
            
            var root_toolbar = create_toolbar_with_header(general_page, true);
            var root_page = new Adw.NavigationPage(root_toolbar, "main");
            root_page.title = I18n.tr("AppManager");
            navigation_view.add(root_page);

            portable_group = new Adw.PreferencesGroup();
            portable_group.title = I18n.tr("Portable AppImages");
            general_page.add(portable_group);

            extracted_group = new Adw.PreferencesGroup();
            extracted_group.title = I18n.tr("Extracted AppImages");
            general_page.add(extracted_group);

            this.close_request.connect(() => {
                settings.set_int("window-width", this.get_width());
                settings.set_int("window-height", this.get_height());
                return false;
            });
        }

        private void refresh_installations() {
            general_page.remove(portable_group);
            general_page.remove(extracted_group);
            
            portable_group = new Adw.PreferencesGroup();
            setup_group_header(portable_group, I18n.tr("Portable AppImages"), AppPaths.applications_dir);
            
            extracted_group = new Adw.PreferencesGroup();
            setup_group_header(extracted_group, I18n.tr("Extracted AppImages"), AppPaths.extracted_root);
            
            general_page.add(portable_group);
            general_page.add(extracted_group);
            
            var records = registry.list();
            var extracted_records = new Gee.ArrayList<InstallationRecord>();
            var portable_records = new Gee.ArrayList<InstallationRecord>();
            
            foreach (var record in records) {
                if (record.mode == InstallMode.EXTRACTED) {
                    extracted_records.add(record);
                } else {
                    portable_records.add(record);
                }
            }

            populate_group(portable_group, portable_records);
            populate_group(extracted_group, extracted_records);

            if (records.length == 0) {
                var empty_row = new Adw.ActionRow();
                empty_row.title = I18n.tr("Nothing installed yet");
                empty_row.subtitle = I18n.tr("Install an AppImage by double-clicking it");
                portable_group.add(empty_row);
            }
        }

        private void setup_group_header(Adw.PreferencesGroup group, string title, string path) {
            var display_path = format_display_path(path);

            var header_container = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            header_container.set_halign(Gtk.Align.START);
           
            var title_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
            title_row.set_valign(Gtk.Align.CENTER);
            title_row.set_halign(Gtk.Align.START);

            var title_label = new Gtk.Label(title);
            title_label.add_css_class("title-4");
            title_label.set_xalign(0);
            title_row.append(title_label);

            var folder_button = new Gtk.Button.from_icon_name("folder-open-symbolic");
            folder_button.add_css_class("flat");
            folder_button.set_valign(Gtk.Align.CENTER);
            folder_button.tooltip_text = I18n.tr("Open folder");
            folder_button.clicked.connect(() => {
                UiUtils.open_folder(path, this);
            });
            title_row.append(folder_button);

            header_container.append(title_row);

            var path_label = new Gtk.Label(display_path);
            path_label.add_css_class("dim-label");
            path_label.add_css_class("caption");
            path_label.set_xalign(0);
            path_label.set_ellipsize(Pango.EllipsizeMode.MIDDLE);
            header_container.append(path_label);

            group.title = null;
            group.description = null;
            group.set_header_suffix(header_container);
            align_group_header_box(group);
        }

        private string format_display_path(string path) {
            var home = Environment.get_home_dir();
            if (path.has_prefix(home)) {
                if (path.length == home.length) {
                    return "~";
                }
                var remainder = path.substring(home.length);
                if (!remainder.has_prefix("/")) {
                    remainder = "/" + remainder;
                }
                return "~" + remainder;
            }
            return path;
        }

        private void align_group_header_box(Adw.PreferencesGroup group) {
            var outer_box = group.get_first_child();
            if (outer_box == null) {
                return;
            }

            for (var child = outer_box.get_first_child(); child != null; child = child.get_next_sibling()) {
                if (child.has_css_class("header")) {
                    child.set_halign(Gtk.Align.START);
                    child.set_hexpand(false);
                    return;
                }
            }
        }

        private void populate_group(Adw.PreferencesGroup group, Gee.ArrayList<InstallationRecord> records) {
            foreach (var record in records) {
                var row = new Adw.ActionRow();
                row.title = record.name;
                
                string version_text;
                if (record.version != null && record.version.strip() != "") {
                    version_text = I18n.tr("Version %s").printf(record.version);
                } else {
                    version_text = I18n.tr("Version unknown");
                }
                row.subtitle = version_text;

                // Add icon if available
                if (record.icon_path != null && record.icon_path.strip() != "") {
                    var icon_image = UiUtils.load_app_icon(record.icon_path);
                    if (icon_image != null) {
                        row.add_prefix(icon_image);
                    }
                }

                // Make row activatable to show detail page
                row.activatable = true;
                row.activated.connect(() => { show_detail_page(record); });

                // Add navigation arrow
                var arrow = new Gtk.Image.from_icon_name("go-next-symbolic");
                arrow.add_css_class("dim-label");
                row.add_suffix(arrow);

                group.add(row);
            }
        }

        public void present_shortcuts_dialog() {
            ensure_shortcuts_window();
            if (shortcuts_window == null) {
                return;
            }
            shortcuts_window.set_transient_for(this);
            shortcuts_window.present();
        }

        private GLib.MenuModel build_menu_model() {
            var menu = new GLib.Menu();
            menu.append(I18n.tr("Keyboard shortcuts"), "app.show_shortcuts");
            menu.append(I18n.tr("About AppManager"), "app.show_about");
            return menu;
        }

        private Adw.ToolbarView create_toolbar_with_header(Gtk.Widget content, bool include_menu_button) {
            var toolbar = new Adw.ToolbarView();
            var header = new Adw.HeaderBar();

            if (include_menu_button) {
                var menu_button = new Gtk.MenuButton();
                menu_button.set_icon_name("open-menu-symbolic");
                menu_button.menu_model = build_menu_model();
                menu_button.tooltip_text = I18n.tr("More actions");
                header.pack_end(menu_button);
            }

            toolbar.add_top_bar(header);
            toolbar.set_content(content);
            return toolbar;
        }


        private void ensure_shortcuts_window() {
            if (shortcuts_window != null) {
                return;
            }
            try {
                var builder = new Gtk.Builder();
                builder.add_from_resource(SHORTCUTS_RESOURCE);
                shortcuts_window = builder.get_object("shortcuts_window") as Gtk.ShortcutsWindow;
                if (shortcuts_window == null) {
                    warning("Failed to create shortcuts window");
                    return;
                }
                shortcuts_window.set_transient_for(this);

                var section = builder.get_object("general_section") as Gtk.ShortcutsSection;
                if (section != null) {
                    section.title = I18n.tr("General");
                }
                var navigation = builder.get_object("navigation_group") as Gtk.ShortcutsGroup;
                if (navigation != null) {
                    navigation.title = I18n.tr("Navigation");
                }
                var window_group = builder.get_object("window_group") as Gtk.ShortcutsGroup;
                if (window_group != null) {
                    window_group.title = I18n.tr("Window");
                }
                assign_shortcut_title(builder, "shortcut_show_overlay", I18n.tr("Show shortcuts"));
                assign_shortcut_title(builder, "shortcut_about", I18n.tr("About AppManager"));
                assign_shortcut_title(builder, "shortcut_close_window", I18n.tr("Close window"));
                assign_shortcut_title(builder, "shortcut_quit", I18n.tr("Quit AppManager"));
            } catch (Error e) {
                warning("Failed to load shortcuts UI: %s", e.message);
            }
        }

        private void assign_shortcut_title(Gtk.Builder builder, string id, string title) {
            var shortcut = builder.get_object(id) as Gtk.ShortcutsShortcut;
            if (shortcut != null) {
                shortcut.title = title;
            }
        }

        public void present_about_dialog() {
            if (about_dialog == null) {
                about_dialog = (Adw.AboutDialog) about_dialog_new_from_appdata_raw(APPDATA_RESOURCE, null);
                about_dialog.version = APPLICATION_VERSION;
            }
            about_dialog.present(this);
        }

        private void show_detail_page(InstallationRecord record) {
            var details_window = new DetailsWindow(record, registry);
            details_window.uninstall_requested.connect((r) => {
                navigation_view.pop();
                app_ref.uninstall_record(r, this);
            });
            navigation_view.push(details_window);
        }
    }
}
