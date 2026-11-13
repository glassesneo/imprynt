const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Digest = [32]u8;

pub const Fingerprint = struct {
    digest: Digest,
    mode: u32,

    pub fn eql(a: Fingerprint, b: Fingerprint) bool {
        return a.mode == b.mode and std.mem.eql(u8, &a.digest, &b.digest);
    }
};

pub const File = struct {
    path: []const u8,
    fingerprint: Fingerprint,
};

pub const Observed = union(enum) {
    missing,
    regular: Fingerprint,
    other,
};

pub const Observation = struct {
    path: []const u8,
    value: Observed,
};

pub const Action = struct {
    path: []const u8,
    before: ?Fingerprint,
    after: ?Fingerprint,
};

pub const Conflict = struct {
    path: []const u8,
    reason: enum { occupied, changed, missing },
};

pub const Plan = struct {
    actions: std.ArrayList(Action) = .empty,
    conflicts: std.ArrayList(Conflict) = .empty,

    pub fn deinit(self: *Plan, allocator: Allocator) void {
        self.actions.deinit(allocator);
        self.conflicts.deinit(allocator);
    }
};

pub fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, 0) != null)
        return error.InvalidPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
            return error.InvalidPath;
    }
}

fn validateFiles(files: []const File) !void {
    for (files, 0..) |file, i| {
        try validatePath(file.path);
        if (file.fingerprint.mode & ~@as(u32, 0o777) != 0) return error.InvalidMode;
        for (files[0..i]) |other| {
            if (std.mem.eql(u8, file.path, other.path)) return error.DuplicatePath;
            if (isAncestor(file.path, other.path) or isAncestor(other.path, file.path))
                return error.OverlappingPaths;
        }
    }
}

fn isAncestor(a: []const u8, b: []const u8) bool {
    return b.len > a.len and std.mem.startsWith(u8, b, a) and b[a.len] == '/';
}

fn find(files: []const File, path: []const u8) ?Fingerprint {
    for (files) |file| if (std.mem.eql(u8, file.path, path)) return file.fingerprint;
    return null;
}

fn observe(observations: []const Observation, path: []const u8) !Observed {
    var found: ?Observed = null;
    for (observations) |item| {
        if (std.mem.eql(u8, item.path, path)) {
            if (found != null) return error.DuplicateObservation;
            found = item.value;
        }
    }
    return found orelse error.MissingObservation;
}

pub fn build(
    allocator: Allocator,
    previous: []const File,
    desired: []const File,
    observations: []const Observation,
) !Plan {
    try validateFiles(previous);
    try validateFiles(desired);
    // Changing a file into a parent directory (or the reverse) needs a distinct
    // migration protocol; reject it before touching the filesystem.
    for (previous) |old| for (desired) |new| {
        if (isAncestor(old.path, new.path) or isAncestor(new.path, old.path))
            return error.OverlappingPaths;
    };
    var result: Plan = .{};
    errdefer result.deinit(allocator);
    for (previous) |old| {
        const actual = try observe(observations, old.path);
        const unchanged = switch (actual) {
            .regular => |actual_fp| actual_fp.eql(old.fingerprint),
            else => false,
        };
        if (!unchanged) {
            try result.conflicts.append(allocator, .{
                .path = old.path,
                .reason = if (actual == .missing) .missing else .changed,
            });
            continue;
        }
        const next = find(desired, old.path);
        if (next == null or !next.?.eql(old.fingerprint))
            try result.actions.append(allocator, .{
                .path = old.path,
                .before = old.fingerprint,
                .after = next,
            });
    }
    for (desired) |new| {
        if (find(previous, new.path) != null) continue;
        if (try observe(observations, new.path) != .missing) {
            try result.conflicts.append(allocator, .{ .path = new.path, .reason = .occupied });
        } else {
            try result.actions.append(allocator, .{
                .path = new.path,
                .before = null,
                .after = new.fingerprint,
            });
        }
    }
    // A conflicting plan must never be executable, even by an inattentive caller.
    if (result.conflicts.items.len != 0) result.actions.clearRetainingCapacity();
    return result;
}

fn fp(bytes: []const u8) Fingerprint {
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .digest = digest, .mode = 0o644 };
}

test "plan install, update, removal, and no-op against the previous state" {
    const a = std.testing.allocator;
    const old = fp("old");
    const new = fp("new");
    var plan = try build(a, &.{
        .{ .path = "updated", .fingerprint = old },
        .{ .path = "removed", .fingerprint = old },
        .{ .path = "unchanged", .fingerprint = old },
    }, &.{
        .{ .path = "updated", .fingerprint = new },
        .{ .path = "unchanged", .fingerprint = old },
        .{ .path = "installed", .fingerprint = new },
    }, &.{
        .{ .path = "updated", .value = .{ .regular = old } },
        .{ .path = "removed", .value = .{ .regular = old } },
        .{ .path = "unchanged", .value = .{ .regular = old } },
        .{ .path = "installed", .value = .missing },
    });
    defer plan.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), plan.conflicts.items.len);
    try std.testing.expectEqual(@as(usize, 3), plan.actions.items.len);
    try std.testing.expect(plan.actions.items[0].before.?.eql(old));
    try std.testing.expect(plan.actions.items[0].after.?.eql(new));
    try std.testing.expect(plan.actions.items[1].after == null);
    try std.testing.expect(plan.actions.items[2].before == null);
}

test "collect all conflicts and discard otherwise valid actions" {
    const a = std.testing.allocator;
    const old = fp("old");
    var plan = try build(a, &.{
        .{ .path = "modified", .fingerprint = old },
        .{ .path = "deleted", .fingerprint = old },
    }, &.{
        .{ .path = "occupied", .fingerprint = old },
        .{ .path = "free", .fingerprint = old },
    }, &.{
        .{ .path = "modified", .value = .{ .regular = fp("manual") } },
        .{ .path = "deleted", .value = .missing },
        .{ .path = "occupied", .value = .{ .regular = old } },
        .{ .path = "free", .value = .missing },
    });
    defer plan.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), plan.conflicts.items.len);
    try std.testing.expectEqual(@as(usize, 0), plan.actions.items.len);
}

test "mode changes and non-regular replacements conflict even without a declaration change" {
    const a = std.testing.allocator;
    const old = fp("old");
    var changed = old;
    changed.mode = 0o600;
    for ([_]Observed{ .{ .regular = changed }, .other }) |actual| {
        var plan = try build(a, &.{.{ .path = "A", .fingerprint = old }}, &.{.{ .path = "A", .fingerprint = old }}, &.{.{ .path = "A", .value = actual }});
        defer plan.deinit(a);
        try std.testing.expectEqual(@as(usize, 1), plan.conflicts.items.len);
    }
}

test "reject unsafe, duplicate, overlapping paths and incomplete observations" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "", "/A", "../A", "A/../B", "A//B", "A/", "./A", "A\x00B" }) |path|
        try std.testing.expectError(error.InvalidPath, validatePath(path));
    try validatePath("nested/A.ttf");
    const files = [_]File{ .{ .path = "A", .fingerprint = fp("A") }, .{ .path = "A/B", .fingerprint = fp("B") } };
    try std.testing.expectError(error.OverlappingPaths, build(a, &.{}, &files, &.{}));
    try std.testing.expectError(error.DuplicatePath, build(a, &.{}, &.{ files[0], files[0] }, &.{}));
    try std.testing.expectError(error.MissingObservation, build(a, &files[0..1].*, &.{}, &.{}));
}
