//! Integration tests linked against the real, pinned Ghostty GTK runtime.
const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const gdk = @import("gdk");
const state = &@import("global.zig").state;
const CoreApp = @import("App.zig");
const Runtime = @import("apprt/gtk/App.zig");
const Window = @import("apprt/gtk/class/window.zig").Window;
const devspace = @import("devspace_backend_client.zig");
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;

fn waitForPwd(runtime: *Runtime, surface: anytype, expected: []const u8) !void {
    // This catches a broken OSC 7 -> GTK surface callback, rather than merely
    // checking that Surface.setPwd stores a value.
    for (0..500) |_| {
        while (glib.MainContext.iteration(null, 0) != 0) {}
        try runtime.app.core().tick(runtime.app.rt());
        if (surface.getPwd()) |pwd| {
            if (std.mem.eql(u8, pwd, expected)) return;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    std.debug.print("OSC 7 timeout: expected={s}, actual={s}, initialized={}\n", .{
        expected, surface.getPwd() orelse "<none>", surface.core() != null,
    });
    return error.PwdNotReported;
}

test "DevSpace window contains a workspace sidebar beside the terminal content" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const temporary_path = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(temporary_path);
    const events_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/events.jsonl", .{temporary_path}, 0);
    defer std.testing.allocator.free(events_path);
    try std.testing.expectEqual(@as(c_int, 0), setenv("DEVSPACE_TEST_EVENTS", events_path, 1));
    const host_workspace = std.posix.getenv("DEVSPACE_HOST_WORKSPACE");
    const fixture_path = try std.fs.cwd().realpathAlloc(std.testing.allocator, if (host_workspace != null) "../../../Tests/Linux/fixtures/host_backend.py" else "../../../Tests/Linux/fixtures/backend.py");
    defer std.testing.allocator.free(fixture_path);
    const fixture = try std.testing.allocator.dupeZ(u8, fixture_path);
    defer std.testing.allocator.free(fixture);
    try std.testing.expectEqual(@as(c_int, 0), setenv("DEVSPACE_BACKEND", fixture, 1));
    try std.testing.expectEqual(@as(c_int, 0), setenv("DEVSPACE_BUILD_CHANNEL", "development", 1));
    if (host_workspace != null) {
        // Isolate layout/config changes from the user's regular dev instance.
        const config_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/config", .{temporary_path}, 0);
        defer std.testing.allocator.free(config_path);
        try std.testing.expectEqual(@as(c_int, 0), setenv("XDG_CONFIG_HOME", config_path, 1));
    }
    // Without the window adaptation, the content is Ghostty's TabOverview.
    try state.init();
    defer state.deinit();
    const core = try CoreApp.create(state.alloc);
    defer core.destroy();
    var runtime: Runtime = undefined;
    try runtime.init(core, .{});
    // The runtime sets GTK environment variables before initializing GTK.
    // Pre-initializing it here violates an upstream startup assertion.
    try std.testing.expect(gtk.isInitialized() != 0);
    defer {
        // Runtime.terminate force-deinitializes but intentionally doesn't run
        // GObject disposal. Dispose auxiliary dialogs before dropping config.
        runtime.app.as(gobject.Object).runDispose();
        while (glib.MainContext.iteration(null, 0) != 0) {}
        runtime.terminate();
    }
    try std.testing.expectEqualStrings("com.prakharp.devspace.dev", std.mem.span(runtime.app.as(gio.Application).getApplicationId().?));
    runtime.app.as(gio.Application).setFlags(.{ .non_unique = true });
    var registration_error: ?*glib.Error = null;
    try std.testing.expect(runtime.app.as(gio.Application).register(null, &registration_error) != 0);
    try std.testing.expect(runtime.app.as(gio.ActionGroup).hasAction("devspace-select-workspace") != 0);
    try std.testing.expect(runtime.app.as(gio.ActionGroup).hasAction("devspace-reload-workspace") != 0);
    const window = Window.new(runtime.app, .none);
    try std.testing.expectEqualStrings("DevSpaceDev", std.mem.span(glib.getApplicationName().?));
    // The last shell exiting can destroy the window before test teardown.
    // Keep the GObject alive so destroy remains safe on either exit path.
    _ = window.as(gobject.Object).ref();
    defer {
        window.as(gtk.Window).destroy();
        window.as(gobject.Object).unref();
        // GTK releases animation and focus references from the main context.
        // The core must remain alive until surface finalizers have run.
        for (0..300) |_| {
            while (glib.MainContext.iteration(null, 0) != 0) {}
            if (core.surfaces.items.len == 0) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        std.debug.print("GTK teardown: remaining surfaces={d}\n", .{core.surfaces.items.len});
    }

    const content = window.as(adw.ApplicationWindow).getContent().?;
    try std.testing.expect(gobject.ext.cast(gtk.Box, content) != null);
    const sidebar = content.getFirstChild().?;
    try std.testing.expectEqualStrings("devspace-sidebar", std.mem.span(sidebar.getName()));
    try std.testing.expect(sidebar.getNextSibling() != null);
    if (host_workspace) |workspace| {
        window.as(gtk.Window).present();
        try verifyHostSSH(&runtime, window, sidebar, events_path, workspace);
        return;
    }
    try verifyTabs(window);
    // PTYs initialize when the terminal widget is realized, not on Tab.new.
    window.as(gtk.Window).present();
    try verifyBackendOpen(&runtime, window, sidebar);
    const selected_surface = window.getActiveSurface().?;
    const page_count = window.getTabView().getNPages();
    const target = glib.Variant.newString("pod");
    _ = target.refSink();
    defer target.unref();
    runtime.app.as(gio.ActionGroup).activateAction("devspace-select-workspace", target);
    try waitForBackendEvent(&runtime, events_path, "select", null);
    try std.testing.expectEqual(page_count, window.getTabView().getNPages());
    try std.testing.expect(window.getActiveSurface().? == selected_surface);
    waitForBackendEvent(&runtime, events_path, "terminal_directory", "/tmp/backend-cwd") catch |err| {
        std.debug.print("Bound surface state: core={} mapped={} realized={} visible={} width={} height={}\n", .{
            selected_surface.core() != null,              selected_surface.as(gtk.Widget).getMapped(), selected_surface.as(gtk.Widget).getRealized(),
            selected_surface.as(gtk.Widget).getVisible(), selected_surface.as(gtk.Widget).getWidth(),  selected_surface.as(gtk.Widget).getHeight(),
        });
        std.debug.print("Layout sizes: window={}x{} content={}x{} sidebar={}x{} tabs={}x{}\n", .{
            window.as(gtk.Widget).getWidth(), window.as(gtk.Widget).getHeight(), content.getWidth(),                            content.getHeight(),
            sidebar.getWidth(),               sidebar.getHeight(),               window.getTabView().as(gtk.Widget).getWidth(), window.getTabView().as(gtk.Widget).getHeight(),
        });
        return err;
    };
    try waitForBackendEvent(&runtime, events_path, "terminal_output", null);
    const pixel = [_]u8{ 12, 34, 56, 255 };
    const pixels = glib.Bytes.new(&pixel, pixel.len);
    defer pixels.unref();
    const texture = gdk.MemoryTexture.new(1, 1, .r8g8b8a8, pixels, 4);
    defer texture.unref();
    selected_surface.as(gtk.Widget).getClipboard().setTexture(texture.as(gdk.Texture));
    try std.testing.expect(try selected_surface.clipboardRequest(.standard, .paste));
    try waitForBackendEvent(&runtime, events_path, "paste_image", null);
    // Rejected images must produce visible feedback, not silently consume paste.
    const large_pixels = try std.testing.allocator.alloc(u8, 4097 * 4097 * 4);
    defer std.testing.allocator.free(large_pixels);
    @memset(large_pixels, 0);
    const large_bytes = glib.Bytes.new(large_pixels.ptr, large_pixels.len);
    defer large_bytes.unref();
    const large_texture = gdk.MemoryTexture.new(4097, 4097, .r8g8b8a8, large_bytes, 4097 * 4);
    defer large_texture.unref();
    selected_surface.as(gtk.Widget).getClipboard().setTexture(large_texture.as(gdk.Texture));
    try std.testing.expect(try selected_surface.clipboardRequest(.standard, .paste));
    const status = gobject.ext.cast(gtk.Label, sidebar.getFirstChild().?.getNextSibling().?).?;
    const image_deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < image_deadline) {
        try pump(&runtime);
        if (std.mem.indexOf(u8, std.mem.span(status.getText()), "Clipboard image is too large") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(status.getText()), "Clipboard image is too large") != null);
    try waitForBackendEvent(&runtime, events_path, "terminal_exit", null);
    try verifyPwd(&runtime, window);
    try verifyInjection(&runtime, window);
    try verifyBackendRequestedClose(&runtime, window, sidebar);
    const events = try std.fs.cwd().readFileAlloc(std.testing.allocator, events_path, 64 * 1024);
    defer std.testing.allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, events, "\"terminal_exit\""));
}

