namespace AppManager.Core {
    public class AppImageMetadata : Object {
    public File file { get; private set; }
    public string path { owned get { return file.get_path(); } }
    public string basename { owned get { return file.get_basename(); } }
        public string display_name { get; private set; }
        public bool is_executable { get; private set; }
        public string checksum { get; private set; }
        public string? update_info { get; private set; }

        public AppImageMetadata(File file) throws Error {
            this.file = file;
            if (!file.query_exists()) {
                throw new FileError.NOENT("AppImage not found: %s", file.get_path());
            }
            display_name = derive_name(file.get_basename());
            checksum = Utils.FileUtils.compute_checksum(file.get_path());
            is_executable = detect_executable();
            update_info = extract_update_info(file.get_path());
        }

        /**
         * Extract update information from AppImage's .upd_info ELF section.
         * This section contains update URLs in formats like:
         *   - zsync|https://example.com/App.AppImage.zsync
         *   - gh-releases-zsync|owner|repo|latest|App-*x86_64.AppImage.zsync
         * Returns null if no update info is found.
         */
        private static string? extract_update_info(string appimage_path) {
            try {
                string stdout_buf;
                string stderr_buf;
                int exit_status;
                
                Process.spawn_command_line_sync(
                    "readelf -p .upd_info \"%s\"".printf(appimage_path),
                    out stdout_buf,
                    out stderr_buf,
                    out exit_status
                );
                
                if (exit_status != 0 || stdout_buf == null || stdout_buf.strip() == "") {
                    return null;
                }
                
                // Parse readelf output - look for the actual content line
                // Format: "  [     0]  zsync|https://..."
                foreach (var line in stdout_buf.split("\n")) {
                    var trimmed = line.strip();
                    // Skip header lines and empty lines
                    if (trimmed == "" || trimmed.has_prefix("String dump") || trimmed.has_prefix("Section")) {
                        continue;
                    }
                    // Content lines start with [ followed by offset
                    if (trimmed.has_prefix("[")) {
                        var bracket_end = trimmed.index_of("]");
                        if (bracket_end > 0 && bracket_end + 1 < trimmed.length) {
                            var content = trimmed.substring(bracket_end + 1).strip();
                            if (content != "" && !content.has_prefix("Section")) {
                                return content;
                            }
                        }
                    }
                }
                
                return null;
            } catch (Error e) {
                debug("Failed to extract .upd_info: %s", e.message);
                return null;
            }
        }

        private bool detect_executable() {
            try {
                var info = file.query_info("unix::mode", FileQueryInfoFlags.NONE);
                uint32 mode = info.get_attribute_uint32("unix::mode");
                return (mode & 0100) != 0;
            } catch (Error e) {
                warning("Failed to query file mode: %s", e.message);
                return false;
            }
        }

        public string sanitized_basename() {
            var stem = Path.get_basename(file.get_path());
            if (stem.has_suffix(".AppImage")) {
                stem = stem.substring(0, (int)stem.length - ".AppImage".length);
            }
            var builder = new StringBuilder();
            for (int i = 0; i < stem.length; i++) {
                char c = stem[i];
                if (c.isalnum() || c == '-' || c == '_') {
                    builder.append_c(c);
                } else {
                    builder.append_c('-');
                }
            }
            return builder.str.strip();
        }

        private string derive_name(string filename) {
            var name = filename;
            if (name.has_suffix(".AppImage")) {
                name = name.substring(0, (int)name.length - 9);
            }
            name = name.replace("-", " ");
            name = name.replace("_", " ");
            if (name.length == 0) {
                return "AppImage";
            }
            var first = name.substring(0, 1).up();
            var rest = name.substring(1);
            return first + rest;
        }
    }
}
