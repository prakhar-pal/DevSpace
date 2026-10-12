const std = @import("std");
const protocol = @import("backend_protocol.zig");
const allocator = std.heap.page_allocator;
var application_name_configured = false;
pub fn applicationIdentifier(channel: []const u8) [:0]const u8 {
    return if (std.mem.eql(u8, channel, "development")) "com.prakharp.devspace.dev" else "com.prakharp.devspace";
}
const Object = opaque {};
pub const TerminalEffect = struct {
    kind: []const u8,
    workspaceID: []const u8,
    generation: []const u8,
    paneID: ?[]const u8 = null,
    executable: ?[]const u8 = null,
    arguments: []const []const u8 = &.{},
    message: ?[]const u8 = null,
    title: ?[]const u8 = null,
};
pub const EffectHandler = *const fn (*anyopaque, ?*anyopaque, TerminalEffect) anyerror!void;

/// A surface owns copied identity, never slices into a temporary JSON frame.
/// Keeping its client alive also makes late widget disposal safe.
pub const TerminalBinding = struct {
    client: *Client,
    workspace: []u8,
    generation: []u8,
    pane: []u8,
    exited: bool = false,

    pub fn create(client: *Client, effect: TerminalEffect) !*TerminalBinding {
        const pane_id = effect.paneID orelse return error.MissingPaneIdentity;
        const workspace = try allocator.dupe(u8, effect.workspaceID);
        errdefer allocator.free(workspace);
        const generation = try allocator.dupe(u8, effect.generation);
        errdefer allocator.free(generation);
        const pane = try allocator.dupe(u8, pane_id);
        errdefer allocator.free(pane);
        const self = try allocator.create(TerminalBinding);
        self.* = .{ .client = client, .workspace = workspace, .generation = generation, .pane = pane };
        client.retain();
        return self;
    }

    pub fn report(self: *TerminalBinding, kind: []const u8, directory: ?[]const u8) void {
        if (std.mem.eql(u8, kind, "terminal_exit")) {
            if (self.exited) return;
            self.exited = true;
        }
        self.client.reportTerminal(kind, self.workspace, self.generation, self.pane, directory) catch {};
    }

    pub fn destroy(self: *TerminalBinding) void {
        self.client.release();
        allocator.free(self.workspace);
        allocator.free(self.generation);
        allocator.free(self.pane);
        allocator.destroy(self);
    }
};
const Callback = *const fn (?*Object, ?*Object, ?*anyopaque) callconv(.c) void;
extern "gio-2.0" fn g_subprocess_newv([*:null]const ?[*:0]const u8, c_uint, ?*?*anyopaque) ?*Object;
extern "gio-2.0" fn g_subprocess_get_stdin_pipe(*Object) *Object;
extern "gio-2.0" fn g_subprocess_get_stdout_pipe(*Object) *Object;
extern "gio-2.0" fn g_subprocess_force_exit(*Object) void;
extern "gio-2.0" fn g_subprocess_wait_async(*Object, ?*Object, Callback, ?*anyopaque) void;
extern "gio-2.0" fn g_subprocess_wait_finish(*Object, *Object, ?*?*anyopaque) c_int;
extern "gio-2.0" fn g_subprocess_get_successful(*Object) c_int;
extern "gio-2.0" fn g_subprocess_get_identifier(*Object) ?[*:0]const u8;
extern "gio-2.0" fn g_data_input_stream_new(*Object) *Object;
extern "gio-2.0" fn g_data_input_stream_read_line_async(*Object, c_int, ?*Object, Callback, ?*anyopaque) void;
extern "gio-2.0" fn g_data_input_stream_read_line_finish(*Object, *Object, *usize, ?*?*anyopaque) ?[*:0]u8;
extern "gio-2.0" fn g_output_stream_write_all(*Object, [*]const u8, usize, ?*usize, ?*Object, ?*?*anyopaque) c_int;
extern "gio-2.0" fn g_cancellable_new() *Object;
extern "gio-2.0" fn g_cancellable_cancel(*Object) void;
extern "gobject-2.0" fn g_object_unref(*Object) void;
extern "gobject-2.0" fn g_object_ref(*Object) *Object;
extern "gobject-2.0" fn g_object_weak_ref(*Object, *const fn (?*anyopaque, *Object) callconv(.c) void, ?*anyopaque) void;
extern "glib-2.0" fn g_free(?*anyopaque) void;
extern "glib-2.0" fn g_set_application_name([*:0]const u8) void;
extern "glib-2.0" fn g_timeout_add_seconds(c_uint, *const fn (?*anyopaque) callconv(.c) c_int, ?*anyopaque) c_uint;
extern "glib-2.0" fn g_source_remove(c_uint) c_int;
extern "gtk-4" fn gtk_label_new(?[*:0]const u8) *Object;
extern "gtk-4" fn gtk_label_set_text(*Object, [*:0]const u8) void;
extern "gtk-4" fn gtk_box_append(*Object, *Object) void;
extern "gtk-4" fn gtk_box_remove(*Object, *Object) void;
extern "gtk-4" fn gtk_widget_get_first_child(*Object) ?*Object;
extern "gtk-4" fn gtk_box_new(c_int, c_int) *Object;
extern "gtk-4" fn gtk_grid_new() *Object;
extern "gtk-4" fn gtk_grid_get_type() usize;
extern "gtk-4" fn gtk_grid_attach(*Object, *Object, c_int, c_int, c_int, c_int) void;
extern "gtk-4" fn gtk_grid_set_row_spacing(*Object, c_uint) void;
extern "gtk-4" fn gtk_grid_set_column_spacing(*Object, c_uint) void;
extern "gtk-4" fn gtk_widget_get_next_sibling(*Object) ?*Object;
extern "gtk-4" fn gtk_widget_set_sensitive(*Object, c_int) void;
extern "gtk-4" fn gtk_widget_set_visible(*Object, c_int) void;