fn pump(runtime: *Runtime) !void {
    while (glib.MainContext.iteration(null, 0) != 0) {}
    try runtime.app.core().tick(runtime.app.rt());
    std.Thread.sleep(10 * std.time.ns_per_ms);
}

fn hostAction(sidebar: *gtk.Widget, workspace: []const u8, action_index: usize) ?*gtk.Widget {
    const rows = sidebar.getFirstChild().?.getNextSibling().?.getNextSibling().?;
    var row = rows.getFirstChild();
    while (row) |label| {
        const text = std.mem.span(gobject.ext.cast(gtk.Label, label).?.getText());
        const actions = label.getNextSibling() orelse return null;
        if (std.mem.startsWith(u8, text, workspace) and text.len > workspace.len and
            std.mem.startsWith(u8, text[workspace.len..], " · "))
        {
            var action = actions.getFirstChild();
            for (0..action_index) |_| action = (action orelse return null).getNextSibling();
            return action;
        }
        row = actions.getNextSibling();
    }
    return null;
}

fn hostLaunch(path: []const u8, index: usize) !?std.json.Parsed(devspace.TerminalEffect) {
    const bytes = std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1024 * 1024) catch return null;
    defer std.testing.allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var found: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const frame = parsed.value.object.get("frame").?.object;
        if (!std.mem.eql(u8, frame.get("kind").?.string, "terminal_launch")) continue;
        if (found == index) return try std.json.parseFromSlice(devspace.TerminalEffect, std.testing.allocator, frame.get("payload").?.object.get("json").?.string, .{ .allocate = .alloc_always });
        found += 1;
    }
    return null;
}

