/*
 * Shelf Mirror — a Wingpanel indicator that shows a live camera view.
 *
 * Wingpanel renders the widget returned by get_widget () inside a popover.
 * The popover is dismissed automatically when the user clicks anywhere else,
 * so "close when you click elsewhere" comes for free from the panel itself —
 * we just make sure to release the camera in closed ().
 *
 * Frames are pulled from an appsink and painted by hand into a windowless
 * Gtk.DrawingArea. Doing the drawing ourselves (rather than using gtksink,
 * whose widget owns its own rectangular window) lets us clip the feed to
 * rounded corners and render a blurred, translucent loading state. The
 * loading spinner is a real Gtk.Spinner layered on top via a Gtk.Overlay, so
 * it picks up elementary's themed spinner.
 *
 * The popover content is a Gtk.Stack with three views: the live camera (with
 * an OSD menu button), a Settings view to pick the webcam, and an About view.
 */
public class ShelfMirror.Indicator : Wingpanel.Indicator {
    private const string SCHEMA_ID = "io.github.breitburg.shelf-mirror";

    // Sized to the camera's native aspect ratio (848:588 ≈ 1.44:1) so the
    // feed fills the popover edge to edge with no letterbox bars.
    private const int VIEW_WIDTH = 360;
    private const int VIEW_HEIGHT = 250;

    // Corner radius matching the elementary popover's content area.
    private const double CORNER_RADIUS = 5.0;

    // Loading look + timings.
    private const double LOADING_OPACITY = 0.3;
    private const double SCRIM_ALPHA = 0.22;  // frosted panel behind spinner / error
    private const int BLUR_DOWNSCALE = 8;     // higher = blurrier
    private const uint SETTLE_MS = 600;       // blurred → crisp after first frame
    private const int SPINNER_SIZE = 32;

    // If no frame arrives within this window after opening, the stream is
    // rebuilt from scratch — the camera sometimes wedges on a fast reopen.
    private const uint WATCHDOG_MS = 2500;
    private const int MAX_START_ATTEMPTS = 4;

    private Gtk.Image? icon = null;
    private Gtk.Stack? stack = null;
    private Gtk.Overlay? camera_overlay = null;
    private Gtk.DrawingArea? drawing_area = null;
    private Gtk.Spinner? spinner = null;
    private Gtk.Label? error_label = null;
    private Gtk.ComboBoxText? camera_combo = null;

    private Gst.Element? pipeline = null;

    // Latest frame, shared between the GStreamer streaming thread and the UI.
    private Gst.Sample? current_sample = null;
    private GLib.Mutex sample_mutex;
    // Reused downscale buffer for the loading-state blur.
    private Cairo.ImageSurface? blur_surface = null;

    // Loading state machine.
    private bool loading = true;
    private bool first_frame_seen = false;
    private uint settle_id = 0;

    // Stream supervision.
    private bool is_open = false;
    private uint watchdog_id = 0;
    private uint bus_watch_id = 0;
    private int start_attempts = 0;
    private bool retry_pending = false;

    // Settings.
    private GLib.Settings? settings = null;
    private string current_device = "";
    private bool populating = false;

    private static Gtk.CssProvider? css_provider = null;

    public Indicator () {
        Object (
            code_name: "shelf-mirror",
            visible: true
        );

        load_settings ();
    }

    /* The icon shown in the panel itself. */
    public override Gtk.Widget get_display_widget () {
        if (icon == null) {
            icon = new Gtk.Image.from_icon_name (
                "camera-web-symbolic",
                Gtk.IconSize.LARGE_TOOLBAR
            );
            icon.tooltip_text = "Mirror";
        }

        return icon;
    }

