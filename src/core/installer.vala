using AppManager.Utils;
using Gee;

namespace AppManager.Core {
    public errordomain InstallerError {
        ALREADY_INSTALLED,
        DESKTOP_MISSING,
        EXTRACTION_FAILED,
        SEVEN_ZIP_MISSING,
        UNINSTALL_FAILED,
        UNKNOWN
    }

    public class Installer : Object {
        private InstallationRegistry registry;
        private Settings settings;
        private string[] uninstall_prefix;

        public signal void progress(string message);

        public Installer(InstallationRegistry registry, Settings settings) {
            this.registry = registry;
            this.settings = settings;
            this.uninstall_prefix = resolve_uninstall_prefix();
            migrate_uninstall_execs();
        }

        public InstallationRecord install(string file_path, InstallMode override_mode = InstallMode.PORTABLE) throws Error {
            return install_sync(file_path, override_mode);
        }

        private InstallationRecord install_sync(string file_path, InstallMode override_mode) throws Error {
            var file = File.new_for_path(file_path);
            var metadata = new AppImageMetadata(file);
            if (registry.is_installed_checksum(metadata.checksum)) {
                throw new InstallerError.ALREADY_INSTALLED("AppImage already installed");
            }

            InstallMode mode = override_mode;

            var record = new InstallationRecord(metadata.checksum, metadata.display_name, mode);
            record.source_path = metadata.path;
            record.source_checksum = metadata.checksum;

            try {
                if (mode == InstallMode.PORTABLE) {
                    install_portable(metadata, record);
                } else {
                    install_extracted(metadata, record);
                }

                // Only delete source after successful installation
                if (File.new_for_path(file_path).query_exists()) {
                    File.new_for_path(file_path).delete();
                }

                registry.register(record);
                return record;
            } catch (Error e) {
                // Cleanup on failure
                cleanup_failed_installation(record);
                throw e;
            }
        }

        private void install_portable(AppImageMetadata metadata, InstallationRecord record) throws Error {
            progress("Preparing Applications folder…");
            var dest_path = Utils.FileUtils.unique_path(Path.build_filename(AppPaths.applications_dir, metadata.basename));
            var dest = File.new_for_path(dest_path);
            metadata.file.copy(dest, FileCopyFlags.OVERWRITE, null, null);
            ensure_executable(dest_path);
            record.installed_path = dest_path;
            finalize_desktop_and_icon(record, metadata, dest_path, dest_path);
        }

        private void install_extracted(AppImageMetadata metadata, InstallationRecord record) throws Error {
            progress("Extracting AppImage…");
            var base_name = metadata.sanitized_basename();
            var dest_dir = Utils.FileUtils.unique_path(Path.build_filename(AppPaths.extracted_root, base_name));
            DirUtils.create_with_parents(dest_dir, 0755);
            run_7z({"x", metadata.path, "-o" + dest_dir, "-y"});
            var dest_appimage = Path.build_filename(dest_dir, metadata.basename);
            metadata.file.copy(File.new_for_path(dest_appimage), FileCopyFlags.OVERWRITE, null, null);
            var app_run = Path.build_filename(dest_dir, "AppRun");
            if (File.new_for_path(app_run).query_exists()) {
                ensure_executable(app_run);
            } else {
                app_run = dest_appimage;
                ensure_executable(app_run);
            }
            record.installed_path = dest_dir;
            finalize_desktop_and_icon(record, metadata, app_run, dest_appimage);
        }

