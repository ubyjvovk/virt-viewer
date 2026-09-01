version_compare_bin = executable(
  'test-version-compare',
  sources: ['test-version-compare.c'],
  dependencies: [glib_dep, gtk_dep],
  include_directories: top_include_dir + src_include_dir,
  link_with: [util_lib],
)

test('test-version-compare', version_compare_bin)


monitor_mapping_bin = executable(
  'test-monitor-mapping',
  sources: ['test-monitor-mapping.c'],
  dependencies: [glib_dep, gtk_dep],
  include_directories: top_include_dir + src_include_dir,
  link_with: [util_lib],
)

test('test-monitor-mapping', monitor_mapping_bin)


hotkeys_bin = executable(
  'test-hotkeys',
  sources: ['test-hotkeys.c', common_enum_headers],
  dependencies: [glib_dep, gtk_dep],
  include_directories: top_include_dir + src_include_dir,
  link_with: [common_lib],
)

test('test-hotkeys', hotkeys_bin)


monitor_alignment_bin = executable(
  'test-monitor-alignment',
  sources: ['test-monitor-alignment.c'],
  dependencies: [glib_dep, gtk_dep],
  include_directories: top_include_dir + src_include_dir,
  link_with: [util_lib],
)

test('test-monitor-alignment', monitor_alignment_bin)


if host_machine.system() == 'windows'
  redirect_bin = executable(
    'test-redirect',
    sources: ['redirect-test.c'],
    dependencies: [glib_dep, gtk_dep],
    link_with: [util_lib],
    link_args: ['-Wl,--subsystem,windows'],
    include_directories: top_include_dir + src_include_dir,
  )

  test('test-redirect', redirect_bin)
endif


if host_machine.system() == 'darwin'
  macos_window_state_bin = executable(
    'test-macos-window-state',
    sources: ['test-macos-window-state.c'],
    dependencies: [glib_dep, gtk_dep],
    include_directories: top_include_dir + src_include_dir,
  )

  # Drives a real window through the window server, so it is slower than the
  # pure-logic tests; skips itself (exit 77) on a builder with no GUI session.
  test('test-macos-window-state', macos_window_state_bin, timeout: 120)
endif