/// Relaunch only this frontend, after its exit releases GTK and backend pipes.
/// The shell receives executable/PID as separate arguments, never shell text.
pub fn queueApplicationRestart(executable: []const u8, frontend_pid: u32) !void {
    return queueRestartAfterExit(executable, frontend_pid, null);
}

fn queueRestartAfterExit(executable: []const u8, frontend_pid: u32, backend_pid: ?[*:0]const u8) !void {
    if (frontend_pid <= 1) return error.InvalidFrontendPID;
    const path = try allocator.dupeZ(u8, executable);
    defer allocator.free(path);
    const pid = try std.fmt.allocPrintSentinel(allocator, "{d}", .{frontend_pid}, 0);
    defer allocator.free(pid);
    const arguments = [_:null]?[*:0]const u8{
        "/bin/sh",             "-c",    "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; if [ -n \"$3\" ]; then while kill -0 \"$3\" 2>/dev/null; do sleep 0.1; done; fi; exec \"$2\"",
        "devspace-restart",    pid.ptr, path.ptr,
        backend_pid orelse "",
    };
    const process = g_subprocess_newv(&arguments, 0, null) orelse return error.FrontendRestartFailed;
    g_subprocess_wait_async(process, null, &restartFinished, null);
}

fn restartFinished(process: ?*Object, result: ?*Object, _: ?*anyopaque) callconv(.c) void {
    _ = g_subprocess_wait_finish(process.?, result.?, null);
    g_object_unref(process.?);
}
extern "gtk-4" fn gtk_button_new_with_label([*:0]const u8) *Object;
extern "gtk-4" fn gtk_window_new() *Object;
extern "gtk-4" fn gtk_window_get_type() usize;
extern "gtk-4" fn gtk_window_set_title(*Object, [*:0]const u8) void;
extern "gtk-4" fn gtk_window_set_default_size(*Object, c_int, c_int) void;
extern "gtk-4" fn gtk_window_set_modal(*Object, c_int) void;
extern "gtk-4" fn gtk_window_set_transient_for(*Object, *Object) void;
extern "gtk-4" fn gtk_window_set_destroy_with_parent(*Object, c_int) void;
extern "gtk-4" fn gtk_window_set_child(*Object, *Object) void;
extern "gtk-4" fn gtk_window_present(*Object) void;
extern "gtk-4" fn gtk_window_destroy(*Object) void;
extern "gtk-4" fn gtk_widget_get_root(*Object) ?*Object;
extern "gtk-4" fn gtk_entry_new() *Object;
extern "gtk-4" fn gtk_editable_set_text(*Object, [*:0]const u8) void;
extern "gtk-4" fn gtk_editable_get_text(*Object) [*:0]const u8;
extern "gobject-2.0" fn g_type_check_instance_is_a(*Object, usize) c_int;
extern "gobject-2.0" fn g_signal_connect_data(*Object, [*:0]const u8, *const fn (*Object, ?*anyopaque) callconv(.c) void, ?*anyopaque, ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void, c_uint) c_ulong;

pub fn requestLine(gpa: std.mem.Allocator, id: u64, kind: []const u8, workspace_id: ?[]const u8) ![]u8 {
    const id_string = try std.fmt.allocPrint(gpa, "{d}", .{id});
    defer gpa.free(id_string);
    const json = try std.json.Stringify.valueAlloc(gpa, .{
        .version = protocol.version,
        .id = id_string,
        .kind = kind,
        .payload = if (workspace_id) |workspace| .{ .workspace_id = workspace } else null,
    }, .{});
    defer gpa.free(json);
    return std.fmt.allocPrint(gpa, "{s}\n", .{json});
}

pub fn terminalEventLine(gpa: std.mem.Allocator, id: u64, kind: []const u8, workspace: []const u8, generation: []const u8, pane: []const u8, directory: ?[]const u8) ![]u8 {
    const id_string = try std.fmt.allocPrint(gpa, "{d}", .{id});
    defer gpa.free(id_string);
    const json = try std.json.Stringify.valueAlloc(gpa, .{
        .version = protocol.version,
        .id = id_string,
        .kind = kind,
        .payload = .{ .workspace_id = workspace, .generation = generation, .pane_id = pane, .directory = directory },
    }, .{ .emit_null_optional_fields = false });
    defer gpa.free(json);
    return std.fmt.allocPrint(gpa, "{s}\n", .{json});
}

