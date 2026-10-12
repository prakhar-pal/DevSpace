const std = @import("std");

pub const version = 1;
pub const Workspace = struct {
    id: []const u8,
    state: []const u8,
    provider: []const u8 = "",
    source: []const u8 = "",
    lastUsed: []const u8 = "",
    @"error": ?[]const u8 = null,
};
pub const Snapshot = struct {
    revision: u64 = 0,
    workspaces: []Workspace = &.{},
    selectedID: ?[]const u8 = null,
    layout: Layout = .{},
    operations: []Operation = &.{},
    badges: []const []const u8 = &.{},
};
pub const Operation = struct {
    id: []const u8,
    kind: []const u8,
    workspaceID: ?[]const u8 = null,
    state: []const u8,
    output: []const u8 = "",
};
pub const Layout = struct {
    order: []const []const u8 = &.{},
    hidden: []const []const u8 = &.{},
    aliases: std.json.ArrayHashMap([]const u8) = .{},
    hidden_collapsed: bool = false,
};
const Frame = struct {
    version: u32,
    kind: []const u8,
    payload: ?struct { json: ?[]const u8 = null } = null,
};

pub fn decodeSnapshot(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Snapshot) {
    const frame = try std.json.parseFromSlice(Frame, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer frame.deinit();
    if (frame.value.version != version) return error.UnsupportedVersion;
    if (!std.mem.eql(u8, frame.value.kind, "snapshot")) return error.UnexpectedMessage;
    const payload = frame.value.payload orelse return error.MissingPayload;
    const json = payload.json orelse return error.MissingPayload;
    return std.json.parseFromSlice(Snapshot, allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}
