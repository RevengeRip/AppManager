using AppManager.Core;
using AppManager.Utils;

namespace AppManager {
    public class DropWindow : Adw.Window {
        private InstallationRegistry registry;
        private Installer installer;
        private AppImageMetadata metadata;
        private Gtk.Image app_icon;
        private Gtk.Image folder_icon;
        private Gtk.Image arrow_icon;
        private Gtk.Overlay drag_overlay;
        private Gtk.Image drag_ghost;
        private Gtk.Label app_name_label;
        private Gtk.Label folder_name_label;
        private Adw.ToastOverlay toast_overlay;
        private Gtk.Box drag_box;
        private string appimage_path;
        private bool installing = false;
        private bool install_blocked = false;
        private InstallMode install_mode = InstallMode.PORTABLE;
        private const double DRAG_VISUAL_RANGE = 240.0;

        private Settings settings;

        public DropWindow(Application app, InstallationRegistry registry, Installer installer, Settings settings, string path) throws Error {
            Object(application: app,
                title: I18n.tr("AppImage Installer"),
                modal: true,
                default_width: 520,
                default_height: 320,
                destroy_with_parent: true);
            this.registry = registry;
            this.installer = installer;
            this.settings = settings;
            this.appimage_path = path;
            metadata = new AppImageMetadata(File.new_for_path(path));
            install_mode = determine_install_mode();
            build_ui();
            check_existing();
            load_icons_async();
        }

        private void build_ui() {
            this.title = I18n.tr("AppImage Installer");

            var toolbar_view = new Adw.ToolbarView();
            content = toolbar_view;

            var header = new Adw.HeaderBar();
            header.set_show_end_title_buttons(true);
            var title_widget = new Gtk.Label(I18n.tr("AppImage Installer"));
            title_widget.add_css_class("title-4");
            header.set_title_widget(title_widget);
            toolbar_view.add_top_bar(header);

            toast_overlay = new Adw.ToastOverlay();
            toolbar_view.content = toast_overlay;

            var clamp = new Adw.Clamp();
            clamp.margin_top = 24;
            clamp.margin_bottom = 24;
            clamp.margin_start = 24;
            clamp.margin_end = 24;
            toast_overlay.child = clamp;

            var outer = new Gtk.Box(Gtk.Orientation.VERTICAL, 18);
            clamp.child = outer;

            var subtitle = new Gtk.Label(I18n.tr("Drag and drop to install into Applications"));
            subtitle.add_css_class("dim-label");
            subtitle.halign = Gtk.Align.CENTER;
            subtitle.wrap = true;
            outer.append(subtitle);

            drag_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 32);
            drag_box.halign = Gtk.Align.CENTER;
            drag_box.valign = Gtk.Align.CENTER;
            drag_box.hexpand = false;
            drag_box.vexpand = true;
            drag_box.margin_start = 0;
            drag_box.margin_end = 0;

            app_icon = new Gtk.Image();
            app_icon.set_pixel_size(96);
            app_icon.set_from_icon_name("application-x-executable");
            var app_name = extract_app_name();
            var app_column = build_icon_column(app_icon, out app_name_label, app_name, true);
            drag_box.append(app_column);

            arrow_icon = new Gtk.Image.from_icon_name("pan-end-symbolic");
            arrow_icon.set_pixel_size(48);
            arrow_icon.add_css_class("dim-label");
            drag_box.append(arrow_icon);

            folder_icon = create_applications_icon();
            var folder_column = build_icon_column(folder_icon, out folder_name_label, I18n.tr("Applications"));
            drag_box.append(folder_column);

            drag_overlay = new Gtk.Overlay();
            drag_overlay.child = drag_box;
            drag_overlay.hexpand = false;
            drag_overlay.vexpand = false;
            drag_overlay.halign = Gtk.Align.CENTER;
            drag_overlay.valign = Gtk.Align.CENTER;
            drag_overlay.margin_start = 24;
            drag_overlay.margin_end = 24;

            drag_ghost = new Gtk.Image();
            drag_ghost.set_pixel_size(96);
            drag_ghost.add_css_class("drag-ghost");
            drag_ghost.set_opacity(0.0);
            drag_ghost.visible = false;
            drag_ghost.halign = Gtk.Align.START;
            drag_ghost.valign = Gtk.Align.START;
            drag_ghost.set_sensitive(false);
            drag_overlay.add_overlay(drag_ghost);
            drag_overlay.set_clip_overlay(drag_ghost, false);