    /* The content of the popover. Built lazily on first open. */
    public override Gtk.Widget? get_widget () {
        if (stack == null) {
            ensure_style ();

            stack = new Gtk.Stack () {
                transition_type = Gtk.StackTransitionType.SLIDE_LEFT_RIGHT,
                transition_duration = 200,
                hhomogeneous = true,
                vhomogeneous = false,
                width_request = VIEW_WIDTH,
                hexpand = true,
                vexpand = true,
                halign = Gtk.Align.FILL,
                valign = Gtk.Align.FILL
            };

            stack.add_named (build_camera_page (), "camera");
            stack.add_named (build_settings_page (), "settings");
            stack.add_named (build_about_page (), "about");
            stack.visible_child_name = "camera";

            // Wingpanel's IndicatorPopover packs our content into a Gtk.Box with
            // margin_top/margin_bottom = 3, which shows as thin lines above and
            // below the feed. Zero that parent margin once we're attached so the
            // camera reaches the popover edges vertically too.
            stack.map.connect (() => {
                var parent = stack.get_parent ();
                if (parent != null) {
                    parent.margin_top = 0;
                    parent.margin_bottom = 0;
                }
            });

            stack.show_all ();
        }

        return stack;
    }

    /* ---- Camera page -------------------------------------------------- */

    private Gtk.Widget build_camera_page () {
        drawing_area = new Gtk.DrawingArea ();
        // Windowless + app-paintable so the corners we leave unpainted stay
        // transparent and reveal the popover's rounded background behind us.
        drawing_area.set_has_window (false);
        drawing_area.set_app_paintable (true);
        drawing_area.hexpand = true;
        drawing_area.vexpand = true;
        drawing_area.halign = Gtk.Align.FILL;
        drawing_area.valign = Gtk.Align.FILL;
        drawing_area.draw.connect (on_draw);

        // The pipeline is (re)built fresh each time the popover opens.

        // elementary themes Gtk.Spinner into its signature spinner.
        spinner = new Gtk.Spinner () {
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER,
            width_request = SPINNER_SIZE,
            height_request = SPINNER_SIZE
        };

        // Shown only when the camera genuinely fails to start.
        error_label = new Gtk.Label ("Camera unavailable") {
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER,
            wrap = true,
            justify = Gtk.Justification.CENTER,
            max_width_chars = 24,
            no_show_all = true
        };
        error_label.get_style_context ().add_class ("shelf-mirror-error");

        var menu_button = build_menu_button ();

        // Overlay is a no-window container, so the windowless drawing area still
        // paints straight onto the popover and keeps its rounded transparent
        // corners; the spinner, message and menu button float on top.
        camera_overlay = new Gtk.Overlay () {
            width_request = VIEW_WIDTH,
            height_request = VIEW_HEIGHT
        };
        camera_overlay.add (drawing_area);
        camera_overlay.add_overlay (spinner);
        camera_overlay.add_overlay (error_label);
        camera_overlay.add_overlay (menu_button);

        return camera_overlay;
    }

    private Gtk.MenuButton build_menu_button () {
        var settings_item = new Gtk.ModelButton () { text = "Settings…" };
        var about_item = new Gtk.ModelButton () { text = "About" };

        var menu_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            margin_top = 3,
            margin_bottom = 3
        };
        menu_box.add (settings_item);
        menu_box.add (about_item);
        menu_box.show_all ();

        var menu_popover = new Gtk.Popover (null);
        menu_popover.position = Gtk.PositionType.TOP;
        menu_popover.add (menu_box);

        var button = new Gtk.MenuButton () {
            halign = Gtk.Align.END,
            valign = Gtk.Align.END,
            margin_end = 8,
            margin_bottom = 8,
            image = new Gtk.Image.from_icon_name ("view-more-symbolic", Gtk.IconSize.BUTTON),
            popover = menu_popover,
            tooltip_text = "Menu"
        };
        button.get_style_context ().add_class ("flat");
        button.get_style_context ().add_class ("shelf-mirror-osd");

        settings_item.clicked.connect (() => {
            menu_popover.popdown ();
            populate_cameras ();
            stack.visible_child_name = "settings";
        });
        about_item.clicked.connect (() => {
            menu_popover.popdown ();
            stack.visible_child_name = "about";
        });

