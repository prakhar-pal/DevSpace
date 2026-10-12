const std = @import("std");
const client = @import("client");

test "Linux application identity keeps development separate from production" {
    try std.testing.expectEqualStrings("com.prakharp.devspace.dev", client.applicationIdentifier("development"));
    try std.testing.expectEqualStrings("com.prakharp.devspace", client.applicationIdentifier("production"));
    try std.testing.expectEqualStrings("com.prakharp.devspace", client.applicationIdentifier("invalid"));
}

test "client builds request IDs with a single frame delimiter" {
    const allocator = std.testing.allocator;
    const line = try client.requestLine(allocator, 7, "poll", null);
    defer allocator.free(line);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("7", parsed.value.object.get("id").?.string);
    try std.testing.expectEqualStrings("poll", parsed.value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("version").?.integer);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
}

test "terminal events carry generation and pane identity with escaped directory" {
    const allocator = std.testing.allocator;
    const line = try client.terminalEventLine(allocator, 8, "terminal_directory", "pod", "generation", "pane", "/tmp/a\nb");
    defer allocator.free(line);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const payload = parsed.value.object.get("payload").?.object;
    try std.testing.expectEqualStrings("generation", payload.get("generation").?.string);
    try std.testing.expectEqualStrings("pane", payload.get("pane_id").?.string);
    try std.testing.expectEqualStrings("/tmp/a\nb", payload.get("directory").?.string);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
}

const Object = opaque {};
extern "gtk-4" fn gtk_init_check() c_int;
extern "gtk-4" fn gtk_box_new(c_int, c_int) *Object;
extern "gtk-4" fn gtk_widget_get_first_child(*Object) ?*Object;
extern "gtk-4" fn gtk_label_get_text(*Object) [*:0]const u8;
extern "gobject-2.0" fn g_object_ref_sink(*Object) *Object;
extern "gobject-2.0" fn g_object_unref(*Object) void;
extern "glib-2.0" fn g_main_context_iteration(?*anyopaque, c_int) c_int;
extern "glib-2.0" fn g_get_application_name() ?[*:0]const u8;

test "GTK client renders snapshot from a real subprocess" {
    try std.testing.expect(gtk_init_check() != 0);
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    try client.Client.attach(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "development");
    try std.testing.expectEqualStrings("DevSpaceDev", std.mem.span(g_get_application_name() orelse return error.ApplicationDisplayNameMissing));
    const status = gtk_widget_get_first_child(sidebar).?;
    const deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (std.mem.eql(u8, std.mem.span(gtk_label_get_text(status)), "Workspaces")) break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expectEqualStrings("Workspaces", std.mem.span(gtk_label_get_text(status)));
    const rows = gtk_widget_get_next_sibling(status).?;
    const row = gtk_widget_get_first_child(rows).?;
    try std.testing.expectEqualStrings("pod · Running", std.mem.span(gtk_label_get_text(row)));
}

extern "gtk-4" fn gtk_widget_get_next_sibling(*Object) ?*Object;
extern "gtk-4" fn gtk_widget_is_sensitive(*Object) c_int;
extern "gtk-4" fn gtk_widget_measure(*Object, c_int, c_int, *c_int, *c_int, ?*c_int, ?*c_int) void;

test "workspace controls fit a compact sidebar" {
    try std.testing.expect(gtk_init_check() != 0);
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    _ = try client.Client.attachWithEffects(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "development", &ignoreEffect, null);
    const rows = gtk_widget_get_next_sibling(gtk_widget_get_first_child(sidebar).?).?;
    try waitForRow(rows, "pod · Running");
    const actions = gtk_widget_get_next_sibling(gtk_widget_get_first_child(rows).?).?;
    var minimum: c_int = 0;
    var natural: c_int = 0;
    gtk_widget_measure(actions, 0, -1, &minimum, &natural, null, null);
    try std.testing.expect(minimum <= 280);
}

test "essential reload command uses workspace reconnect without disabling the client" {
    try std.testing.expect(gtk_init_check() != 0);
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    const connection = try client.Client.attachWithEffects(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "development", &ignoreEffect, null);
    const rows = gtk_widget_get_next_sibling(gtk_widget_get_first_child(sidebar).?).?;
    try waitForRow(rows, "pod · Running");
    try connection.reloadWorkspace("pod");
    try waitForRow(rows, "pod · StaleFrameSeen");
    try std.testing.expect(gtk_widget_is_sensitive(rows) != 0);
}