        private void finalize_desktop_and_icon(InstallationRecord record, AppImageMetadata metadata, string exec_target, string appimage_for_assets) throws Error {
            owned string exec_path = exec_target.dup();
            owned string assets_path = appimage_for_assets.dup();
            progress("Extracting desktop entry…");
            var temp_dir = Utils.FileUtils.create_temp_dir("appmgr-");
            try {
                run_7z({"x", assets_path, "-o" + temp_dir, "-y"});
                var desktop_path = find_desktop_entry(temp_dir);
                if (desktop_path == null) {
                    throw new InstallerError.DESKTOP_MISSING("The AppImage does not contain a .desktop file");
                }
                var icon_path = find_icon(temp_dir);
                string desktop_name = metadata.display_name;
                string? desktop_version = null;
                bool is_terminal_app = false;
                try {
                    var key_file = new KeyFile();
                    key_file.load_from_file(desktop_path, KeyFileFlags.NONE);
                    if (key_file.has_key("Desktop Entry", "Name")) {
                        desktop_name = key_file.get_string("Desktop Entry", "Name");
                    }
                    if (key_file.has_key("Desktop Entry", "X-AppImage-Version")) {
                        var parsed_version = key_file.get_string("Desktop Entry", "X-AppImage-Version").strip();
                        if (parsed_version.length > 0) {
                            desktop_version = parsed_version;
                        }
                    }
                    if (key_file.has_key("Desktop Entry", "Terminal")) {
                        is_terminal_app = key_file.get_boolean("Desktop Entry", "Terminal");
                    }
                } catch (Error e) {
                    warning("Failed to parse desktop metadata: %s", e.message);
                }
                record.name = desktop_name;
                record.version = desktop_version;

                var slug = slugify_app_name(desktop_name);
                if (slug == "") {
                    slug = metadata.sanitized_basename().down();
                }

                var renamed_path = ensure_install_name(record.installed_path, slug, record.mode == InstallMode.EXTRACTED);
                if (renamed_path != record.installed_path) {
                    if (record.mode == InstallMode.EXTRACTED) {
                        var exec_basename = Path.get_basename(exec_path);
                        exec_path = Path.build_filename(renamed_path, exec_basename);
                        var appimage_basename = Path.get_basename(assets_path);
                        assets_path = Path.build_filename(renamed_path, appimage_basename);
                    } else {
                        exec_path = renamed_path;
                        assets_path = renamed_path;
                    }
                    record.installed_path = renamed_path;
                }

                var final_slug = derive_slug_from_path(record.installed_path, record.mode == InstallMode.EXTRACTED);
                string? stored_icon = null;
                string icon_for_desktop = "";
                if (icon_path != null) {
                    if (settings.get_boolean("use-system-icons")) {
                        var base_name = Path.get_basename(icon_path);
                        var dot_index = base_name.last_index_of_char('.');
                        var extension = dot_index >= 0 ? base_name.substring(dot_index) : ".png";
                        stored_icon = Path.build_filename(AppPaths.icons_dir, "%s%s".printf(final_slug, extension));
                        Utils.FileUtils.file_copy(icon_path, stored_icon);
                        icon_for_desktop = final_slug;
                    } else {
                        stored_icon = Path.build_filename(AppPaths.data_dir, "%s-%s".printf(final_slug, Path.get_basename(icon_path)));
                        Utils.FileUtils.file_copy(icon_path, stored_icon);
                        icon_for_desktop = stored_icon;
                    }
                }
                var desktop_contents = rewrite_desktop(desktop_path, exec_path, icon_for_desktop, record.installed_path, is_terminal_app);
                var desktop_filename = "%s-%s.desktop".printf("appmanager", final_slug);
                var desktop_destination = Path.build_filename(AppPaths.desktop_dir, desktop_filename);
                Utils.FileUtils.ensure_parent(desktop_destination);
                if (!GLib.FileUtils.set_contents(desktop_destination, desktop_contents)) {
                    throw new InstallerError.UNKNOWN("Unable to write desktop file");
                }
                record.desktop_file = desktop_destination;
                record.icon_path = stored_icon;

                // Create symlink for terminal applications
                if (is_terminal_app) {
                    progress("Creating symlink for terminal application…");
                    record.bin_symlink = create_bin_symlink(exec_path, final_slug);
                }
            } finally {
                if (settings.get_boolean("auto-clean-temp")) {
                    Utils.FileUtils.remove_dir_recursive(temp_dir);
                }
            }
        }

        public void uninstall(InstallationRecord record) throws Error {
            uninstall_sync(record);
        }

        private void uninstall_sync(InstallationRecord record) throws Error {
            try {
                var installed_file = File.new_for_path(record.installed_path);
                if (installed_file.query_exists()) {
                    if (installed_file.query_file_type(FileQueryInfoFlags.NONE) == FileType.DIRECTORY) {
                        Utils.FileUtils.remove_dir_recursive(record.installed_path);
                    } else {
                        installed_file.trash(null);
                    }
                }
                if (record.desktop_file != null && File.new_for_path(record.desktop_file).query_exists()) {
                    File.new_for_path(record.desktop_file).delete(null);
                }
                if (record.icon_path != null && File.new_for_path(record.icon_path).query_exists()) {
                    File.new_for_path(record.icon_path).delete(null);
                }
                if (record.bin_symlink != null && File.new_for_path(record.bin_symlink).query_exists()) {
                    File.new_for_path(record.bin_symlink).delete(null);
                }
                registry.unregister(record.id);
            } catch (Error e) {
                throw new InstallerError.UNINSTALL_FAILED(e.message);
            }
        }