/// GLib owns pipe-read scheduling on GTK's main context. The sidebar's weak
/// notification cancels the pending read; that callback releases the client.
pub const Client = struct {
    process: *Object,
    input: *Object,
    cancellation: *Object,
    sidebar: ?*Object,
    status: *Object,
    rows: *Object,
    progress: *Object,
    recovery: *Object,
    next_id: u64 = 0,
    ready: bool = false,
    read_pending: bool = false,
    effect_handler: ?EffectHandler = null,
    effect_context: ?*anyopaque = null,
    references: usize = 1,
    refresh_timer: c_uint = 0,
    pending_poll: ?u64 = null,
    last_error: ?[:0]u8 = null,
    notification_warning: ?[:0]u8 = null,
    rendered_sidebar: ?[]u8 = null,
    pending_workspace: ?[]u8 = null,
    pending_open: bool = false,

    pub fn queueRestart(self: *Client, executable: []const u8, frontend_pid: u32) !void {
        try queueRestartAfterExit(executable, frontend_pid, g_subprocess_get_identifier(self.process));
    }

    pub fn reloadWorkspace(self: *Client, workspace: []const u8) !void {
        if (!self.ready or self.sidebar == null) return error.BackendDisconnected;
        self.clearError();
        self.request("reconnect", workspace) catch |err| {
            try self.showError("Workspace could not reload; try Reload again");
            return err;
        };
    }

    pub fn selectWorkspace(self: *Client, workspace: []const u8, open_terminal: bool) !void {
        if (workspace.len == 0 or workspace.len > 64) return error.InvalidWorkspaceID;
        if (self.ready) {
            if (self.rendered_sidebar) |json| {
                const snapshot = try std.json.parseFromSlice(protocol.Snapshot, allocator, json, .{ .ignore_unknown_fields = true });
                defer snapshot.deinit();
                for (snapshot.value.workspaces) |item| {
                    if (!std.mem.eql(u8, item.id, workspace)) continue;
                    try self.request("select", workspace);
                    if (open_terminal and std.mem.eql(u8, item.state, "Running")) try self.request("connect", workspace);
                    return;
                }
            }
        }
        const owned = try allocator.dupe(u8, workspace);
        if (self.pending_workspace) |previous| allocator.free(previous);
        self.pending_workspace = owned;
        self.pending_open = open_terminal;
    }

    fn showError(self: *Client, message: []const u8) !void {
        const owned = try allocator.dupeZ(u8, message);
        if (self.last_error) |previous| allocator.free(previous);
        self.last_error = owned;
        gtk_label_set_text(self.status, owned);
    }

    pub fn reportClipboardError(self: *Client, message: []const u8) void {
        if (self.sidebar != null) self.showError(message) catch {};
    }

    fn clearError(self: *Client) void {
        if (self.last_error) |previous| allocator.free(previous);
        self.last_error = null;
        gtk_label_set_text(self.status, self.notification_warning orelse "Workspaces");
    }

    fn launchZed(self: *Client, url: []const u8) !void {
        if (!std.mem.startsWith(u8, url, "ssh://") or std.mem.indexOfScalar(u8, url, 0) != null) return error.InvalidZedURL;
        const owned = try allocator.dupeZ(u8, url);
        defer allocator.free(owned);
        const arguments = [_:null]?[*:0]const u8{ "/usr/bin/env", "zed", owned.ptr, null };
        const process = g_subprocess_newv(&arguments, (1 << 3) | (1 << 5), null) orelse {
            try self.showError("Zed could not be launched; install zed and add it to PATH");
            return;
        };
        self.retain();
        g_subprocess_wait_async(process, null, &zedFinished, self);
    }

    fn zedFinished(process: ?*Object, result: ?*Object, data: ?*anyopaque) callconv(.c) void {
        const self: *Client = @ptrCast(@alignCast(data.?));
        defer self.release();
        defer g_object_unref(process.?);
        const waited = g_subprocess_wait_finish(process.?, result.?, null) != 0;
        if (self.sidebar != null and (!waited or g_subprocess_get_successful(process.?) == 0)) {
            self.showError("Zed could not be launched; install zed and add it to PATH") catch {};
        }
    }

    const Action = struct { client: *Client, kind: []const u8, workspace: []u8, name: ?[]u8 = null };

    const AliasDialog = struct {
        client: *Client,
        window: *Object,
        entry: *Object,
        workspace: []u8,

        fn save(_: *Object, data: ?*anyopaque) callconv(.c) void {
            const self: *AliasDialog = @ptrCast(@alignCast(data.?));
            self.client.requestAlias(self.workspace, std.mem.span(gtk_editable_get_text(self.entry))) catch {
                if (self.client.sidebar != null) gtk_label_set_text(self.client.status, "Workspace backend pipe failed");
                return;
            };
            gtk_window_destroy(self.window);
        }

        fn cancel(_: *Object, data: ?*anyopaque) callconv(.c) void {
            const self: *AliasDialog = @ptrCast(@alignCast(data.?));
            gtk_window_destroy(self.window);
        }

        fn destroyed(data: ?*anyopaque, _: *Object) callconv(.c) void {
            const self: *AliasDialog = @ptrCast(@alignCast(data.?));
            self.client.release();
            allocator.free(self.workspace);
            allocator.destroy(self);
        }
    };

    const LifecycleDialog = struct {
        client: *Client,
        window: *Object,
        kind: []const u8,
        workspace: []u8,
        repository: ?*Object = null,
        id: ?*Object = null,

        fn confirm(_: *Object, data: ?*anyopaque) callconv(.c) void {
            const self: *LifecycleDialog = @ptrCast(@alignCast(data.?));
            if (self.repository) |repository| {
                self.client.requestCreate(std.mem.span(gtk_editable_get_text(repository)), std.mem.span(gtk_editable_get_text(self.id.?))) catch {
                    gtk_label_set_text(self.client.status, "Workspace backend pipe failed");
                    return;
                };
            } else {
                self.client.request(self.kind, self.workspace) catch {
                    gtk_label_set_text(self.client.status, "Workspace backend pipe failed");
                    return;
                };
            }
            gtk_window_destroy(self.window);
        }

        fn cancel(_: *Object, data: ?*anyopaque) callconv(.c) void {
            const self: *LifecycleDialog = @ptrCast(@alignCast(data.?));
            gtk_window_destroy(self.window);
        }

        fn destroyed(data: ?*anyopaque, _: *Object) callconv(.c) void {
            const self: *LifecycleDialog = @ptrCast(@alignCast(data.?));
            self.client.release();
            allocator.free(self.workspace);
            allocator.destroy(self);
        }
    };

    fn showLifecycleDialog(self: *Client, kind: []const u8, workspace: []const u8) !void {
        if (!self.ready or self.sidebar == null) return error.BackendDisconnected;
        const data = try allocator.create(LifecycleDialog);
        errdefer allocator.destroy(data);
        const owned_workspace = try allocator.dupe(u8, workspace);
        errdefer allocator.free(owned_workspace);
        const creating = std.mem.eql(u8, kind, "create");
        const recreating = std.mem.eql(u8, kind, "recreate");
        const window = gtk_window_new();
        const content = gtk_box_new(1, 12);
        data.* = .{ .client = self, .window = window, .kind = kind, .workspace = owned_workspace };
        if (creating) {
            gtk_box_append(content, gtk_label_new("Repository URL or local folder"));
            data.repository = gtk_entry_new();
            gtk_box_append(content, data.repository.?);
            gtk_box_append(content, gtk_label_new("Workspace ID (optional)"));
            data.id = gtk_entry_new();
            gtk_box_append(content, data.id.?);
        } else {
            const warning = try std.fmt.allocPrintSentinel(allocator, "{s} workspace {s}? This may discard workspace data. This cannot be undone.", .{ if (recreating) "Recreate" else "Delete", workspace }, 0);
            defer allocator.free(warning);
            gtk_box_append(content, gtk_label_new(warning));
        }
        const buttons = gtk_box_new(0, 6);
        gtk_box_append(content, buttons);
        const confirm = gtk_button_new_with_label(if (creating) "Create" else if (recreating) "Recreate" else "Delete");
        const cancel = gtk_button_new_with_label("Cancel");
        gtk_box_append(buttons, confirm);
        gtk_box_append(buttons, cancel);
        self.retain();
        g_object_weak_ref(window, &LifecycleDialog.destroyed, data);
        _ = g_signal_connect_data(confirm, "clicked", &LifecycleDialog.confirm, data, null, 0);
        _ = g_signal_connect_data(cancel, "clicked", &LifecycleDialog.cancel, data, null, 0);
        gtk_window_set_title(window, if (creating) "Create workspace" else if (recreating) "Recreate workspace" else "Delete workspace");
        gtk_window_set_default_size(window, 400, -1);
        gtk_window_set_modal(window, 1);
        if (gtk_widget_get_root(self.sidebar.?)) |root| {
            if (g_type_check_instance_is_a(root, gtk_window_get_type()) != 0) {
                gtk_window_set_transient_for(window, root);
                gtk_window_set_destroy_with_parent(window, 1);
            }
        }
        gtk_window_set_child(window, content);
        gtk_window_present(window);
    }

    fn showAliasDialog(self: *Client, workspace: []const u8, name: []const u8) !void {
        const data = try allocator.create(AliasDialog);
        errdefer allocator.destroy(data);
        const owned_workspace = try allocator.dupe(u8, workspace);
        errdefer allocator.free(owned_workspace);
        const initial = try allocator.dupeZ(u8, name);
        defer allocator.free(initial);
        const window = gtk_window_new();
        const content = gtk_box_new(1, 12);
        gtk_box_append(content, gtk_label_new("Friendly name (leave empty to reset)"));
        const entry = gtk_entry_new();
        gtk_editable_set_text(entry, initial);
        gtk_box_append(content, entry);
        const buttons = gtk_box_new(0, 6);
        gtk_box_append(content, buttons);
        const save = gtk_button_new_with_label("Save");
        const cancel = gtk_button_new_with_label("Cancel");
        gtk_box_append(buttons, save);
        gtk_box_append(buttons, cancel);
        data.* = .{ .client = self, .window = window, .entry = entry, .workspace = owned_workspace };
        self.retain();
        g_object_weak_ref(window, &AliasDialog.destroyed, data);
        _ = g_signal_connect_data(save, "clicked", &AliasDialog.save, data, null, 0);
        _ = g_signal_connect_data(cancel, "clicked", &AliasDialog.cancel, data, null, 0);
        gtk_window_set_title(window, "Rename workspace");
        gtk_window_set_default_size(window, 340, -1);
        gtk_window_set_modal(window, 1);
        if (self.sidebar) |sidebar| {
            if (gtk_widget_get_root(sidebar)) |root| {
                if (g_type_check_instance_is_a(root, gtk_window_get_type()) != 0) {
                    gtk_window_set_transient_for(window, root);
                    gtk_window_set_destroy_with_parent(window, 1);
                }
            }
        }
        gtk_window_set_child(window, content);
        gtk_window_present(window);
    }

    fn refresh(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Client = @ptrCast(@alignCast(data.?));
        if (!self.ready or self.sidebar == null) {
            self.refresh_timer = 0;
            return 0;
        }
        self.request("poll", null) catch {
            self.ready = false;
            self.refresh_timer = 0;
            gtk_widget_set_sensitive(self.rows, 0);
            gtk_label_set_text(self.status, "Workspace backend pipe failed");
            gtk_widget_set_visible(self.recovery, 1);
            return 0;
        };
        return 1;
    }

    fn stopRefresh(self: *Client) void {
        if (self.refresh_timer != 0) _ = g_source_remove(self.refresh_timer);
        self.refresh_timer = 0;
    }

    const Shutdown = struct {
        process: *Object,
        input: *Object,
        timeout: c_uint = 0,

        fn expired(data: ?*anyopaque) callconv(.c) c_int {
            const self: *Shutdown = @ptrCast(@alignCast(data.?));
            self.timeout = 0;
            g_subprocess_force_exit(self.process);
            return 0;
        }

        fn exited(_: ?*Object, result: ?*Object, data: ?*anyopaque) callconv(.c) void {
            const self: *Shutdown = @ptrCast(@alignCast(data.?));
            _ = g_subprocess_wait_finish(self.process, result.?, null);
            if (self.timeout != 0) _ = g_source_remove(self.timeout);
            g_object_unref(self.input);
            g_object_unref(self.process);
            allocator.destroy(self);
        }
    };

    fn actionClicked(_: *Object, data: ?*anyopaque) callconv(.c) void {
        const action: *Action = @ptrCast(@alignCast(data.?));
        if (std.mem.eql(u8, action.kind, "restart")) {
            if (action.client.effect_handler) |handler| {
                handler(action.client, action.client.effect_context, .{
                    .kind = "platform_restart",
                    .workspaceID = "",
                    .generation = "",
                }) catch {
                    gtk_label_set_text(action.client.status, "Could not restart DevSpace; close and relaunch it");
                };
            }
            return;
        }
        if (std.mem.eql(u8, action.kind, "select")) {
            if (action.client.effect_handler) |handler| {
                handler(action.client, action.client.effect_context, .{
                    .kind = "platform_select",
                    .workspaceID = action.workspace,
                    .generation = "",
                }) catch {
                    gtk_label_set_text(action.client.status, "Could not select workspace");
                };
            } else action.client.selectWorkspace(action.workspace, false) catch {
                gtk_label_set_text(action.client.status, "Workspace backend pipe failed");
            };
            return;
        }
        if (std.mem.eql(u8, action.kind, "create") or std.mem.eql(u8, action.kind, "recreate") or std.mem.eql(u8, action.kind, "delete")) {
            action.client.showLifecycleDialog(action.kind, action.workspace) catch {
                gtk_label_set_text(action.client.status, "Could not open workspace dialog");
            };
            return;
        }
        if (std.mem.eql(u8, action.kind, "cancel")) {
            action.client.requestCancel(action.workspace) catch {
                gtk_label_set_text(action.client.status, "Workspace backend pipe failed");
            };
            return;
        }
        if (std.mem.eql(u8, action.kind, "alias")) {
            action.client.showAliasDialog(action.workspace, action.name orelse action.workspace) catch {
                gtk_label_set_text(action.client.status, "Could not open workspace rename dialog");
            };
            return;
        }
        action.client.request(action.kind, action.workspace) catch {
            gtk_label_set_text(action.client.status, "Workspace backend pipe failed");
        };
    }

    fn actionDestroyed(data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const action: *Action = @ptrCast(@alignCast(data.?));
        allocator.free(action.workspace);
        if (action.name) |name| allocator.free(name);
        allocator.destroy(action);
    }

    fn addAction(self: *Client, box: *Object, label: [*:0]const u8, kind: []const u8, workspace: []const u8) !*Action {
        const action = try allocator.create(Action);
        errdefer allocator.destroy(action);
        action.* = .{ .client = self, .kind = kind, .workspace = try allocator.dupe(u8, workspace) };
        const button = gtk_button_new_with_label(label);
        _ = g_signal_connect_data(button, "clicked", &actionClicked, action, &actionDestroyed, 0);
        if (g_type_check_instance_is_a(box, gtk_grid_get_type()) != 0) {
            var count: c_int = 0;
            var child = gtk_widget_get_first_child(box);
            while (child) |item| : (child = gtk_widget_get_next_sibling(item)) count += 1;
            gtk_grid_attach(box, button, @mod(count, 3), @divTrunc(count, 3), 1, 1);
        } else gtk_box_append(box, button);
        return action;
    }

    fn containsID(ids: []const []const u8, id: []const u8) bool {
        for (ids) |item| if (std.mem.eql(u8, item, id)) return true;
        return false;
    }

    fn appendWorkspace(self: *Client, workspace: protocol.Workspace, layout: protocol.Layout, badged: bool) !void {
        const name = layout.aliases.map.get(workspace.id) orelse workspace.id;
        const text = try std.fmt.allocPrintSentinel(allocator, "{s} · {s}{s}", .{ name, workspace.state, if (badged) " · ●" else "" }, 0);
        defer allocator.free(text);
        gtk_box_append(self.rows, gtk_label_new(text));
        const actions = gtk_grid_new();
        gtk_grid_set_column_spacing(actions, 4);
        gtk_grid_set_row_spacing(actions, 4);
        gtk_box_append(self.rows, actions);
        _ = try self.addAction(actions, "Start", "start", workspace.id);
        _ = try self.addAction(actions, "Stop", "stop", workspace.id);
        if (self.effect_handler != null) {
            _ = try self.addAction(actions, "Open", "connect", workspace.id);
            _ = try self.addAction(actions, "Reload", "reconnect", workspace.id);
        }
        const hidden = containsID(layout.hidden, workspace.id);
        _ = try self.addAction(actions, if (hidden) "Show" else "Hide", if (hidden) "show" else "hide", workspace.id);
        const rename = try self.addAction(actions, "Rename", "alias", workspace.id);
        rename.name = try allocator.dupe(u8, name);
        _ = try self.addAction(actions, "Recreate", "recreate", workspace.id);
        _ = try self.addAction(actions, "Delete", "delete", workspace.id);
        _ = try self.addAction(actions, "Select", "select", workspace.id);
    }

    pub fn attach(sidebar: *Object, executable: [:0]const u8, channel: [:0]const u8) !void {
        _ = try attachWithEffects(sidebar, executable, channel, null, null);
    }

    pub fn attachWithEffects(sidebar: *Object, executable: [:0]const u8, channel: [:0]const u8, handler: ?EffectHandler, context: ?*anyopaque) !*Client {
        // GLib's default is the upstream executable name. Desktop banners must
        // identify DevSpace, while each channel retains its distinct app ID.
        if (!application_name_configured) {
            g_set_application_name(if (std.mem.eql(u8, channel, "development")) "DevSpaceDev" else "DevSpace");
            application_name_configured = true;
        }
        const status = gtk_label_new("Starting workspace backend…");
        gtk_box_append(sidebar, status);
        const rows = gtk_box_new(1, 6);
        gtk_box_append(sidebar, rows);
        const progress = gtk_box_new(1, 6);
        gtk_box_append(sidebar, progress);
        const recovery = gtk_box_new(1, 6);
        gtk_box_append(sidebar, recovery);
        gtk_widget_set_visible(recovery, 0);
        const argv = [_:null]?[*:0]const u8{ executable.ptr, "--channel", channel.ptr };
        // G_SUBPROCESS_FLAGS_STDIN_PIPE | G_SUBPROCESS_FLAGS_STDOUT_PIPE.
        const process = g_subprocess_newv(&argv, 1 | 4, null) orelse {
            gtk_label_set_text(status, "Workspace backend could not start");
            return error.BackendLaunchFailed;
        };
        const self = try allocator.create(Client);
        self.* = .{
            .process = process,
            .input = g_data_input_stream_new(g_subprocess_get_stdout_pipe(process)),
            .cancellation = g_cancellable_new(),
            .sidebar = sidebar,
            .status = status,
            .rows = rows,
            .progress = progress,
            .recovery = recovery,
            .effect_handler = handler,
            .effect_context = context,
        };
        g_object_weak_ref(sidebar, &sidebarGone, self);
        _ = try self.addAction(sidebar, "New workspace", "create", "");
        _ = try self.addAction(recovery, "Restart DevSpace", "restart", "");
        self.request("handshake", null) catch {
            gtk_label_set_text(status, "Workspace backend pipe failed");
        };
        self.read();
        return self;
    }

    fn request(self: *Client, kind: []const u8, workspace: ?[]const u8) !void {
        const polling = std.mem.eql(u8, kind, "poll");
        // Never accumulate timer requests behind a slow DevPod operation.
        if (polling and self.pending_poll != null) return;
        self.next_id += 1;
        const line = try requestLine(allocator, self.next_id, kind, workspace);
        defer allocator.free(line);
        if (g_output_stream_write_all(g_subprocess_get_stdin_pipe(self.process), line.ptr, line.len, null, self.cancellation, null) == 0)
            return error.BackendWriteFailed;
        if (polling) self.pending_poll = self.next_id;
    }

    fn requestAlias(self: *Client, workspace: []const u8, name: []const u8) !void {
        if (self.sidebar == null or !self.ready) return error.BackendDisconnected;
        self.next_id += 1;
        const id = try std.fmt.allocPrint(allocator, "{d}", .{self.next_id});
        defer allocator.free(id);
        const json = try std.json.Stringify.valueAlloc(allocator, .{
            .version = protocol.version,
            .id = id,
            .kind = "alias",
            .payload = .{ .workspace_id = workspace, .name = name },
        }, .{});
        defer allocator.free(json);
        const line = try std.fmt.allocPrint(allocator, "{s}\n", .{json});
        defer allocator.free(line);
        if (g_output_stream_write_all(g_subprocess_get_stdin_pipe(self.process), line.ptr, line.len, null, self.cancellation, null) == 0) return error.BackendWriteFailed;
    }

    fn requestCancel(self: *Client, request_id: []const u8) !void {
        if (self.sidebar == null or !self.ready) return error.BackendDisconnected;
        self.next_id += 1;
        const id = try std.fmt.allocPrint(allocator, "{d}", .{self.next_id});
        defer allocator.free(id);
        const json = try std.json.Stringify.valueAlloc(allocator, .{
            .version = protocol.version,
            .id = id,
            .kind = "cancel",
            .payload = .{ .request_id = request_id },
        }, .{});
        defer allocator.free(json);
        const line = try std.fmt.allocPrint(allocator, "{s}\n", .{json});
        defer allocator.free(line);
        if (g_output_stream_write_all(g_subprocess_get_stdin_pipe(self.process), line.ptr, line.len, null, self.cancellation, null) == 0) return error.BackendWriteFailed;
    }

    fn requestCreate(self: *Client, repository: []const u8, workspace_id: []const u8) !void {
        if (self.sidebar == null or !self.ready) return error.BackendDisconnected;
        self.next_id += 1;
        const id = try std.fmt.allocPrint(allocator, "{d}", .{self.next_id});
        defer allocator.free(id);
        const json = try std.json.Stringify.valueAlloc(allocator, .{
            .version = protocol.version,
            .id = id,
            .kind = "create",
            .payload = .{ .repository = repository, .workspace_id = workspace_id },
        }, .{});
        defer allocator.free(json);
        const line = try std.fmt.allocPrint(allocator, "{s}\n", .{json});
        defer allocator.free(line);
        if (g_output_stream_write_all(g_subprocess_get_stdin_pipe(self.process), line.ptr, line.len, null, self.cancellation, null) == 0) return error.BackendWriteFailed;
    }

    fn read(self: *Client) void {
        self.read_pending = true;
        g_data_input_stream_read_line_async(self.input, 0, self.cancellation, &lineReceived, self);
    }

    fn sidebarGone(data: ?*anyopaque, _: *Object) callconv(.c) void {
        const self: *Client = @ptrCast(@alignCast(data.?));
        self.sidebar = null;
        self.stopRefresh();
        // Attempt orderly shutdown before cancelling the outstanding read.
        self.request("shutdown", null) catch {};
        const shutdown = allocator.create(Shutdown) catch {
            g_subprocess_force_exit(self.process);
            g_cancellable_cancel(self.cancellation);
            if (!self.read_pending) self.release();
            return;
        };
        // Retain the read end until exit so an in-flight response cannot hit
        // SIGPIPE before the backend reads our shutdown request.
        shutdown.* = .{ .process = g_object_ref(self.process), .input = g_object_ref(self.input) };
        // Keep the UI nonblocking, allow cleanup, and reap even a stuck peer.
        shutdown.timeout = g_timeout_add_seconds(2, &Shutdown.expired, shutdown);
        g_subprocess_wait_async(self.process, null, &Shutdown.exited, shutdown);
        g_cancellable_cancel(self.cancellation);
        if (!self.read_pending) self.release();
    }

    /// Terminal widgets may outlive their sidebar during GTK destruction.
    pub fn retain(self: *Client) void {
        self.references += 1;
    }

    pub fn release(self: *Client) void {
        self.references -= 1;
        if (self.references != 0) return;
        g_object_unref(self.input);
        g_object_unref(self.cancellation);
        g_object_unref(self.process);
        if (self.last_error) |previous| allocator.free(previous);
        if (self.notification_warning) |warning| allocator.free(warning);
        if (self.rendered_sidebar) |previous| allocator.free(previous);
        if (self.pending_workspace) |workspace| allocator.free(workspace);
        allocator.destroy(self);
    }

    pub fn reportTerminal(self: *Client, kind: []const u8, workspace: []const u8, generation: []const u8, pane: []const u8, directory: ?[]const u8) !void {
        if (self.sidebar == null or !self.ready) return error.BackendDisconnected;
        self.next_id += 1;
        const line = try terminalEventLine(allocator, self.next_id, kind, workspace, generation, pane, directory);
        defer allocator.free(line);
        if (g_output_stream_write_all(g_subprocess_get_stdin_pipe(self.process), line.ptr, line.len, null, self.cancellation, null) == 0) return error.BackendWriteFailed;
    }

    pub fn reportImage(self: *Client, workspace: []const u8, generation: []const u8, pane: []const u8, source: []const u8) !void {
        if (self.sidebar == null or !self.ready) return error.BackendDisconnected;
        self.next_id += 1;
        const id = try std.fmt.allocPrint(allocator, "{d}", .{self.next_id});
        defer allocator.free(id);
        const json = try std.json.Stringify.valueAlloc(allocator, .{
            .version = protocol.version,
            .id = id,
            .kind = "paste_image",
            .payload = .{ .workspace_id = workspace, .generation = generation, .pane_id = pane, .source_path = source },
        }, .{});
        defer allocator.free(json);
        const line = try std.fmt.allocPrint(allocator, "{s}\n", .{json});
        defer allocator.free(line);
        if (g_output_stream_write_all(g_subprocess_get_stdin_pipe(self.process), line.ptr, line.len, null, self.cancellation, null) == 0) return error.BackendWriteFailed;
    }

    fn lineReceived(_: ?*Object, result: ?*Object, data: ?*anyopaque) callconv(.c) void {
        const self: *Client = @ptrCast(@alignCast(data.?));
        self.read_pending = false;
        var length: usize = 0;
        const bytes = g_data_input_stream_read_line_finish(self.input, result.?, &length, null);
        defer if (bytes) |line| g_free(line);
        if (self.sidebar == null) {
            self.release();
            return;
        }
        const line = bytes orelse {
            self.ready = false;
            self.stopRefresh();
            gtk_widget_set_sensitive(self.rows, 0);
            gtk_label_set_text(self.status, "Workspace backend disconnected");
            gtk_widget_set_visible(self.recovery, 1);
            return;
        };
        self.receive(line[0..length]) catch {
            self.ready = false;
            self.stopRefresh();
            gtk_widget_set_sensitive(self.rows, 0);
            gtk_label_set_text(self.status, "Invalid workspace backend response");
            gtk_widget_set_visible(self.recovery, 1);
            return;
        };
        self.read();
    }

    fn receive(self: *Client, line: []const u8) !void {
        const frame = try std.json.parseFromSlice(struct {
            version: u32,
            id: ?[]const u8 = null,
            kind: []const u8,
            payload: ?struct { json: ?[]const u8 = null, message: ?[]const u8 = null, workspace_id: ?[]const u8 = null, title: ?[]const u8 = null, notify_error: ?[]const u8 = null, url: ?[]const u8 = null } = null,
        }, allocator, line, .{ .ignore_unknown_fields = true });
        defer frame.deinit();
        if (frame.value.version != protocol.version) return error.UnsupportedVersion;
        if (self.pending_poll) |pending| {
            if (frame.value.id) |id| {
                if ((std.fmt.parseInt(u64, id, 10) catch 0) == pending) self.pending_poll = null;
            }
        }
        if (std.mem.eql(u8, frame.value.kind, "ready")) {
            self.ready = true;
            if (frame.value.payload) |payload| {
                if (payload.notify_error) |message| {
                    const warning = try std.fmt.allocPrintSentinel(allocator, "Notifications unavailable: {s}", .{message}, 0);
                    if (self.notification_warning) |previous| allocator.free(previous);
                    self.notification_warning = warning;
                }
            }
            gtk_label_set_text(self.status, "Loading workspaces…");
            try self.request("poll", null);
            if (self.refresh_timer == 0) self.refresh_timer = g_timeout_add_seconds(5, &refresh, self);
        } else if (std.mem.eql(u8, frame.value.kind, "snapshot")) {
            var snapshot = try protocol.decodeSnapshot(allocator, line);
            defer snapshot.deinit();
            while (gtk_widget_get_first_child(self.progress)) |child| gtk_box_remove(self.progress, child);
            for (snapshot.value.operations) |operation| {
                const heading = try std.fmt.allocPrintSentinel(allocator, "{s} · {s} · {s}", .{ operation.kind, operation.workspaceID orelse "new workspace", operation.state }, 0);
                defer allocator.free(heading);
                gtk_box_append(self.progress, gtk_label_new(heading));
                const output = try allocator.dupeZ(u8, operation.output);
                defer allocator.free(output);
                gtk_box_append(self.progress, gtk_label_new(output));
                if (!std.mem.eql(u8, operation.state, "cancelling"))
                    _ = try self.addAction(self.progress, "Cancel operation", "cancel", operation.id);
            }
            const sidebar_state = try std.json.Stringify.valueAlloc(allocator, .{
                .workspaces = snapshot.value.workspaces,
                .layout = snapshot.value.layout,
                .selectedID = snapshot.value.selectedID,
                .badges = snapshot.value.badges,
            }, .{});
            defer allocator.free(sidebar_state);
            const changed = if (self.rendered_sidebar) |previous| !std.mem.eql(u8, previous, sidebar_state) else true;
            if (changed) {
                while (gtk_widget_get_first_child(self.rows)) |child| gtk_box_remove(self.rows, child);
                const layout = snapshot.value.layout;
                var ordered: std.ArrayList(protocol.Workspace) = .empty;
                defer ordered.deinit(allocator);
                // ponytail: linear matching for a small sidebar; index IDs if it
                // ever needs to render thousands of workspaces.
                for (layout.order) |id| {
                    for (snapshot.value.workspaces) |workspace| {
                        if (std.mem.eql(u8, workspace.id, id)) {
                            try ordered.append(allocator, workspace);
                            break;
                        }
                    }
                }
                for (snapshot.value.workspaces) |workspace| {
                    if (!containsID(layout.order, workspace.id)) try ordered.append(allocator, workspace);
                }
                for (ordered.items) |workspace| {
                    if (!containsID(layout.hidden, workspace.id)) try self.appendWorkspace(workspace, layout, containsID(snapshot.value.badges, workspace.id));
                }
                // Always retain the section control, even when every row is hidden.
                if (layout.hidden.len > 0) {
                    _ = try self.addAction(self.rows, if (layout.hidden_collapsed) "Expand hidden" else "Collapse hidden", if (layout.hidden_collapsed) "expand_hidden" else "collapse_hidden", "");
                    for (ordered.items) |workspace| {
                        const selected = if (snapshot.value.selectedID) |id| std.mem.eql(u8, id, workspace.id) else false;
                        if (containsID(layout.hidden, workspace.id) and (!layout.hidden_collapsed or selected))
                            try self.appendWorkspace(workspace, layout, containsID(snapshot.value.badges, workspace.id));
                    }
                }
                const retained = try allocator.dupe(u8, sidebar_state);
                if (self.rendered_sidebar) |previous| allocator.free(previous);
                self.rendered_sidebar = retained;
            }
            gtk_label_set_text(self.status, self.last_error orelse self.notification_warning orelse
                (if (snapshot.value.workspaces.len == 0) "No workspaces" else "Workspaces"));
            if (self.pending_workspace) |workspace| {
                const open_terminal = self.pending_open;
                self.pending_workspace = null;
                defer allocator.free(workspace);
                try self.selectWorkspace(workspace, open_terminal);
            }
        } else if (std.mem.eql(u8, frame.value.kind, "completed") or std.mem.eql(u8, frame.value.kind, "cancelled")) {
            try self.request("poll", null);
        } else if (std.mem.eql(u8, frame.value.kind, "error") or std.mem.eql(u8, frame.value.kind, "platform_error") or std.mem.eql(u8, frame.value.kind, "platform_info")) {
            const message = if (frame.value.payload) |payload| payload.message orelse "Workspace operation failed" else "Workspace operation failed";
            try self.showError(message);
        } else if (std.mem.eql(u8, frame.value.kind, "platform_open_zed")) {
            const payload = frame.value.payload orelse return error.MissingPayload;
            try self.launchZed(payload.url orelse return error.MissingPayload);
        } else if (std.mem.eql(u8, frame.value.kind, "platform_notify")) {
            const payload = frame.value.payload orelse return error.MissingPayload;
            if (self.effect_handler) |handler| {
                handler(self, self.effect_context, .{
                    .kind = "platform_notify",
                    .workspaceID = payload.workspace_id orelse return error.MissingPayload,
                    .generation = "",
                    .title = payload.title orelse return error.MissingPayload,
                    .message = payload.message orelse return error.MissingPayload,
                }) catch {
                    try self.showError("Desktop notification unavailable");
                };
            }
        } else if (std.mem.startsWith(u8, frame.value.kind, "terminal_")) {
            const payload = frame.value.payload orelse return error.MissingPayload;
            const parsed = try std.json.parseFromSlice(TerminalEffect, allocator, payload.json orelse return error.MissingPayload, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (std.mem.eql(u8, parsed.value.kind, "terminal_error")) {
                try self.showError(parsed.value.message orelse "SSH connection failed");
            }
            if (self.effect_handler) |handler| {
                handler(self, self.effect_context, parsed.value) catch |err| {
                    // A local terminal failure is not a malformed backend frame.
                    // Release the backend's transport while keeping recovery actions usable.
                    if (!std.mem.eql(u8, parsed.value.kind, "terminal_launch")) return err;
                    try self.reportTerminal("terminal_launch_failed", parsed.value.workspaceID, parsed.value.generation, parsed.value.paneID orelse return error.MissingPayload, null);
                    try self.showError("Terminal could not be opened; try Open again");
                    return;
                };
                if (std.mem.eql(u8, parsed.value.kind, "terminal_launch")) self.clearError();
            }
        }
    }
};