test "GTK notification badge remains visible without desktop banners and clears on selection" {
    try std.testing.expect(gtk_init_check() != 0);
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    try client.Client.attach(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "notification-badge");
    const rows = gtk_widget_get_next_sibling(gtk_widget_get_first_child(sidebar).?).?;
    try waitForRow(rows, "pod · Running · ●");
    const actions = gtk_widget_get_next_sibling(gtk_widget_get_first_child(rows).?).?;
    g_signal_emit_by_name(try findButton(actions, "Select"), "clicked");
    try waitForRow(rows, "pod · Running");
}

test "GTK sidebar honors shared aliases order and collapsed hidden workspaces" {
    try std.testing.expect(gtk_init_check() != 0);
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    try client.Client.attach(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "sidebar-layout");
    const status = gtk_widget_get_first_child(sidebar).?;
    const rows = gtk_widget_get_next_sibling(status).?;
    const deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (std.mem.eql(u8, std.mem.span(gtk_label_get_text(status)), "Workspaces")) break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    const first = gtk_widget_get_first_child(rows).?;
    try std.testing.expectEqualStrings("Other pod · Stopped", std.mem.span(gtk_label_get_text(first)));
    const first_actions = gtk_widget_get_next_sibling(first).?;
    const second = gtk_widget_get_next_sibling(first_actions).?;
    try std.testing.expectEqualStrings("Work pod · Running", std.mem.span(gtk_label_get_text(second)));
    const second_actions = gtk_widget_get_next_sibling(second).?;
    const expand = gtk_widget_get_next_sibling(second_actions).?;
    try std.testing.expectEqualStrings("Expand hidden", std.mem.span(gtk_button_get_label(expand)));
    try std.testing.expect(gtk_widget_get_next_sibling(expand) == null);
}

test "selected hidden workspace stays reachable when its section is collapsed" {
    try std.testing.expect(gtk_init_check() != 0);
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    try client.Client.attach(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "sidebar-selected-hidden");
    const status = gtk_widget_get_first_child(sidebar).?;
    const rows = gtk_widget_get_next_sibling(status).?;
    const deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (std.mem.eql(u8, std.mem.span(gtk_label_get_text(status)), "Workspaces")) break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    const heading = gtk_widget_get_first_child(rows) orelse return error.SelectedWorkspaceNotReachable;
    const selected = gtk_widget_get_next_sibling(heading) orelse return error.SelectedWorkspaceNotReachable;
    try std.testing.expectEqualStrings("pod · Running", std.mem.span(gtk_label_get_text(selected)));
    const actions = gtk_widget_get_next_sibling(selected).?;
    try std.testing.expect(gtk_widget_get_next_sibling(actions) == null);
}

test "GTK client refreshes status without a user action" {
    try std.testing.expect(gtk_init_check() != 0);
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    try client.Client.attach(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "periodic-status");
    const rows = gtk_widget_get_next_sibling(gtk_widget_get_first_child(sidebar).?).?;
    const deadline = std.time.milliTimestamp() + 8000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (gtk_widget_get_first_child(rows)) |row| {
            if (std.mem.eql(u8, std.mem.span(gtk_label_get_text(row)), "pod · Stopped")) return;
        }
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.StatusDidNotRefresh;
}

test "backend crash disables workspace actions" {
    try std.testing.expect(gtk_init_check() != 0);
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    try client.Client.attach(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "exit");
    const status = gtk_widget_get_first_child(sidebar).?;
    const deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (std.mem.eql(u8, std.mem.span(gtk_label_get_text(status)), "Workspace backend disconnected")) break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expectEqualStrings("Workspace backend disconnected", std.mem.span(gtk_label_get_text(status)));
    const rows = gtk_widget_get_next_sibling(status).?;
    try std.testing.expectEqual(@as(c_int, 0), gtk_widget_is_sensitive(rows));
}

fn recordRestart(_: *anyopaque, data: ?*anyopaque, effect: client.TerminalEffect) !void {
    const restarted: *bool = @ptrCast(@alignCast(data.?));
    if (std.mem.eql(u8, effect.kind, "platform_restart")) restarted.* = true;
}

fn waitForStatus(status: *Object, expected: []const u8) !void {
    const deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (std.mem.eql(u8, std.mem.span(gtk_label_get_text(status)), expected)) return;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.StatusDidNotArrive;
}

test "backend crash exposes an enabled application restart action" {
    try std.testing.expect(gtk_init_check() != 0);
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    var restarted = false;
    _ = try client.Client.attachWithEffects(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "exit", &recordRestart, &restarted);
    const status = gtk_widget_get_first_child(sidebar).?;
    try waitForStatus(status, "Workspace backend disconnected");
    const rows = gtk_widget_get_next_sibling(status).?;
    const progress = gtk_widget_get_next_sibling(rows).?;
    const recovery = gtk_widget_get_next_sibling(progress).?;
    const button = try findButton(recovery, "Restart DevSpace");
    try std.testing.expect(gtk_widget_is_sensitive(button) != 0);
    g_signal_emit_by_name(button, "clicked");
    try std.testing.expect(restarted);
}