fn hostOutputSeen(path: []const u8, pane: []const u8) bool {
    const bytes = std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1024 * 1024) catch return false;
    defer std.testing.allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const frame = parsed.value.object.get("frame").?.object;
        if (!std.mem.eql(u8, frame.get("kind").?.string, "terminal_output")) continue;
        if (std.mem.eql(u8, frame.get("payload").?.object.get("pane_id").?.string, pane)) return true;
    }
    return false;
}

fn openHostPane(runtime: *Runtime, window: *Window, sidebar: *gtk.Widget, events: []const u8, workspace: []const u8, index: usize) !std.json.Parsed(devspace.TerminalEffect) {
    var clicked = false;
    for (0..6000) |_| {
        try pump(runtime);
        if (!clicked) {
            if (hostAction(sidebar, workspace, 2)) |open| {
                g_signal_emit_by_name(open, "clicked");
                clicked = true;
            }
        }
        if (window.getTabView().getNPages() == index + 1) {
            if (try hostLaunch(events, index)) |launch| {
                if (hostOutputSeen(events, launch.value.paneID.?)) return launch;
                launch.deinit();
            }
        }
    }
    const status = sidebar.getFirstChild().?.getNextSibling().?;
    std.debug.print("Host connection timeout: {s}\n", .{std.mem.span(gobject.ext.cast(gtk.Label, status).?.getText())});
    return error.HostTerminalNotReady;
}

fn controlPath(effect: devspace.TerminalEffect) ![]const u8 {
    for (effect.arguments) |argument| {
        if (std.mem.startsWith(u8, argument, "ControlPath=")) return argument[12..];
    }
    return error.MissingControlPath;
}

fn checkHostMaster(path: []const u8, workspace: []const u8) !void {
    const host = try std.fmt.allocPrint(std.testing.allocator, "{s}.devpod", .{workspace});
    defer std.testing.allocator.free(host);
    const result = try std.process.Child.run(.{ .allocator = std.testing.allocator, .argv = &.{ "/usr/bin/ssh", "-S", path, "-O", "check", host } });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Master running") != null);
}