            outer.append(drag_overlay);
            setup_drag_install(drag_box);
            sync_drag_ghost();

        }

        private void check_existing() {
            if (registry.lookup_by_source(appimage_path) != null || registry.lookup_by_checksum(metadata.checksum) != null) {
                show_toast(I18n.tr("Already installed"));
                install_blocked = true;
            }
        }

        private InstallMode selected_mode() {
            return install_mode;
        }

        private void start_install() {
            if (installing || install_blocked) {
                return;
            }
            installing = true;
            show_toast(I18n.tr("Installing…"));
            new Thread<void>("appmgr-install", () => {
                try {
                    var record = installer.install(appimage_path, selected_mode());
                    Idle.add(() => {
                        show_toast(I18n.tr("Installed %s").printf(record.name));
                        GLib.Timeout.add(1500, () => {
                            this.close();
                            return GLib.Source.REMOVE;
                        });
                        return GLib.Source.REMOVE;
                    });
                } catch (Error e) {
                    var message = e.message;
                    Idle.add(() => {
                        show_toast(I18n.tr("Failed: %s").printf(message));
                        installing = false;
                        return GLib.Source.REMOVE;
                    });
                }
            });
        }

        private void load_icons_async() {
            new Thread<void>("appmgr-icon", () => {
                try {
                    var texture = extract_icon_from_appimage(appimage_path);
                    if (texture != null) {
                        Idle.add(() => {
                            app_icon.set_from_paintable(texture);
                            sync_drag_ghost();
                            return GLib.Source.REMOVE;
                        });
                    } else {
                        Idle.add(() => {
                            app_icon.set_from_icon_name("application-x-executable");
                            sync_drag_ghost();
                            return GLib.Source.REMOVE;
                        });
                    }
                } catch (Error e) {
                    warning("Icon preview failed: %s", e.message);
                }
            });
        }

        private void setup_drag_install(Gtk.Box drag_container) {
            var gesture = new Gtk.GestureDrag();
            gesture.drag_begin.connect((start_x, start_y) => {
                drag_container.add_css_class("drag-active");
                show_drag_ghost(0);
            });
            gesture.drag_update.connect((offset_x, offset_y) => {
                update_drag_visual(offset_x);
            });
            gesture.drag_end.connect((offset_x, offset_y) => {
                drag_container.remove_css_class("drag-active");
                var threshold = drag_container.get_width() * 0.45;
                if (threshold <= 0) {
                    threshold = 150;
                }
                var final_offset = offset_x;
                if (final_offset < 0) {
                    final_offset = 0;
                }
                if (final_offset >= threshold) {
                    start_install();
                }
                reset_drag_visual();
            });
            drag_container.add_controller(gesture);
        }

        private void update_drag_visual(double offset_x) {
            var clamped = offset_x;
            if (clamped < 0) {
                clamped = 0;
            }
            if (clamped > DRAG_VISUAL_RANGE) {
                clamped = DRAG_VISUAL_RANGE;
            }

            var progress = clamped / DRAG_VISUAL_RANGE;
            arrow_icon.set_opacity(0.3 + progress * 0.7);
            folder_icon.set_opacity(0.7 + progress * 0.3);

            if (drag_ghost != null) {
                drag_ghost.visible = true;
                drag_ghost.set_opacity(0.4 + progress * 0.6);
                
                int base_x, base_y;
                compute_icon_position(out base_x, out base_y);
                
                drag_ghost.margin_start = base_x + (int)clamped;
                drag_ghost.margin_top = base_y;
                
                check_folder_highlight(drag_ghost.margin_start, base_y);
            }
        }

        private void check_folder_highlight(int ghost_x, int ghost_y) {
            if (folder_icon == null || drag_overlay == null) {
                return;
            }
            
            Graphene.Rect folder_bounds;
            if (folder_icon.compute_bounds(drag_overlay, out folder_bounds)) {
                int ghost_center_x = ghost_x + 48;
                int ghost_center_y = ghost_y + 48;
                
                var point = Graphene.Point();
                point.init(ghost_center_x, ghost_center_y);
                
                if (folder_bounds.contains_point(point)) {
                    folder_icon.set_opacity(1.0);
                    if (folder_name_label != null) {
                        folder_name_label.add_css_class("accent");
                    }
                } else {
                    if (folder_name_label != null) {
                        folder_name_label.remove_css_class("accent");
                    }
                }
            }
        }