test "application restart waits for the old frontend to exit" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const executable = try std.fs.path.join(std.testing.allocator, &.{ directory, "frontend" });
    defer std.testing.allocator.free(executable);
    const marker = try std.fs.path.join(std.testing.allocator, &.{ directory, "started" });
    defer std.testing.allocator.free(marker);
    const script = try std.fmt.allocPrint(std.testing.allocator, "#!/bin/sh\nprintf restarted > '{s}'\n", .{marker});
    defer std.testing.allocator.free(script);
    const file = try temporary.dir.createFile("frontend", .{ .mode = 0o700 });
    try file.writeAll(script);
    file.close();
    var old = std.process.Child.init(&.{ "/bin/sleep", "30" }, std.testing.allocator);
    try old.spawn();
    var reaped = false;
    defer if (!reaped) {
        _ = old.kill() catch {};
    };
    try client.queueApplicationRestart(executable, @intCast(old.id));
    std.Thread.sleep(100 * std.time.ns_per_ms);
    try std.testing.expectError(error.FileNotFound, temporary.dir.access("started", .{}));
    _ = try old.kill();
    reaped = true;
    const deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        temporary.dir.access("started", .{}) catch {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        return;
    }
    return error.FrontendDidNotRestart;
}

test "application restart also waits for its owned backend cleanup" {
    try std.testing.expect(gtk_init_check() != 0);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const executable = try std.fs.path.join(std.testing.allocator, &.{ directory, "frontend" });
    defer std.testing.allocator.free(executable);
    const marker = try std.fs.path.join(std.testing.allocator, &.{ directory, "started" });
    defer std.testing.allocator.free(marker);
    const script = try std.fmt.allocPrint(std.testing.allocator, "#!/bin/sh\nprintf restarted > '{s}'\n", .{marker});
    defer std.testing.allocator.free(script);
    const file = try temporary.dir.createFile("frontend", .{ .mode = 0o700 });
    try file.writeAll(script);
    file.close();
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    var destroyed = false;
    defer if (!destroyed) g_object_unref(sidebar);
    const connection = try client.Client.attachWithEffects(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "development", null, null);
    try waitForStatus(gtk_widget_get_first_child(sidebar).?, "Workspaces");
    var old = std.process.Child.init(&.{ "/bin/sleep", "30" }, std.testing.allocator);
    try old.spawn();
    var reaped = false;
    defer if (!reaped) {
        _ = old.kill() catch {};
    };
    try connection.queueRestart(executable, @intCast(old.id));
    _ = try old.kill();
    reaped = true;
    std.Thread.sleep(200 * std.time.ns_per_ms);
    try std.testing.expectError(error.FileNotFound, temporary.dir.access("started", .{}));
    g_object_unref(sidebar);
    destroyed = true;
    const deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        temporary.dir.access("started", .{}) catch {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        return;
    }
    return error.FrontendDidNotRestart;
}

extern "gtk-4" fn gtk_button_get_label(*Object) [*:0]const u8;
extern "gobject-2.0" fn g_signal_emit_by_name(*Object, [*:0]const u8, ...) void;
extern "gtk-4" fn gtk_button_get_type() usize;
extern "gobject-2.0" fn g_type_check_instance_is_a(*Object, usize) c_int;
extern "gtk-4" fn gtk_window_get_toplevels() *Object;
extern "gtk-4" fn gtk_window_get_child(*Object) ?*Object;
extern "gtk-4" fn gtk_window_get_title(*Object) ?[*:0]const u8;
extern "gtk-4" fn gtk_window_destroy(*Object) void;
extern "gtk-4" fn gtk_editable_set_text(*Object, [*:0]const u8) void;
extern "gio-2.0" fn g_list_model_get_n_items(*Object) c_uint;
extern "gio-2.0" fn g_list_model_get_item(*Object, c_uint) ?*Object;
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern "c" fn unsetenv([*:0]const u8) c_int;

fn rejectTerminal(_: *anyopaque, _: ?*anyopaque, _: client.TerminalEffect) !void {
    return error.TestTerminalLaunchFailed;
}