        private void cleanup_failed_installation(InstallationRecord record) {
            try {
                if (record.installed_path != null) {
                    var installed_file = File.new_for_path(record.installed_path);
                    if (installed_file.query_exists()) {
                        if (installed_file.query_file_type(FileQueryInfoFlags.NONE) == FileType.DIRECTORY) {
                            Utils.FileUtils.remove_dir_recursive(record.installed_path);
                        } else {
                            installed_file.delete(null);
                        }
                    }
                }
                if (record.desktop_file != null && File.new_for_path(record.desktop_file).query_exists()) {
                    File.new_for_path(record.desktop_file).delete(null);
                }
                if (record.icon_path != null && File.new_for_path(record.icon_path).query_exists()) {
                    File.new_for_path(record.icon_path).delete(null);
                }
                if (record.bin_symlink != null && File.new_for_path(record.bin_symlink).query_exists()) {
                    File.new_for_path(record.bin_symlink).delete(null);
                }
            } catch (Error e) {
                warning("Failed to cleanup after installation error: %s", e.message);
            }
        }

        private string? find_desktop_entry(string directory) {
            string? found = null;
            GLib.Dir dir;
            try {
                dir = GLib.Dir.open(directory);
            } catch (Error e) {
                warning("Failed to open directory %s: %s", directory, e.message);
                return null;
            }
            string? name;
            while ((name = dir.read_name()) != null) {
                var path = Path.build_filename(directory, name);
                if (GLib.FileUtils.test(path, GLib.FileTest.IS_DIR)) {
                    found = find_desktop_entry(path);
                    if (found != null) {
                        break;
                    }
                } else if (name.has_suffix(".desktop")) {
                    return path;
                }
            }
            return found;
        }

        private string? find_icon(string directory) {
            string? candidate = null;
            try {
                var dir = GLib.Dir.open(directory);
                string? name;
                while ((name = dir.read_name()) != null) {
                var path = Path.build_filename(directory, name);
                if (GLib.FileUtils.test(path, GLib.FileTest.IS_DIR)) {
                    var child = find_icon(path);
                    if (child != null) {
                        return child;
                    }
                } else if (name.has_suffix(".png") || name.has_suffix(".svg")) {
                    if (candidate == null || name.contains("256") || name.contains("512")) {
                        candidate = path;
                    }
                }
            }
            } catch (Error e) {
                warning("Failed to enumerate %s: %s", directory, e.message);
            }
            return candidate;
        }

        private string rewrite_desktop(string desktop_path, string exec_target, string icon_target, string installed_path, bool is_terminal) throws Error {
            string contents;
            if (!GLib.FileUtils.get_contents(desktop_path, out contents)) {
                throw new InstallerError.DESKTOP_MISSING("Failed to read desktop file");
            }
            var output = new StringBuilder();
            bool actions_line_found = false;
            bool uninstall_listed = false;
            bool skipping_uninstall_block = false;
            bool no_display_found = false;
            foreach (var line in contents.split("\n")) {
                var trimmed = line.strip();
                if (skipping_uninstall_block) {
                    if (trimmed.has_prefix("[")) {
                        skipping_uninstall_block = false;
                    } else {
                        continue;
                    }
                }
                if (trimmed == "[Desktop Action Uninstall]") {
                    skipping_uninstall_block = true;
                    continue;
                }

                if (trimmed.has_prefix("Exec=")) {
                    output.append("Exec=%s\n".printf(exec_target));
                } else if (trimmed.has_prefix("Icon=") && icon_target != "") {
                    output.append("Icon=%s\n".printf(icon_target));
                } else if (trimmed.has_prefix("NoDisplay=")) {
                    no_display_found = true;
                    if (is_terminal) {
                        output.append("NoDisplay=true\n");
                    } else {
                        output.append(line + "\n");
                    }
                } else if (trimmed.has_prefix("Actions=")) {
                    actions_line_found = true;
                    var value = trimmed.substring("Actions=".length);
                    var parts = value.split(";");
                    var cleaned_actions = new Gee.ArrayList<string>();
                    foreach (var part in parts) {
                        var action = part.strip();
                        if (action == "") {
                            continue;
                        }
                        if (action == "Uninstall") {
                            uninstall_listed = true;
                        }
                        cleaned_actions.add(action);
                    }
                    if (!uninstall_listed) {
                        cleaned_actions.add("Uninstall");
                        uninstall_listed = true;
                    }
                    var updated_actions = string.joinv(";", cleaned_actions.to_array());
                    output.append("Actions=%s;\n".printf(updated_actions));
                } else {
                    output.append(line + "\n");
                }
            }

            if (!actions_line_found) {
                output.append("Actions=Uninstall;\n");
            }
            if (is_terminal && !no_display_found) {
                output.append("NoDisplay=true\n");
            }

            var uninstall_exec = build_uninstall_exec(installed_path);
            output.append("\n[Desktop Action Uninstall]\n");
            output.append("Name=%s\n".printf(I18n.tr("Uninstall AppImage")));
            output.append("Exec=%s\n".printf(uninstall_exec));
            output.append("Icon=user-trash\n");
            return output.str;
        }