        private void show_drag_ghost(double offset_x) {
            if (drag_ghost != null) {
                drag_ghost.visible = true;
                drag_ghost.set_opacity(0.0);
            }
            if (app_icon != null) {
                app_icon.set_opacity(0.6);
            }
            update_drag_visual(offset_x);
        }

        private void reset_drag_visual() {
            arrow_icon.set_opacity(1.0);
            folder_icon.set_opacity(1.0);
            if (app_icon != null) {
                app_icon.set_opacity(1.0);
            }
            if (drag_ghost != null) {
                drag_ghost.visible = false;
                drag_ghost.set_opacity(0.0);
                
                int base_x, base_y;
                compute_icon_position(out base_x, out base_y);
                drag_ghost.margin_start = base_x;
                drag_ghost.margin_top = base_y;
            }
            if (folder_name_label != null) {
                folder_name_label.remove_css_class("accent");
            }
        }

        private Gdk.Paintable? extract_icon_from_appimage(string path) throws Error {
            var temp_dir = Utils.FileUtils.create_temp_dir("appmgr-icon-");
            try {
                run_7z({"x", path, "-o" + temp_dir, "-y"});
                var icon_path = find_icon(temp_dir);
                if (icon_path != null) {
                    return Gdk.Texture.from_file(File.new_for_path(icon_path));
                }
            } catch (Error e) {
                warning("Icon extraction error: %s", e.message);
            } finally {
                Utils.FileUtils.remove_dir_recursive(temp_dir);
            }
            return null;
        }

        private string extract_app_name() {
            var temp_dir = Utils.FileUtils.create_temp_dir("appmgr-name-");
            try {
                run_7z({"x", appimage_path, "-o" + temp_dir, "*.desktop", "-r", "-y"});
                var desktop_file = find_desktop_file(temp_dir);
                if (desktop_file != null) {
                    var key_file = new KeyFile();
                    key_file.load_from_file(desktop_file, KeyFileFlags.NONE);
                    if (key_file.has_group("Desktop Entry") && key_file.has_key("Desktop Entry", "Name")) {
                        return key_file.get_string("Desktop Entry", "Name");
                    }
                }
            } catch (Error e) {
                warning("Desktop file extraction error: %s", e.message);
            } finally {
                Utils.FileUtils.remove_dir_recursive(temp_dir);
            }
            return metadata.display_name;
        }

        private string? find_desktop_file(string directory) {
            GLib.Dir dir;
            try {
                dir = GLib.Dir.open(directory);
            } catch (Error e) {
                return null;
            }
            string? name;
            while ((name = dir.read_name()) != null) {
                var path = Path.build_filename(directory, name);
                if (GLib.FileUtils.test(path, FileTest.IS_DIR)) {
                    var child = find_desktop_file(path);
                    if (child != null) {
                        return child;
                    }
                } else if (name.has_suffix(".desktop")) {
                    return path;
                }
            }
            return null;
        }

        private string? find_icon(string directory) {
            GLib.Dir dir;
            try {
                dir = GLib.Dir.open(directory);
            } catch (Error e) {
                warning("Failed to open %s: %s", directory, e.message);
                return null;
            }
            string? name;
            string? best = null;
            while ((name = dir.read_name()) != null) {
                var path = Path.build_filename(directory, name);
                if (GLib.FileUtils.test(path, FileTest.IS_DIR)) {
                    var child = find_icon(path);
                    if (child != null) {
                        return child;
                    }
                } else if (name.has_suffix(".png") || name.has_suffix(".svg")) {
                    best = path;
                }
            }
            return best;
        }

        private void run_7z(string[] args) throws Error {
            var cmd = new string[1 + args.length];
            cmd[0] = "7z";
            for (int i = 0; i < args.length; i++) {
                cmd[i + 1] = args[i];
            }
            string? stdout_str;
            string? stderr_str;
            int status;
            Process.spawn_sync(null, cmd, null, SpawnFlags.SEARCH_PATH, null, out stdout_str, out stderr_str, out status);
            if (status != 0) {
                throw new InstallerError.SEVEN_ZIP_MISSING("7z extraction failed");
            }
        }