test "frontend launch failure is reported without disabling workspace actions" {
    try std.testing.expect(gtk_init_check() != 0);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const events = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/events", .{directory}, 0);
    defer std.testing.allocator.free(events);
    const shutdown = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/shutdown", .{directory}, 0);
    defer std.testing.allocator.free(shutdown);
    try std.testing.expectEqual(@as(c_int, 0), setenv("DEVSPACE_TEST_EVENTS", events, 1));
    defer _ = unsetenv("DEVSPACE_TEST_EVENTS");
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    var destroyed = false;
    defer if (!destroyed) {
        g_object_unref(sidebar);
    };
    _ = try client.Client.attachWithEffects(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", shutdown, &rejectTerminal, null);
    const status = gtk_widget_get_first_child(sidebar).?;
    const rows = gtk_widget_get_next_sibling(status).?;
    var deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (std.mem.eql(u8, std.mem.span(gtk_label_get_text(status)), "Workspaces")) break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    const actions = gtk_widget_get_next_sibling(gtk_widget_get_first_child(rows).?).?;
    const open = gtk_widget_get_next_sibling(gtk_widget_get_next_sibling(gtk_widget_get_first_child(actions).?).?).?;
    g_signal_emit_by_name(open, "clicked");
    var reported = false;
    deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        const contents = temporary.dir.readFileAlloc(std.testing.allocator, "events", 64 * 1024) catch continue;
        defer std.testing.allocator.free(contents);
        if (std.mem.indexOf(u8, contents, "\"terminal_launch_failed\"") != null) {
            reported = true;
            break;
        }
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expect(reported);
    try std.testing.expectEqual(@as(c_int, 1), gtk_widget_is_sensitive(rows));
    g_object_unref(sidebar);
    destroyed = true;
    deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (temporary.dir.access("shutdown", .{})) |_| return else |_| {}
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.BackendDidNotHandleShutdown;
}

test "GTK rename dialog sends a Unicode alias and updates the row" {
    try std.testing.expect(gtk_init_check() != 0);
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    try client.Client.attach(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "sidebar-editing");
    const status = gtk_widget_get_first_child(sidebar).?;
    const rows = gtk_widget_get_next_sibling(status).?;
    var deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (std.mem.eql(u8, std.mem.span(gtk_label_get_text(status)), "Workspaces")) break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    const actions = gtk_widget_get_next_sibling(gtk_widget_get_first_child(rows).?).?;
    var button = gtk_widget_get_first_child(actions);
    var rename: ?*Object = null;
    while (button) |current| : (button = gtk_widget_get_next_sibling(current)) {
        if (std.mem.eql(u8, std.mem.span(gtk_button_get_label(current)), "Rename")) rename = current;
    }
    g_signal_emit_by_name(rename orelse return error.MissingRenameControl, "clicked");
    const windows = gtk_window_get_toplevels();
    try std.testing.expect(g_list_model_get_n_items(windows) > 0);
    const dialog = g_list_model_get_item(windows, 0).?;
    defer {
        gtk_window_destroy(dialog);
        g_object_unref(dialog);
    }
    try std.testing.expectEqualStrings("Rename workspace", std.mem.span(gtk_window_get_title(dialog).?));
    const content = gtk_window_get_child(dialog).?;
    const entry = gtk_widget_get_next_sibling(gtk_widget_get_first_child(content).?).?;
    gtk_editable_set_text(entry, "Work pod α with spaces");
    const buttons = gtk_widget_get_next_sibling(entry).?;
    g_signal_emit_by_name(gtk_widget_get_first_child(buttons).?, "clicked");
    deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        const row = gtk_widget_get_first_child(rows).?;
        if (std.mem.eql(u8, std.mem.span(gtk_label_get_text(row)), "Work pod α with spaces · Running")) return;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.AliasNotUpdated;
}

fn waitForSectionButton(rows: *Object, label: []const u8) !*Object {
    const deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (gtk_widget_get_first_child(rows)) |first| {
            if (g_type_check_instance_is_a(first, gtk_button_get_type()) != 0 and
                std.mem.eql(u8, std.mem.span(gtk_button_get_label(first)), label)) return first;
        }
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.MissingSectionControl;
}

fn waitForRow(rows: *Object, text: []const u8) !void {
    const deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (gtk_widget_get_first_child(rows)) |row| {
            if (std.mem.eql(u8, std.mem.span(gtk_label_get_text(row)), text)) return;
        }
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.RowDidNotUpdate;
}

fn findButton(box: *Object, label: []const u8) !*Object {
    var child = gtk_widget_get_first_child(box);
    while (child) |item| : (child = gtk_widget_get_next_sibling(item)) {
        if (g_type_check_instance_is_a(item, gtk_button_get_type()) != 0 and
            std.mem.eql(u8, std.mem.span(gtk_button_get_label(item)), label)) return item;
    }
    return error.ButtonNotFound;
}

fn findWindow(title: []const u8) !*Object {
    const windows = gtk_window_get_toplevels();
    var index: c_uint = 0;
    while (index < g_list_model_get_n_items(windows)) : (index += 1) {
        const window = g_list_model_get_item(windows, index).?;
        if (gtk_window_get_title(window)) |actual| {
            if (std.mem.eql(u8, std.mem.span(actual), title)) return window;
        }
        g_object_unref(window);
    }
    return error.DialogNotFound;
}

test "GTK creates workspace with repository and optional ID from native dialog" {
    try std.testing.expect(gtk_init_check() != 0);
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    try client.Client.attach(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "development");
    const rows = gtk_widget_get_next_sibling(gtk_widget_get_first_child(sidebar).?).?;
    try waitForRow(rows, "pod · Running");
    const create = try findButton(sidebar, "New workspace");
    g_signal_emit_by_name(create, "clicked");
    const window = try findWindow("Create workspace");
    defer g_object_unref(window);
    const content = gtk_window_get_child(window).?;
    const repository = gtk_widget_get_next_sibling(gtk_widget_get_first_child(content).?).?;
    gtk_editable_set_text(repository, "https://example.invalid/α repo.git");
    const id = gtk_widget_get_next_sibling(gtk_widget_get_next_sibling(repository).?).?;
    gtk_editable_set_text(id, "new-pod");
    const buttons = gtk_widget_get_next_sibling(id).?;
    g_signal_emit_by_name(try findButton(buttons, "Create"), "clicked");
    try waitForRow(rows, "pod · Created");
}

test "GTK recreation requires confirmation and cancellation sends no operation" {
    try std.testing.expect(gtk_init_check() != 0);
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    try client.Client.attach(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "development");
    const rows = gtk_widget_get_next_sibling(gtk_widget_get_first_child(sidebar).?).?;
    try waitForRow(rows, "pod · Running");
    var actions = gtk_widget_get_next_sibling(gtk_widget_get_first_child(rows).?).?;
    g_signal_emit_by_name(try findButton(actions, "Recreate"), "clicked");
    const cancelled = try findWindow("Recreate workspace");
    const cancel_content = gtk_window_get_child(cancelled).?;
    const cancel_buttons = gtk_widget_get_next_sibling(gtk_widget_get_first_child(cancel_content).?).?;
    g_signal_emit_by_name(try findButton(cancel_buttons, "Cancel"), "clicked");
    g_object_unref(cancelled);
    while (g_main_context_iteration(null, 0) != 0) {}
    try std.testing.expectEqualStrings("pod · Running", std.mem.span(gtk_label_get_text(gtk_widget_get_first_child(rows).?)));
    actions = gtk_widget_get_next_sibling(gtk_widget_get_first_child(rows).?).?;
    g_signal_emit_by_name(try findButton(actions, "Recreate"), "clicked");
    const confirmed = try findWindow("Recreate workspace");
    defer g_object_unref(confirmed);
    const content = gtk_window_get_child(confirmed).?;
    const buttons = gtk_widget_get_next_sibling(gtk_widget_get_first_child(content).?).?;
    g_signal_emit_by_name(try findButton(buttons, "Recreate"), "clicked");
    try waitForRow(rows, "pod · Recreated");
}

test "GTK displays live provisioning output and cancels by request identity" {
    try std.testing.expect(gtk_init_check() != 0);
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    try client.Client.attach(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "operation-progress");
    const status = gtk_widget_get_first_child(sidebar).?;
    const rows = gtk_widget_get_next_sibling(status).?;
    const deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (std.mem.eql(u8, std.mem.span(gtk_label_get_text(status)), "Workspaces")) break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    const progress = gtk_widget_get_next_sibling(rows) orelse return error.MissingProgressPanel;
    const heading = gtk_widget_get_first_child(progress) orelse return error.MissingProgressHeading;
    try std.testing.expectEqualStrings("start · pod · running", std.mem.span(gtk_label_get_text(heading)));
    const log = gtk_widget_get_next_sibling(heading).?;
    try std.testing.expectEqualStrings("Preparing λ界🙂\nChecking provider\n", std.mem.span(gtk_label_get_text(log)));
    const cancel = gtk_widget_get_next_sibling(log).?;
    try std.testing.expectEqualStrings("Cancel operation", std.mem.span(gtk_button_get_label(cancel)));
    g_signal_emit_by_name(cancel, "clicked");
    const finished = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < finished) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (gtk_widget_get_first_child(rows)) |row| {
            if (std.mem.eql(u8, std.mem.span(gtk_label_get_text(row)), "pod · Cancelled")) {
                try std.testing.expect(gtk_widget_get_first_child(progress) == null);
                return;
            }
        }
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.CancellationNotAcknowledged;
}

