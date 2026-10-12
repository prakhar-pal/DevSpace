const std = @import("std");
const protocol = @import("protocol");

test "frontend decodes backend snapshot workspace state" {
    const frame = "{\"version\":1,\"kind\":\"snapshot\",\"payload\":{\"json\":\"{\\\"revision\\\":3,\\\"workspaces\\\":[{\\\"id\\\":\\\"pod\\\",\\\"state\\\":\\\"Running\\\"}],\\\"layout\\\":{\\\"aliases\\\":{\\\"pod\\\":\\\"My pod\\\"}}}\"}}";
    var snapshot = try protocol.decodeSnapshot(std.testing.allocator, frame);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 3), snapshot.value.revision);
    try std.testing.expectEqualStrings("pod", snapshot.value.workspaces[0].id);
    try std.testing.expectEqualStrings("Running", snapshot.value.workspaces[0].state);
}

test "frontend rejects unsupported backend protocol" {
    try std.testing.expectError(error.UnsupportedVersion, protocol.decodeSnapshot(
        std.testing.allocator,
        "{\"version\":2,\"kind\":\"snapshot\",\"payload\":{\"json\":\"{}\"}}",
    ));
}
