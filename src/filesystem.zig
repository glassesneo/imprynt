const std = @import("std");
const plan = @import("plan.zig");
const Io = std.Io;
const Dir = Io.Dir;

pub const Parent = struct {
    dir: Dir,
    basename: []const u8,

    pub fn close(self: Parent, io: Io) void {
        self.dir.close(io);
    }
};

pub fn parent(root: Dir, io: Io, path: []const u8) !Parent {
    try plan.validatePath(path);
    var dir = try root.openDir(io, ".", .{ .follow_symlinks = false });
    errdefer dir.close(io);
    var parts = std.mem.splitScalar(u8, path, '/');
    var name = parts.next().?;
    while (parts.next()) |next| {
        const child = try dir.openDir(io, name, .{ .follow_symlinks = false });
        dir.close(io);
        dir = child;
        name = next;
    }
    return .{ .dir = dir, .basename = name };
}

pub fn fingerprint(file: Io.File, io: Io) !plan.Fingerprint {
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.NotRegularFile;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositional(io, &.{&buffer}, offset);
        if (n == 0) break;
        hash.update(buffer[0..n]);
        offset += n;
    }
    return .{ .digest = hash.finalResult(), .mode = @intCast(stat.permissions.toMode() & 0o7777) };
}

pub fn observe(root: Dir, io: Io, path: []const u8) !plan.Observed {
    const p = parent(root, io, path) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        error.SymLinkLoop, error.NotDir => return .other,
        else => return err,
    };
    defer p.close(io);
    const stat = p.dir.statFile(io, p.basename, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    if (stat.kind != .file) return .other;
    const file = try p.dir.openFile(io, p.basename, .{ .follow_symlinks = false });
    defer file.close(io);
    return .{ .regular = try fingerprint(file, io) };
}

pub fn matches(actual: plan.Observed, expected: ?plan.Fingerprint) bool {
    return if (expected) |fp|
        actual == .regular and actual.regular.eql(fp)
    else
        actual == .missing;
}

pub fn sync(dir: Dir, io: Io) !void {
    const file: Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try file.sync(io);
}

pub fn move(from: Dir, old: []const u8, to: Dir, new: []const u8, io: Io) !void {
    try from.renamePreserve(old, to, new, io);
    try sync(from, io);
    try sync(to, io);
}

pub fn remove(dir: Dir, io: Io, path: []const u8) !void {
    try dir.deleteFile(io, path);
    try sync(dir, io);
}

pub fn writeExclusive(dir: Dir, io: Io, name: []const u8, bytes: []const u8, mode: u32) !void {
    const file = try dir.createFile(io, name, .{ .exclusive = true, .permissions = .fromMode(@intCast(mode)) });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.setPermissions(io, .fromMode(@intCast(mode)));
    try file.sync(io);
    try sync(dir, io);
}

pub fn copySource(dir: Dir, io: Io, name: []const u8, source: []const u8, mode: u32) !plan.Fingerprint {
    if (!std.fs.path.isAbsolute(source)) return error.SourceNotAbsolute;
    const input = try Dir.openFileAbsolute(io, source, .{});
    defer input.close(io);
    if ((try input.stat(io)).kind != .file) return error.NotRegularFile;
    const output = try dir.createFile(io, name, .{ .read = true, .exclusive = true, .permissions = .fromMode(@intCast(mode)) });
    defer output.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = input.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        try output.writeStreamingAll(io, buffer[0..n]);
    }
    try output.setPermissions(io, .fromMode(@intCast(mode)));
    try output.sync(io);
    try sync(dir, io);
    return fingerprint(output, io);
}

test "parent traversal rejects symlinks instead of following them" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "real", .default_dir);
    try tmp.dir.symLink(io, "real", "alias", .{ .is_directory = true });
    if (parent(tmp.dir, io, "alias/A")) |p| {
        p.close(io);
        return error.FollowedSymlink;
    } else |err| {
        try std.testing.expect(err == error.NotDir or err == error.SymLinkLoop);
    }
}

test "observe does not follow final symlinks, including broken links" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink(io, "absent", "A", .{});
    try std.testing.expect(try observe(tmp.dir, io, "A") == .other);
}

test "non-replacing move preserves an occupied destination" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeExclusive(tmp.dir, io, "A", "managed", 0o644);
    try writeExclusive(tmp.dir, io, "B", "manual", 0o644);
    try std.testing.expectError(error.PathAlreadyExists, move(tmp.dir, "A", tmp.dir, "B", io));
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("manual", try tmp.dir.readFile(io, "B", &buf));
}