        return button;
    }

    /* ---- Settings page ------------------------------------------------ */

    private Gtk.Widget build_settings_page () {
        var page = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        page.add (build_subview_header ("Settings"));

        var camera_label = new Gtk.Label ("Camera") {
            halign = Gtk.Align.END
        };

        camera_combo = new Gtk.ComboBoxText () {
            hexpand = true,
            valign = Gtk.Align.CENTER
        };
        camera_combo.changed.connect (on_camera_selected);

        var grid = new Gtk.Grid () {
            row_spacing = 12,
            column_spacing = 12,
            margin = 12
        };
        grid.attach (camera_label, 0, 0);
        grid.attach (camera_combo, 1, 0);

        page.add (grid);
        return page;
    }

    private void populate_cameras () {
        if (camera_combo == null) {
            return;
        }

        populating = true;
        camera_combo.remove_all ();

        var monitor = new Gst.DeviceMonitor ();
        monitor.add_filter ("Video/Source", null);
        monitor.start ();

        bool any = false;
        foreach (var device in monitor.get_devices ()) {
            string? path = null;
            var props = device.get_properties ();
            if (props != null) {
                path = props.get_string ("device.path");
                if (path == null) {
                    path = props.get_string ("api.v4l2.path");
                }
            }
            if (path == null) {
                continue;
            }
            camera_combo.append (path, device.get_display_name ());
            any = true;
        }

        monitor.stop ();

        if (current_device == "" || !camera_combo.set_active_id (current_device)) {
            camera_combo.active = any ? 0 : -1;
        }

        populating = false;
    }

    private void on_camera_selected () {
        if (populating) {
            return;
        }

        var id = camera_combo.active_id;
        if (id == null || id == current_device) {
            return;
        }

        current_device = id;
        if (settings != null) {
            settings.set_string ("device", id);
        }
        apply_device_change ();
    }

    /* ---- About page --------------------------------------------------- */

    private Gtk.Widget build_about_page () {
        var page = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        page.add (build_subview_header ("About"));

        var app_icon = new Gtk.Image.from_icon_name ("camera-web-symbolic", Gtk.IconSize.DIALOG) {
            pixel_size = 64
        };

        var name = new Gtk.Label ("Shelf Mirror");
        name.get_style_context ().add_class ("h2");

        var description = new Gtk.Label ("A camera mirror that lives in your panel.") {
            wrap = true,
            justify = Gtk.Justification.CENTER,
            max_width_chars = 32
        };
        description.get_style_context ().add_class ("dim-label");

        var version = new Gtk.Label ("Version " + Config.VERSION);
        version.get_style_context ().add_class ("dim-label");

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 6) {
            margin = 12,
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER,
            vexpand = true
        };
        content.add (app_icon);
        content.add (name);
        content.add (description);
        content.add (version);

        page.add (content);
        return page;
    }

    /* ---- Shared sub-view header (back button + title) ----------------- */

    private Gtk.Widget build_subview_header (string title) {
        var back = new Gtk.Button.from_icon_name ("go-previous-symbolic", Gtk.IconSize.BUTTON) {
            tooltip_text = "Back"
        };
        back.get_style_context ().add_class ("flat");
        back.clicked.connect (() => {
            stack.visible_child_name = "camera";
        });

        var label = new Gtk.Label (title);
        label.get_style_context ().add_class ("h4");

        var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            margin = 6
        };
        header.add (back);
        header.add (label);
        return header;
    }

    /* ---- Drawing ------------------------------------------------------ */

    private bool on_draw (Cairo.Context cr) {
        int w = drawing_area.get_allocated_width ();
        int h = drawing_area.get_allocated_height ();

        rounded_rectangle (cr, 0, 0, w, h, CORNER_RADIUS);
        cr.clip ();

        Gst.Sample? sample;
        sample_mutex.lock ();
        sample = current_sample;
        sample_mutex.unlock ();

        if (sample != null) {
            var buffer = sample.get_buffer ();
            if (buffer != null) {
                Gst.MapInfo map;
                if (buffer.map (out map, Gst.MapFlags.READ)) {
                    var frame = new Cairo.ImageSurface.for_data (
                        map.data, Cairo.Format.ARGB32, VIEW_WIDTH, VIEW_HEIGHT, VIEW_WIDTH * 4
                    );

                    if (loading) {
                        paint_blurred (cr, frame, w, h);
                    } else {
                        paint_frame (cr, frame, w, h);
                    }

                    buffer.unmap (map);
                }
            }
        } else {
            // No frame: a frosted translucent panel for the spinner or the
            // "Camera unavailable" message to sit on.
            cr.set_source_rgba (0, 0, 0, SCRIM_ALPHA);
            cr.paint ();
        }

        return false;
    }

    // Paint a surface scaled from src→dst dimensions with bilinear smoothing.
    private void paint_surface_scaled (Cairo.Context cr, Cairo.Surface surface,
                                       int src_w, int src_h, int dst_w, int dst_h, double alpha) {
        cr.save ();
        cr.scale ((double) dst_w / src_w, (double) dst_h / src_h);
        cr.set_source_surface (surface, 0, 0);
        cr.get_source ().set_filter (Cairo.Filter.GOOD);
        if (alpha >= 1.0) {
            cr.paint ();
        } else {
            cr.paint_with_alpha (alpha);
        }
        cr.restore ();
    }

    private void paint_frame (Cairo.Context cr, Cairo.Surface frame, int w, int h) {
        paint_surface_scaled (cr, frame, VIEW_WIDTH, VIEW_HEIGHT, w, h, 1.0);
    }

    // Cheap blur: shrink the frame to a fraction of its size, then let Cairo's
    // bilinear filter smear it back up to the full view, at reduced opacity.
    private void paint_blurred (Cairo.Context cr, Cairo.Surface frame, int w, int h) {
        int sw = int.max (1, VIEW_WIDTH / BLUR_DOWNSCALE);
        int sh = int.max (1, VIEW_HEIGHT / BLUR_DOWNSCALE);

        if (blur_surface == null) {
            blur_surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, sw, sh);
        }

        // The opaque frame fully overwrites the reused buffer, so no clear needed.
        var sc = new Cairo.Context (blur_surface);
        paint_surface_scaled (sc, frame, VIEW_WIDTH, VIEW_HEIGHT, sw, sh, 1.0);
        blur_surface.flush ();

        paint_surface_scaled (cr, blur_surface, sw, sh, w, h, LOADING_OPACITY);
    }

    private void rounded_rectangle (Cairo.Context cr, double x, double y, double w, double h, double r) {
        r = double.min (r, double.min (w / 2.0, h / 2.0));
        double d = Math.PI / 180.0;

        cr.new_sub_path ();
        cr.arc (x + w - r, y + r,     r, -90 * d,   0);
        cr.arc (x + w - r, y + h - r, r,   0,       90 * d);
        cr.arc (x + r,     y + h - r, r,  90 * d,  180 * d);
        cr.arc (x + r,     y + r,     r, 180 * d,  270 * d);
        cr.close_path ();
    }

    /* ---- GStreamer ---------------------------------------------------- */

    private void load_pipeline () {
        string src = "v4l2src";
        if (current_device != "") {
            src = "v4l2src device=%s".printf (current_device);
        }

        try {
            // BGRA matches Cairo's ARGB32 byte order on little-endian, so the
            // mapped buffer can be wrapped as a Cairo surface without a copy.
            var description = (
                "%s ! videoflip method=horizontal-flip ! videoconvert ! " +
                "videoscale ! video/x-raw,format=BGRA,width=%d,height=%d ! " +
                "appsink name=videosink emit-signals=true max-buffers=1 drop=true sync=false"
            ).printf (src, VIEW_WIDTH, VIEW_HEIGHT);
            pipeline = Gst.parse_launch (description);
        } catch (Error e) {
            warning ("Could not create camera pipeline: %s", e.message);
            pipeline = null;
            return;
        }

        var bin = pipeline as Gst.Bin;
        var sink = bin.get_by_name ("videosink") as Gst.App.Sink;
        if (sink == null) {
            warning ("Camera pipeline has no appsink");
            pipeline = null;
            return;
        }

        sink.new_sample.connect (() => {
            var sample = sink.pull_sample ();
            if (sample != null) {
                sample_mutex.lock ();
                current_sample = sample;
                sample_mutex.unlock ();

                // Marshal back to the UI thread (g_idle uses the default main
                // context, which the GTK loop iterates).
                Idle.add (on_frame_arrived);
            }

            return Gst.FlowReturn.OK;
        });

        // Recover gracefully if the device disappears while streaming.
        bus_watch_id = bin.get_bus ().add_watch (Priority.DEFAULT, on_bus_message);
    }

    // Fully release the current pipeline and any timers tied to it.
    private void teardown_pipeline () {
        clear_source (ref watchdog_id);
        clear_source (ref bus_watch_id);
        if (pipeline != null) {
            pipeline.set_state (Gst.State.NULL);
            pipeline = null;
        }

        sample_mutex.lock ();
        current_sample = null;
        sample_mutex.unlock ();
    }

    // Build a brand-new pipeline and start it. Always starting fresh avoids the
    // wedged-on-reopen state where a reused v4l2 source never produces frames.
    // `fresh` marks a new session (open / device change) and resets the retry
    // budget; internal retries pass false to keep counting down.
    private void start_stream (bool fresh = false) {
        teardown_pipeline ();
        if (!is_open) {
            return;
        }
        if (fresh) {
            start_attempts = 0;
        }

        show_loading ();
        load_pipeline ();

        if (pipeline != null) {
            pipeline.set_state (Gst.State.PLAYING);
        }

        arm_watchdog ();
    }

    // Remove a GLib source by id and zero the id (no-op when already cleared).
    private void clear_source (ref uint id) {
        if (id != 0) {
            Source.remove (id);
            id = 0;
        }
    }

    private void redraw () {
        if (drawing_area != null) {
            drawing_area.queue_draw ();
        }
    }

    // Single place that decides "retry if we can, otherwise surface the error".
    private void fail_or_retry (uint delay_ms) {
        if (!schedule_retry (delay_ms) && !retry_pending) {
            show_error ();
        }
    }

    private void arm_watchdog () {
        clear_source (ref watchdog_id);
        watchdog_id = Timeout.add (WATCHDOG_MS, () => {
            watchdog_id = 0;
            if (!first_frame_seen) {
                fail_or_retry (0);
            }
            return Source.REMOVE;
        });
    }

    // Rebuild the stream after a short delay (lets the device finish releasing).
    // Returns false when there's nothing left to try.
    private bool schedule_retry (uint delay_ms) {
        if (retry_pending || first_frame_seen || !is_open || start_attempts >= MAX_START_ATTEMPTS) {
            return false;
        }

        retry_pending = true;
        start_attempts++;
        warning ("Shelf Mirror: camera produced no frames, restarting (attempt %d)", start_attempts);

        Timeout.add (delay_ms, () => {
            retry_pending = false;
            if (is_open && !first_frame_seen) {
                start_stream ();
            }
            return Source.REMOVE;
        });

        return true;
    }

    private void apply_device_change () {
        if (is_open) {
            start_stream (true);
        } else {
            teardown_pipeline ();
        }
    }

    private bool on_frame_arrived () {
        redraw ();

        // First frame: the stream is healthy — stand down the watchdog and hold
        // the blurred/translucent look briefly, then reveal.
        if (!first_frame_seen) {
            first_frame_seen = true;
            start_attempts = 0;
            clear_source (ref watchdog_id);
            if (settle_id == 0) {
                settle_id = Timeout.add (SETTLE_MS, () => {
                    settle_id = 0;
                    reveal ();
                    return Source.REMOVE;
                });
            }
        }

        return Source.REMOVE;
    }

    private bool on_bus_message (Gst.Bus bus, Gst.Message message) {
        if (message.type == Gst.MessageType.ERROR) {
            Error err;
            string debug_info;
            message.parse_error (out err, out debug_info);
            warning ("Camera stream error: %s", err.message);

            // A short delay gives the device time to release before we retry.
            fail_or_retry (350);
        }

        return Source.CONTINUE;
    }

    /* ---- Loading state ------------------------------------------------ */

    private void show_loading () {
        loading = true;
        first_frame_seen = false;
        clear_source (ref settle_id);
        if (error_label != null) {
            error_label.hide ();
        }
        if (spinner != null) {
            spinner.show ();
            spinner.start ();
        }
        redraw ();
    }

    private void reveal () {
        loading = false;
        if (spinner != null) {
            spinner.stop ();
            spinner.hide ();
        }
        redraw ();
    }

    // The camera could not be started after exhausting retries.
    private void show_error () {
        loading = false;
        if (spinner != null) {
            spinner.stop ();
            spinner.hide ();
        }
        if (error_label != null) {
            error_label.show ();
        }
        redraw ();
    }

    /* ---- Wingpanel lifecycle ------------------------------------------ */

    /* Called by Wingpanel when the popover opens — start streaming fresh. */
    public override void opened () {
        if (stack != null) {
            stack.visible_child_name = "camera";
        }

        is_open = true;
        start_stream (true);
    }

    /* Called by Wingpanel when the popover closes — release the camera. */
    public override void closed () {
        is_open = false;

        clear_source (ref settle_id);
        teardown_pipeline ();
        if (spinner != null) {
            spinner.stop ();
        }
    }

    /* ---- Settings + styling ------------------------------------------- */

    private void load_settings () {
        var source = GLib.SettingsSchemaSource.get_default ();
        if (source != null && source.lookup (SCHEMA_ID, true) != null) {
            settings = new GLib.Settings (SCHEMA_ID);
            current_device = settings.get_string ("device");
            settings.changed["device"].connect (() => {
                var device = settings.get_string ("device");
                if (device != current_device) {
                    current_device = device;
                    if (camera_combo != null && !populating) {
                        populating = true;
                        if (device == "" || !camera_combo.set_active_id (device)) {
                            camera_combo.active = -1;
                        }
                        populating = false;
                    }
                    apply_device_change ();
                }
            });
        } else {
            // Schema not installed: run with the default camera, no persistence.
            warning ("GSettings schema %s not found; camera selection won't persist", SCHEMA_ID);
            settings = null;
            current_device = "";
        }
    }

    private static void ensure_style () {
        if (css_provider != null) {
            return;
        }

        css_provider = new Gtk.CssProvider ();
        try {
            // No chrome — just a white symbolic icon with a tiny drop shadow so
            // it stays legible over any frame, the elementary way for OSD icons.
            css_provider.load_from_data (
                ".shelf-mirror-osd {" +
                "  background: none;" +
                "  background-color: transparent;" +
                "  border: none;" +
                "  box-shadow: none;" +
                "  color: #ffffff;" +
                "  padding: 4px;" +
                "  border-radius: 99px;" +
                "  -gtk-icon-shadow: 0 1px 0 rgba (0, 0, 0, 0.5);" +
                "}" +
                ".shelf-mirror-osd:hover { background-color: rgba (0, 0, 0, 0.45); }" +
                ".shelf-mirror-osd:active," +
                ".shelf-mirror-osd:checked { background-color: rgba (0, 0, 0, 0.6); }" +
                ".shelf-mirror-error {" +
                "  color: rgba (0, 0, 0, 0.5);" +
                "  text-shadow: none;" +
                "}"
            );
        } catch (Error e) {
            warning ("Could not load style: %s", e.message);
            return;
        }

        Gtk.StyleContext.add_provider_for_screen (
            Gdk.Screen.get_default (),
            css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }
}

/*
 * Entry point looked up by Wingpanel's module loader. The greeter has no
 * business showing a camera, so we only register in a normal session.
 */
public Wingpanel.Indicator? get_indicator (Module module, Wingpanel.IndicatorManager.ServerType server_type) {
    if (server_type != Wingpanel.IndicatorManager.ServerType.SESSION) {
        return null;
    }

    unowned string[]? gst_args = null;
    Gst.init (ref gst_args);

    debug ("Activating Shelf Mirror indicator");

    return new ShelfMirror.Indicator ();
}