test "provisioning updates retain unchanged sidebar widgets" {
    try std.testing.expect(gtk_init_check() != 0);
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    try client.Client.attach(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "stable-sidebar");
    const status = gtk_widget_get_first_child(sidebar).?;
    const rows = gtk_widget_get_next_sibling(status).?;
    const progress = gtk_widget_get_next_sibling(rows).?;
    var deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (std.mem.eql(u8, std.mem.span(gtk_label_get_text(status)), "Workspaces")) break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    const row = g_object_ref_sink(gtk_widget_get_first_child(rows).?);
    defer g_object_unref(row);
    deadline = std.time.milliTimestamp() + 8000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (gtk_widget_get_first_child(progress)) |heading| {
            const output = gtk_widget_get_next_sibling(heading).?;
            if (!std.mem.eql(u8, std.mem.span(gtk_label_get_text(output)), "Progress 1")) {
                try std.testing.expect(gtk_widget_get_first_child(rows).? == row);
                return;
            }
        }
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.ProgressDidNotUpdate;
}

test "GTK hide control updates workspace visibility through the backend" {
    try std.testing.expect(gtk_init_check() != 0);
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    try client.Client.attach(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "sidebar-editing");
    const status = gtk_widget_get_first_child(sidebar).?;
    const rows = gtk_widget_get_next_sibling(status).?;
    var deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (std.mem.eql(u8, std.mem.span(gtk_label_get_text(status)), "Workspaces")) break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    const actions = gtk_widget_get_next_sibling(gtk_widget_get_first_child(rows).?).?;
    var button = gtk_widget_get_first_child(actions);
    var hide: ?*Object = null;
    while (button) |current| : (button = gtk_widget_get_next_sibling(current)) {
        if (std.mem.eql(u8, std.mem.span(gtk_button_get_label(current)), "Hide")) hide = current;
    }
    g_signal_emit_by_name(hide orelse return error.MissingHideControl, "clicked");
    deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (gtk_widget_get_first_child(rows)) |first| {
            if (g_type_check_instance_is_a(first, gtk_button_get_type()) != 0) {
                const hidden_row = gtk_widget_get_next_sibling(first).?;
                const hidden_actions = gtk_widget_get_next_sibling(hidden_row).?;
                const show = gtk_widget_get_next_sibling(gtk_widget_get_next_sibling(gtk_widget_get_first_child(hidden_actions).?).?).?;
                try std.testing.expectEqualStrings("Show", std.mem.span(gtk_button_get_label(show)));
                g_signal_emit_by_name(first, "clicked");
                const expand = try waitForSectionButton(rows, "Expand hidden");
                try std.testing.expect(gtk_widget_get_next_sibling(expand) == null);
                g_signal_emit_by_name(expand, "clicked");
                const collapse = try waitForSectionButton(rows, "Collapse hidden");
                const revealed = gtk_widget_get_next_sibling(collapse).?;
                try std.testing.expectEqualStrings("pod · Running", std.mem.span(gtk_label_get_text(revealed)));
                return;
            }
        }
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.HideDidNotUpdateVisibility;
}