fn verifyHostSSH(runtime: *Runtime, window: *Window, sidebar: *gtk.Widget, events: []const u8, workspace: []const u8) !void {
    const first = try openHostPane(runtime, window, sidebar, events, workspace, 0);
    defer first.deinit();
    const first_surface = window.getActiveSurface().?;
    const first_page = window.getTabView().getSelectedPage().?;
    const second = try openHostPane(runtime, window, sidebar, events, workspace, 1);
    defer second.deinit();
    const second_surface = window.getActiveSurface().?;
    const second_page = window.getTabView().getSelectedPage().?;
    try std.testing.expect(first_surface != second_surface);
    try std.testing.expectEqualStrings(first.value.generation, second.value.generation);
    try std.testing.expect(!std.mem.eql(u8, first.value.paneID.?, second.value.paneID.?));
    const path = try controlPath(first.value);
    try std.testing.expectEqualStrings(path, try controlPath(second.value));
    try checkHostMaster(path, workspace);
    var safe_proxy = false;
    for (first.value.arguments) |argument| {
        if (std.mem.startsWith(u8, argument, "ProxyCommand=") and
            std.mem.endsWith(u8, argument, "--start-services=false")) safe_proxy = true;
    }
    try std.testing.expect(safe_proxy);
    try hostCommand(first_surface, " unset HISTFILE; cd /tmp; printf '\\033]7;file://localhost/tmp\\007'");
    try waitForPwd(runtime, first_surface, "/tmp");
    try hostCommand(second_surface, " unset HISTFILE; cd /; printf '\\033]7;file://localhost/\\007'");
    try waitForPwd(runtime, second_surface, "/");
    try std.testing.expectEqualStrings("/tmp", first_surface.getPwd().?);
    // Real remote hosts must report editor metadata without granting their
    // paths the privileges of a trusted local Ghostty working directory.
    try hostCommand(first_surface, " cd /usr; printf '\\033]7;file://%s/usr\\007' \"$(hostname)\"");
    try waitForHostDirectory(runtime, events, first.value, "/usr");
    try std.testing.expectEqualStrings("/tmp", first_surface.getPwd().?);
    try verifyHostTerminalData(runtime, first_surface);
    // Relative navigation has a defined starting page, independent of focus
    // events while commands were sent to the background first pane.
    try std.testing.expectEqual(@as(c_int, 2), window.getTabView().getNPages());
    window.getTabView().setSelectedPage(second_page);
    try pump(runtime);
    try std.testing.expect(window.getTabView().getSelectedPage().? == second_page);
    try std.testing.expect(window.selectTab(.previous));
    try std.testing.expect(window.getTabView().getSelectedPage().? == first_page);
    try std.testing.expect(window.getActiveSurface().? == first_surface);
    const initial_grid = first_surface.core().?.size.grid();
    window.as(gtk.Window).setDefaultSize(1000, 700);
    for (0..300) |_| {
        try pump(runtime);
        const grid = first_surface.core().?.size.grid();
        if (grid.rows != initial_grid.rows or grid.columns != initial_grid.columns) break;
    }
    const resized_grid = first_surface.core().?.size.grid();
    try std.testing.expect(resized_grid.rows != initial_grid.rows or resized_grid.columns != initial_grid.columns);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "/devspace-size-{d}-{d}", .{ resized_grid.rows, resized_grid.columns });
    defer std.testing.allocator.free(expected);
    try hostCommand(first_surface, " set -- $(stty size); printf '\\033]7;file://localhost/devspace-size-%s-%s\\007' \"$1\" \"$2\"; sleep 1");
    try waitForPwd(runtime, first_surface, expected);
    // Surviving a poll must not recreate either surface.
    for (0..550) |_| try pump(runtime);
    try std.testing.expectEqual(@as(c_int, 2), window.getTabView().getNPages());
    try std.testing.expect(window.getActiveSurface().? == first_surface);
    try checkHostMaster(path, workspace);
    try hostCommand(first_surface, " exit");
    try hostCommand(second_surface, " exit");
    for (0..1000) |_| {
        try pump(runtime);
        std.fs.cwd().access(path, .{}) catch {
            std.debug.print("HOST SSH PASS: two panes, one master, output/CWD, injection, tab selection, remote PTY resize, polling, master cleanup\n", .{});
            return;
        };
    }
    return error.HostMasterNotReleased;
}

fn hostCommand(surface: anytype, command: []const u8) !void {
    // A real shell enables bracketed paste: pasting a newline intentionally
    // does NOT execute it. Keep that protection and send an actual Enter key.
    try surface.injectText(command);
    _ = try surface.core().?.keyCallback(.{ .key = .enter, .utf8 = "\r" });
}

