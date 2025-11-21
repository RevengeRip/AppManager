app_sources = files(
  'main.vala',
  'application.vala',
  'windows/dialog_window.vala',
  'windows/main_window.vala',
  'windows/drop_window.vala'
)

executable('app-manager',
  core_sources + app_sources,
  dependencies: [adw_dep, gtk_dep, gio_dep, gio_unix_dep, glib_dep, json_glib_dep, gee_dep],
  install: true
)