var launched: bool = false;
var platform_notified: bool = false;
fn platformNotification(_: *anyopaque, _: ?*anyopaque, effect: client.TerminalEffect) !void {
    if (!std.mem.eql(u8, effect.kind, "platform_notify")) return;
    try std.testing.expectEqualStrings("pod", effect.workspaceID);
    try std.testing.expectEqualStrings("Claude finished", effect.message.?);
    try std.testing.expectEqualStrings("Work α", effect.title.?);
    platform_notified = true;
}

test "GTK routes authenticated platform notifications to its desktop adapter" {
    try std.testing.expect(gtk_init_check() != 0);
    platform_notified = false;
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    _ = try client.Client.attachWithEffects(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "platform-notification", &platformNotification, null);
    const rows = gtk_widget_get_next_sibling(gtk_widget_get_first_child(sidebar).?).?;
    try waitForRow(rows, "pod · Running · ●");
    try std.testing.expect(platform_notified);
}

test "workspace activation queues selection until the backend snapshot is ready" {
    try std.testing.expect(gtk_init_check() != 0);
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    const peer = try client.Client.attachWithEffects(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "queued-selection", &ignoreEffect, null);
    try peer.selectWorkspace("pod", false);
    const rows = gtk_widget_get_next_sibling(gtk_widget_get_first_child(sidebar).?).?;
    try waitForRow(rows, "pod · Selected");
}