fn verifyHostTerminalData(runtime: *Runtime, surface: anytype) !void {
    // Octal escapes prevent command echo from satisfying Unicode output.
    // The Q must have actual parsed 24-bit color, not just echoed SGR text.
    try hostCommand(surface, " printf '\\n\\316\\273\\347\\225\\214\\360\\237\\231\\202\\n\\033[38;2;12;34;56mQ\\033[0m\\n'");
    for (0..500) |_| {
        try pump(runtime);
        const core = surface.core().?;
        const matched = matched: {
            core.renderer_state.mutex.lock();
            defer core.renderer_state.mutex.unlock();
            const terminal = core.renderer_state.terminal;
            const text = try terminal.plainString(std.testing.allocator);
            defer std.testing.allocator.free(text);
            if (std.mem.indexOf(u8, text, "λ界🙂") == null) break :matched false;
            for (0..terminal.rows) |y| {
                for (0..terminal.cols) |x| {
                    const cell = terminal.screens.active.pages.getCell(.{ .active = .{ .x = @intCast(x), .y = @intCast(y) } }) orelse continue;
                    if (cell.cell.content_tag != .codepoint or cell.cell.content.codepoint != 'Q') continue;
                    switch (cell.style().fg_color) {
                        .rgb => |rgb| if (rgb.r == 12 and rgb.g == 34 and rgb.b == 56) {
                            break :matched true;
                        },
                        else => {},
                    }
                }
            }
            break :matched false;
        };
        if (matched) return;
    }
    return error.HostUnicodeOrTruecolorNotParsed;
}

fn waitForHostDirectory(runtime: *Runtime, path: []const u8, effect: devspace.TerminalEffect, expected: []const u8) !void {
    for (0..500) |_| {
        try pump(runtime);
        const bytes = std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1024 * 1024) catch continue;
        defer std.testing.allocator.free(bytes);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{}) catch continue;
            defer parsed.deinit();
            const frame = parsed.value.object.get("frame").?.object;
            if (!std.mem.eql(u8, frame.get("kind").?.string, "terminal_directory")) continue;
            const payload = frame.get("payload").?.object;
            if (std.mem.eql(u8, payload.get("pane_id").?.string, effect.paneID.?) and
                std.mem.eql(u8, payload.get("generation").?.string, effect.generation) and
                std.mem.eql(u8, payload.get("directory").?.string, expected)) return;
        }
    }
    std.debug.print("Remote directory not reported to backend: {s}\n", .{expected});
    return error.RemoteDirectoryNotReported;
}