        private InstallMode determine_install_mode() {
            var stored_mode = settings.get_string("default-install-mode");
            var normalized = sanitize_mode_id(stored_mode);
            if (stored_mode != normalized) {
                settings.set_string("default-install-mode", normalized);
            }
            if (normalized == "extracted") {
                return InstallMode.EXTRACTED;
            }
            return InstallMode.PORTABLE;
        }

        private string sanitize_mode_id(string? value) {
            if (value != null && value.down() == "extracted") {
                return "extracted";
            }
            return "portable";
        }

        private Gtk.Image create_applications_icon() {
            const int ICON_SIZE = 96;
            var image = new Gtk.Image();
            image.set_pixel_size(ICON_SIZE);

            var display = Gdk.Display.get_default();
            if (display != null) {
                var theme = Gtk.IconTheme.get_for_display(display);
                var gicon = load_applications_gicon();
                if (theme != null && gicon != null) {
                    var paintable = theme.lookup_by_gicon(gicon, ICON_SIZE, 1, Gtk.TextDirection.NONE, Gtk.IconLookupFlags.FORCE_REGULAR);
                    if (paintable != null) {
                        image.set_from_paintable(paintable);
                        return image;
                    }
                }

                string[] icon_candidates = { "folder-applications", "folder-apps", "folder" };
                foreach (var name in icon_candidates) {
                    if (theme != null && theme.has_icon(name)) {
                        image.set_from_icon_name(name);
                        return image;
                    }
                }
            }

            image.set_from_icon_name("folder");
            return image;
        }

        private GLib.Icon? load_applications_gicon() {
            var applications_path = Path.build_filename(Environment.get_home_dir(), "Applications");
            var applications_dir = File.new_for_path(applications_path);
            try {
                string attributes = "standard::icon";
                bool check_custom = false;

                // If Nautilus is installed, try to load custom icon from metadata
                // because Nautilus allows setting custom folder icons
                var nautilus = new DesktopAppInfo("org.gnome.Nautilus.desktop");
                if (nautilus != null) {
                    attributes += ",metadata::custom-icon";
                    check_custom = true;
                }

                var info = applications_dir.query_info(attributes, FileQueryInfoFlags.NONE);
                if (info != null) {
                    if (check_custom) {
                        var custom_icon = info.get_attribute_string("metadata::custom-icon");
                        if (custom_icon != null) {
                            return new FileIcon(File.new_for_uri(custom_icon));
                        }
                    }
                    return info.get_icon();
                }
            } catch (Error e) {
                warning("Applications icon lookup failed: %s", e.message);
            }

            var themed_fallback = new GLib.ThemedIcon.from_names({ "folder-applications", "folder-apps" });
            return themed_fallback;
        }

        private void sync_drag_ghost() {
            if (drag_ghost == null) {
                return;
            }
            var paintable = app_icon.get_paintable();
            if (paintable != null) {
                drag_ghost.set_from_paintable(paintable);
            } else {
                drag_ghost.set_from_icon_name("application-x-executable");
            }
        }

        private void compute_icon_position(out int x, out int y) {
            x = 0;
            y = 0;
            if (drag_overlay == null || app_icon == null) {
                return;
            }
            Graphene.Rect icon_bounds;
            if (app_icon.compute_bounds(drag_overlay, out icon_bounds)) {
                x = (int)icon_bounds.get_x();
                y = (int)icon_bounds.get_y();
            }
        }

        private Gtk.Box build_icon_column(Gtk.Image image, out Gtk.Label label, string text, bool emphasize = false) {
            var column = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
            column.halign = Gtk.Align.CENTER;
            column.valign = Gtk.Align.CENTER;
            column.append(image);

            label = new Gtk.Label(text);
            label.halign = Gtk.Align.CENTER;
            label.wrap = true;
            var attrs = new Pango.AttrList();
            attrs.insert(Pango.attr_weight_new(Pango.Weight.BOLD));
            label.set_attributes(attrs);
            if (emphasize) {
                label.add_css_class("title-5");
            } else {
                label.add_css_class("title-6");
            }
            column.append(label);

            return column;
        }

        private void show_toast(string message) {
            if (toast_overlay == null) {
                return;
            }
            var toast = new Adw.Toast(message);
            toast_overlay.add_toast(toast);
        }
    }
}
