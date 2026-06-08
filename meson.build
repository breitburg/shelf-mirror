project(
    'shelf-mirror',
    ['vala', 'c'],
    version: '1.0.0',
    meson_version: '>= 0.57'
)

gnome = import('gnome')

wingpanel_dep = dependency('wingpanel')

# Install straight into Wingpanel's indicator directory so the panel picks it up.
indicators_dir = wingpanel_dep.get_variable(pkgconfig: 'indicatorsdir')

# Generate Config.vala so the version lives only in this file.
conf_data = configuration_data()
conf_data.set('VERSION', meson.project_version())
config_vala = configure_file(
    input: 'src/Config.vala.in',
    output: 'Config.vala',
    configuration: conf_data,
)

shared_module(
    meson.project_name(),
    'src/Indicator.vala',
    config_vala,
    name_prefix: 'lib',
    dependencies: [
        dependency('glib-2.0'),
        dependency('gobject-2.0'),
        dependency('gio-2.0'),
        dependency('gtk+-3.0'),
        dependency('cairo'),
        dependency('gstreamer-1.0'),
        dependency('gstreamer-app-1.0'),
        wingpanel_dep,
    ],
    install: true,
    install_dir: indicators_dir,
)

# GSettings schema for the chosen webcam.
install_data(
    'data/io.github.breitburg.shelf-mirror.gschema.xml',
    install_dir: get_option('datadir') / 'glib-2.0' / 'schemas',
)

gnome.post_install(glib_compile_schemas: true)