test "workspace activation must not wake a stopped workspace" {
    try std.testing.expect(gtk_init_check() != 0);
    launched = false;
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    const peer = try client.Client.attachWithEffects(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "queued-stopped", &terminalEffect, null);
    try peer.selectWorkspace("pod", true);
    const rows = gtk_widget_get_next_sibling(gtk_widget_get_first_child(sidebar).?).?;
    try waitForRow(rows, "pod · Selected");
    try std.testing.expect(!launched);
}

fn unavailableNotification(_: *anyopaque, _: ?*anyopaque, _: client.TerminalEffect) !void {
    return error.TestNotificationServiceUnavailable;
}

test "desktop adapter failure preserves the notification badge and recovery actions" {
    try std.testing.expect(gtk_init_check() != 0);
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    _ = try client.Client.attachWithEffects(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "platform-notification", &unavailableNotification, null);
    const status = gtk_widget_get_first_child(sidebar).?;
    const rows = gtk_widget_get_next_sibling(status).?;
    try waitForRow(rows, "pod · Running · ●");
    try std.testing.expectEqualStrings("Desktop notification unavailable", std.mem.span(gtk_label_get_text(status)));
    try std.testing.expect(gtk_widget_is_sensitive(rows) != 0);
}

fn ignoreEffect(_: *anyopaque, _: ?*anyopaque, _: client.TerminalEffect) !void {}

test "ded launches Zed with one remote URL argument and preserves terminal actions on failure" {
    try std.testing.expect(gtk_init_check() != 0);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const old_path = try std.testing.allocator.dupeZ(u8, std.posix.getenv("PATH") orelse "/usr/bin:/bin");
    defer std.testing.allocator.free(old_path);
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}:{s}", .{ directory, old_path }, 0);
    defer std.testing.allocator.free(path);
    const marker = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/zed-url", .{directory}, 0);
    defer std.testing.allocator.free(marker);
    _ = setenv("PATH", path, 1);
    defer _ = setenv("PATH", old_path, 1);
    _ = setenv("DEVSPACE_TEST_ZED_URL", marker, 1);
    defer _ = unsetenv("DEVSPACE_TEST_ZED_URL");
    for ([_]bool{ false, true }) |fails| {
        try temporary.dir.writeFile(.{ .sub_path = "zed", .data = if (fails) "#!/bin/sh\nexit 127\n" else "#!/bin/sh\n[ \"$#\" -eq 1 ] || exit 64\nprintf '%s' \"$1\" > \"$DEVSPACE_TEST_ZED_URL\"\n" });
        const executable = try temporary.dir.openFile("zed", .{});
        try executable.chmod(0o700);
        executable.close();
        const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
        defer g_object_unref(sidebar);
        try client.Client.attach(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "platform-zed");
        const status = gtk_widget_get_first_child(sidebar).?;
        const rows = gtk_widget_get_next_sibling(status).?;
        try waitForRow(rows, "pod · Running");
        const deadline = std.time.milliTimestamp() + 3000;
        var observed = false;
        while (std.time.milliTimestamp() < deadline) {
            while (g_main_context_iteration(null, 0) != 0) {}
            if (fails) {
                if (std.mem.indexOf(u8, std.mem.span(gtk_label_get_text(status)), "Zed") != null) {
                    observed = true;
                    break;
                }
            } else if (temporary.dir.readFileAlloc(std.testing.allocator, "zed-url", 1024)) |url| {
                defer std.testing.allocator.free(url);
                try std.testing.expectEqualStrings("ssh://pod.devpod/workspace/a%20b/%CE%B1", url);
                observed = true;
                break;
            } else |_| {}
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
        try std.testing.expect(observed);
        try std.testing.expect(gtk_widget_is_sensitive(rows) != 0);
    }
}

test "notification listener failure stays visible while workspace actions remain usable" {
    try std.testing.expect(gtk_init_check() != 0);
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    _ = try client.Client.attachWithEffects(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "notification-listener-unavailable", &ignoreEffect, null);
    const status = gtk_widget_get_first_child(sidebar).?;
    const rows = gtk_widget_get_next_sibling(status).?;
    try waitForRow(rows, "pod · Running");
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(gtk_label_get_text(status)), "listener port is already in use") != null);
    try std.testing.expect(gtk_widget_is_sensitive(rows) != 0);
    const actions = gtk_widget_get_next_sibling(gtk_widget_get_first_child(rows).?).?;
    const stop = gtk_widget_get_next_sibling(gtk_widget_get_first_child(actions).?).?;
    g_signal_emit_by_name(stop, "clicked");
    try waitForRow(rows, "pod · Stopped");
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(gtk_label_get_text(status)), "listener port is already in use") != null);
}

