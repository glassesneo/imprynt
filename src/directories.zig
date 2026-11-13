const std = @import("std");
const fs = @import("filesystem.zig");
const plan = @import("plan.zig");
const Io = std.Io;

pub const Directory = struct { path: []const u8, inode: Io.File.INode };
pub const Observed = union(enum) { missing, directory: Io.File.INode, other };
pub const Prepared = struct { next: []const Directory, created: []const Directory };

pub fn observe(root: Io.Dir, io: Io, path: []const u8) !Observed {
    const p = fs.parent(root, io, path) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        error.NotDir, error.SymLinkLoop => return .other,
        else => return err,
    };
    defer p.close(io);
    const stat = p.dir.statFile(io, p.basename, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    return if (stat.kind == .directory) .{ .directory = stat.inode } else .other;
}

pub fn matches(actual: Observed, expected: Directory) bool {
    return actual == .directory and actual.directory == expected.inode;
}

pub fn name(a: std.mem.Allocator, index: usize) ![]const u8 {
    return std.fmt.allocPrint(a, "directory-{d}", .{index});
}

pub fn prepare(a: std.mem.Allocator, io: Io, root: Io.Dir, tx: Io.Dir, previous: []const Directory, files: anytype) !Prepared {
    var next: std.ArrayList(Directory) = .empty;
    var created: std.ArrayList(Directory) = .empty;
    for (previous) |dir| {
        try plan.validatePath(dir.path);
        if (matches(try observe(root, io, dir.path), dir)) try next.append(a, dir);
    }
    for (files) |file| {
        for (file.path, 0..) |c, end| {
            if (c != '/') continue;
            const path = file.path[0..end];
            var known = false;
            for (created.items) |dir| {
                if (std.mem.eql(u8, dir.path, path)) known = true;
            }
            if (known) continue;
            switch (try observe(root, io, path)) {
                .directory => {},
                .other => return error.Conflict,
                .missing => {
                    const staged_name = try name(a, created.items.len);
                    try tx.createDir(io, staged_name, .fromMode(0o755));
                    const stat = try tx.statFile(io, staged_name, .{ .follow_symlinks = false });
                    const dir: Directory = .{ .path = path, .inode = stat.inode };
                    try created.append(a, dir);
                    try next.append(a, dir);
                },
            }
        }
    }
    try fs.sync(tx, io);
    return .{ .next = next.items, .created = created.items };
}

pub fn validate(a: std.mem.Allocator, io: Io, root: Io.Dir, tx: Io.Dir, created: []const Directory, committed: bool) !void {
    for (created, 0..) |dir, i| {
        try plan.validatePath(dir.path);
        const staged = try observe(tx, io, try name(a, i));
        const actual = try observe(root, io, dir.path);
        if (staged != .missing and !matches(staged, dir)) return error.RecoveryConflict;
        if (committed) {
            if (staged != .missing or !matches(actual, dir)) return error.RecoveryConflict;
        } else if (staged != .missing) {
            if (actual != .missing) return error.RecoveryConflict;
        } else if (actual != .missing and !matches(actual, dir)) return error.RecoveryConflict;
    }
}

pub fn needed(path: []const u8, files: anytype) bool {
    for (files) |file| {
        if (file.path.len > path.len and std.mem.startsWith(u8, file.path, path) and file.path[path.len] == '/') return true;
    }
    return false;
}

// Only rmdir: never recursively remove a destination directory. An unrelated
// manual child keeps it alive. Replaced directories are not adopted.
pub fn removeEmpty(root: Io.Dir, io: Io, dir: Directory) !void {
    if (!matches(try observe(root, io, dir.path), dir)) return;
    const p = try fs.parent(root, io, dir.path);
    defer p.close(io);
    p.dir.deleteDir(io, p.basename) catch |err| switch (err) {
        error.DirNotEmpty, error.FileNotFound => return,
        else => return err,
    };
    try fs.sync(p.dir, io);
}