        private void ensure_executable(string path) {
            if (Posix.chmod(path, 0755) != 0) {
                warning("Failed to chmod %s", path);
            }
        }

        private string escape_exec_arg(string value) {
            return value.replace("\"", "\\\"");
        }

        private string build_uninstall_exec(string installed_path) {
            var parts = new Gee.ArrayList<string>();
            foreach (var token in uninstall_prefix) {
                parts.add(quote_exec_token(token));
            }
            parts.add("--uninstall");
            parts.add("\"%s\"".printf(escape_exec_arg(installed_path)));
            return string.joinv(" ", parts.to_array());
        }

        private string quote_exec_token(string token) {
            for (int i = 0; i < token.length; i++) {
                var ch = token[i];
                if (ch == ' ' || ch == '\t') {
                    return "\"%s\"".printf(escape_exec_arg(token));
                }
            }
            return token;
        }

        private string slugify_app_name(string name) {
            var normalized = name.strip().down();
            var builder = new StringBuilder();
            bool last_was_separator = false;
            for (int i = 0; i < normalized.length; i++) {
                char ch = normalized[i];
                if (ch == '\0') {
                    break;
                }
                if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) {
                    builder.append_c(ch);
                    last_was_separator = false;
                    continue;
                }
                if (!last_was_separator && builder.len > 0) {
                    builder.append_c('_');
                }
                last_was_separator = true;
            }
            return builder.len > 0 ? builder.str : "";
        }

        private string ensure_install_name(string current_path, string slug, bool is_extracted) throws Error {
            if (slug == "") {
                return current_path;
            }
            var parent = Path.get_dirname(current_path);
            string desired;
            if (is_extracted) {
                desired = Path.build_filename(parent, slug);
            } else {
                desired = Path.build_filename(parent, slug + get_path_extension(current_path));
            }

            if (desired == current_path) {
                return current_path;
            }

            if (File.new_for_path(desired).query_exists()) {
                var current_slug = derive_slug_from_path(current_path, is_extracted);
                if (current_slug != slug) {
                    return current_path;
                }
            }

            var final_target = Utils.FileUtils.unique_path(desired);
            if (final_target == current_path) {
                return current_path;
            }
            var source = File.new_for_path(current_path);
            var dest = File.new_for_path(final_target);
            source.move(dest, FileCopyFlags.NONE, null, null);
            return final_target;
        }

        private string get_path_extension(string path) {
            var base_name = Path.get_basename(path);
            var dot_index = base_name.last_index_of_char('.');
            return dot_index >= 0 ? base_name.substring(dot_index) : "";
        }

        private string derive_slug_from_path(string path, bool is_extracted) {
            var base_name = Path.get_basename(path);
            if (!is_extracted) {
                var dot_index = base_name.last_index_of_char('.');
                if (dot_index > 0) {
                    base_name = base_name.substring(0, dot_index);
                }
            }
            return base_name.down();
        }

        private string[] resolve_uninstall_prefix() {
            var prefix = new Gee.ArrayList<string>();
            if (is_flatpak_sandbox()) {
                var flatpak_id = flatpak_app_id();
                if (flatpak_id != null) {
                    var trimmed = flatpak_id.strip();
                    if (trimmed != "") {
                        prefix.add("flatpak");
                        prefix.add("run");
                        prefix.add(trimmed);
                        return prefix.to_array();
                    }
                }
            }
            string? resolved = Environment.find_program_in_path("app-manager");
            if (resolved == null || resolved.strip() == "") {
                resolved = current_executable_path();
            }
            if (resolved == null || resolved.strip() == "") {
                resolved = "app-manager";
            }
            prefix.add(resolved);
            return prefix.to_array();
        }