test "terminal connection failure remains visible after automatic refresh" {
    try std.testing.expect(gtk_init_check() != 0);
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    _ = try client.Client.attachWithEffects(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "terminal-error", &ignoreEffect, null);
    const status = gtk_widget_get_first_child(sidebar).?;
    const rows = gtk_widget_get_next_sibling(status).?;
    var deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (std.mem.eql(u8, std.mem.span(gtk_label_get_text(status)), "Workspaces")) break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    const actions = gtk_widget_get_next_sibling(gtk_widget_get_first_child(rows).?).?;
    const open = gtk_widget_get_next_sibling(gtk_widget_get_next_sibling(gtk_widget_get_first_child(actions).?).?).?;
    g_signal_emit_by_name(open, "clicked");
    var saw_error = false;
    deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (std.mem.eql(u8, std.mem.span(gtk_label_get_text(status)), "SSH authentication failed")) {
            saw_error = true;
            break;
        }
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expect(saw_error);
    deadline = std.time.milliTimestamp() + 8000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        const row = gtk_widget_get_first_child(rows).?;
        if (std.mem.eql(u8, std.mem.span(gtk_label_get_text(row)), "pod · Refreshed")) {
            try std.testing.expectEqualStrings("SSH authentication failed", std.mem.span(gtk_label_get_text(status)));
            return;
        }
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.AutomaticRefreshNotObserved;
}

fn terminalEffect(_: *anyopaque, _: ?*anyopaque, effect: client.TerminalEffect) !void {
    try std.testing.expectEqualStrings("/bin/sh", effect.executable.?);
    try std.testing.expectEqualStrings("pod", effect.workspaceID);
    try std.testing.expectEqualStrings("-c", effect.arguments[0]);
    launched = true;
}

test "Open routes backend terminal effect to host adapter" {
    try std.testing.expect(gtk_init_check() != 0);
    launched = false;
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    _ = try client.Client.attachWithEffects(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "development", &terminalEffect, null);
    const status = gtk_widget_get_first_child(sidebar).?;
    const rows = gtk_widget_get_next_sibling(status).?;
    var deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (std.mem.eql(u8, std.mem.span(gtk_label_get_text(status)), "Workspaces")) break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    const label = gtk_widget_get_first_child(rows).?;
    const actions = gtk_widget_get_next_sibling(label).?;
    const start = gtk_widget_get_first_child(actions).?;
    const stop = gtk_widget_get_next_sibling(start).?;
    const open = gtk_widget_get_next_sibling(stop) orelse return error.MissingOpenAction;
    try std.testing.expectEqualStrings("Open", std.mem.span(gtk_button_get_label(open)));
    g_signal_emit_by_name(open, "clicked");
    deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline and !launched) {
        while (g_main_context_iteration(null, 0) != 0) {}
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expect(launched);
}

test "destroying sidebar lets backend handle orderly shutdown" {
    try std.testing.expect(gtk_init_check() != 0);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const marker = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/shutdown", .{directory}, 0);
    defer std.testing.allocator.free(marker);
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    try client.Client.attach(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", marker);
    g_object_unref(sidebar);
    const deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (temporary.dir.access("shutdown", .{})) |_| return else |_| {}
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.BackendDidNotHandleShutdown;
}

test "GTK stop button sends command and refreshes snapshot" {
    try std.testing.expect(gtk_init_check() != 0);
    const sidebar = g_object_ref_sink(gtk_box_new(1, 6));
    defer g_object_unref(sidebar);
    try client.Client.attach(@ptrCast(sidebar), "Tests/Linux/fixtures/backend.py", "development");
    const status = gtk_widget_get_first_child(sidebar).?;
    const rows = gtk_widget_get_next_sibling(status).?;
    var deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        if (std.mem.eql(u8, std.mem.span(gtk_label_get_text(status)), "Workspaces")) break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    const label = gtk_widget_get_first_child(rows).?;
    const actions = gtk_widget_get_next_sibling(label) orelse return error.MissingWorkspaceActions;
    const start = gtk_widget_get_first_child(actions).?;
    const stop = gtk_widget_get_next_sibling(start).?;
    try std.testing.expectEqualStrings("Stop", std.mem.span(gtk_button_get_label(stop)));
    g_signal_emit_by_name(stop, "clicked");
    deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        while (g_main_context_iteration(null, 0) != 0) {}
        const current = gtk_widget_get_first_child(rows).?;
        if (std.mem.eql(u8, std.mem.span(gtk_label_get_text(current)), "pod · Stopped")) return;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.StopDidNotRefreshSnapshot;
}