fn verifyBackendRequestedClose(runtime: *Runtime, window: *Window, sidebar: *gtk.Widget) !void {
    const initial = window.getTabView().getNPages();
    const rows = sidebar.getFirstChild().?.getNextSibling().?.getNextSibling().?;
    var actions = rows.getFirstChild().?.getNextSibling().?;
    const open = actions.getFirstChild().?.getNextSibling().?.getNextSibling().?;
    g_signal_emit_by_name(open, "clicked");
    for (0..500) |_| {
        while (glib.MainContext.iteration(null, 0) != 0) {}
        try runtime.app.core().tick(runtime.app.rt());
        if (window.getTabView().getNPages() == initial + 1) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(initial + 1, window.getTabView().getNPages());
    actions = rows.getFirstChild().?.getNextSibling().?;
    const reload = actions.getFirstChild().?.getNextSibling().?.getNextSibling().?.getNextSibling().?;
    g_signal_emit_by_name(reload, "clicked");
    var stale_seen = false;
    for (0..500) |_| {
        while (glib.MainContext.iteration(null, 0) != 0) {}
        try runtime.app.core().tick(runtime.app.rt());
        const label = gobject.ext.cast(gtk.Label, rows.getFirstChild().?).?;
        if (std.mem.eql(u8, std.mem.span(label.getText()), "pod · StaleFrameSeen")) {
            stale_seen = true;
            break;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expect(stale_seen);
    try std.testing.expectEqual(initial + 1, window.getTabView().getNPages());
    runtime.app.as(gio.ActionGroup).activateAction("devspace-reload-workspace", null);
    for (0..500) |_| {
        while (glib.MainContext.iteration(null, 0) != 0) {}
        try runtime.app.core().tick(runtime.app.rt());
        if (window.getTabView().getNPages() == initial) return;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return error.BackendTerminalDidNotClose;
}

fn waitForBackendEvent(runtime: *Runtime, path: []const u8, kind: []const u8, directory: ?[]const u8) !void {
    for (0..500) |_| {
        while (glib.MainContext.iteration(null, 0) != 0) {}
        try runtime.app.core().tick(runtime.app.rt());
        const contents = std.fs.cwd().readFileAlloc(std.testing.allocator, path, 64 * 1024) catch {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        defer std.testing.allocator.free(contents);
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const frame = try std.json.parseFromSlice(struct {
                kind: []const u8,
                payload: ?struct {
                    workspace_id: ?[]const u8 = null,
                    pane_id: ?[]const u8 = null,
                    generation: ?[]const u8 = null,
                    directory: ?[]const u8 = null,
                } = null,
            }, std.testing.allocator, line, .{ .ignore_unknown_fields = true });
            defer frame.deinit();
            if (!std.mem.eql(u8, frame.value.kind, kind)) continue;
            const payload = frame.value.payload orelse continue;
            try std.testing.expectEqualStrings("pod", payload.workspace_id orelse "");
            if (std.mem.startsWith(u8, kind, "terminal_")) {
                try std.testing.expectEqualStrings("00000000-0000-0000-0000-000000000001", payload.generation orelse "");
                try std.testing.expectEqualStrings("00000000-0000-0000-0000-000000000002", payload.pane_id orelse "");
            }
            if (directory) |expected| try std.testing.expectEqualStrings(expected, payload.directory orelse "");
            return;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    std.debug.print("Missing backend terminal event: {s}\n", .{kind});
    const recorded = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, 64 * 1024);
    defer std.testing.allocator.free(recorded);
    std.debug.print("Recorded control events: {s}\n", .{recorded});
    return error.TerminalEventNotReported;
}

extern "gobject-2.0" fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;

fn verifyBackendOpen(runtime: *Runtime, window: *Window, sidebar: *gtk.Widget) !void {
    const heading = sidebar.getFirstChild().?;
    const status = heading.getNextSibling().?;
    const rows = status.getNextSibling().?;
    for (0..500) |_| {
        while (glib.MainContext.iteration(null, 0) != 0) {}
        if (rows.getFirstChild() != null) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    const label = rows.getFirstChild() orelse return error.BackendDidNotRenderWorkspace;
    const actions = label.getNextSibling().?;
    const start = actions.getFirstChild().?;
    const stop = start.getNextSibling().?;
    const open = stop.getNextSibling() orelse return error.MissingOpenAction;
    g_signal_emit_by_name(open, "clicked");
    for (0..500) |_| {
        while (glib.MainContext.iteration(null, 0) != 0) {}
        try runtime.app.core().tick(runtime.app.rt());
        if (window.getTabView().getNPages() == 3) return;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return error.BackendTerminalDidNotLaunch;
}

fn verifyTabs(window: *Window) !void {
    window.newTabForWindow(null, .{ .command = .{ .shell = "sleep 60" } });
    window.newTabForWindow(null, .{ .command = .{ .shell = "sleep 60" } });

    const tab_view = window.getTabView();
    try std.testing.expectEqual(@as(c_int, 2), tab_view.getNPages());
    try std.testing.expect(window.selectTab(.previous));
}

fn verifyPwd(runtime: *Runtime, window: *Window) !void {
    window.newTabForWindow(null, .{ .command = .{ .shell = "printf '\\033]7;file://localhost/tmp/devspace-cwd\\007'; sleep 60" } });
    const surface = window.getActiveSurface().?;
    try waitForPwd(runtime, surface, "/tmp/devspace-cwd");
}

fn verifyInjection(runtime: *Runtime, window: *Window) !void {
    window.newTabForWindow(null, .{ .command = .{ .shell = "printf '\\033]7;file://localhost/tmp/injection-ready\\007'; read line; printf '\\033]7;file://localhost/tmp/injected-%s\\007' \"$line\"; sleep 60" } });
    const surface = window.getActiveSurface().?;
    // A core surface exists before its child has started. Wait for actual
    // child output so the test cannot inject into an uninitialized PTY.
    try waitForPwd(runtime, surface, "/tmp/injection-ready");
    try surface.injectText("text-from-devspace\n");
    try waitForPwd(runtime, surface, "/tmp/injected-text-from-devspace");
}