        private bool is_flatpak_sandbox() {
            return GLib.FileUtils.test("/.flatpak-info", FileTest.EXISTS);
        }

        private string? flatpak_app_id() {
            var env_id = Environment.get_variable("FLATPAK_ID");
            if (env_id != null && env_id.strip() != "") {
                return env_id;
            }
            try {
                var info = new KeyFile();
                info.load_from_file("/.flatpak-info", KeyFileFlags.NONE);
                if (info.has_key("Application", "name")) {
                    return info.get_string("Application", "name");
                }
            } catch (Error e) {
                warning("Failed to read flatpak info: %s", e.message);
            }
            return null;
        }

        private string? current_executable_path() {
            try {
                var path = GLib.FileUtils.read_link("/proc/self/exe");
                if (path != null && path.strip() != "") {
                    return path;
                }
            } catch (Error e) {
                warning("Failed to resolve self executable: %s", e.message);
            }
            return null;
        }

        private void run_7z(string[] arguments) throws Error {
            var cmd = new string[1 + arguments.length];
            cmd[0] = "7z";
            for (int i = 0; i < arguments.length; i++) {
                cmd[i + 1] = arguments[i];
            }
            string? stdout_str;
            string? stderr_str;
            int exit_status;
            Process.spawn_sync(null, cmd, null, SpawnFlags.SEARCH_PATH, null, out stdout_str, out stderr_str, out exit_status);
            if (exit_status != 0) {
                warning("7z stdout: %s", stdout_str ?? "");
                warning("7z stderr: %s", stderr_str ?? "");
                throw new InstallerError.EXTRACTION_FAILED("7z failed to extract payload");
            }
        }

        private string? create_bin_symlink(string exec_path, string slug) {
            try {
                var bin_dir = Path.build_filename(Environment.get_home_dir(), ".local", "bin");
                DirUtils.create_with_parents(bin_dir, 0755);
                
                var symlink_path = Path.build_filename(bin_dir, slug);
                var symlink_file = File.new_for_path(symlink_path);
                
                // Remove existing symlink if it exists
                if (symlink_file.query_exists()) {
                    symlink_file.delete(null);
                }
                
                // Create symlink
                symlink_file.make_symbolic_link(exec_path, null);
                debug("Created symlink: %s -> %s", symlink_path, exec_path);
                return symlink_path;
            } catch (Error e) {
                warning("Failed to create symlink for %s: %s", slug, e.message);
                return null;
            }
        }

        private void migrate_uninstall_execs() {
            foreach (var record in registry.list()) {
                if (record.desktop_file == null || record.desktop_file == "") {
                    continue;
                }
                try {
                    sanitize_uninstall_action(record);
                } catch (Error e) {
                    warning("Failed to sanitize uninstall action for %s: %s", record.name, e.message);
                }
            }
        }

        private void sanitize_uninstall_action(InstallationRecord record) throws Error {
            if (record.desktop_file == null || record.installed_path == null) {
                return;
            }
            string contents;
            if (!GLib.FileUtils.get_contents(record.desktop_file, out contents)) {
                return;
            }
            var builder = new StringBuilder();
            bool in_uninstall_block = false;
            bool modified = false;
            foreach (var line in contents.split("\n")) {
                var trimmed = line.strip();
                if (trimmed == "[Desktop Action Uninstall]") {
                    in_uninstall_block = true;
                    builder.append(line + "\n");
                    continue;
                }
                if (in_uninstall_block && trimmed.has_prefix("[")) {
                    in_uninstall_block = false;
                }
                if (in_uninstall_block && trimmed.has_prefix("Exec=")) {
                    var uninstall_exec = build_uninstall_exec(record.installed_path);
                    builder.append("Exec=%s\n".printf(uninstall_exec));
                    modified = true;
                    continue;
                }
                builder.append(line + "\n");
            }
            if (modified) {
                if (!GLib.FileUtils.set_contents(record.desktop_file, builder.str)) {
                    throw new InstallerError.UNKNOWN("Unable to update desktop file");
                }
            }
        }
    }
}
