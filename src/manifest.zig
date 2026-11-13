const std = @import("std");
const engine = @import("engine.zig");
const plan = @import("plan.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Manifest = struct { version: u32 = 1, files: []const engine.Entry };
pub const Tree = struct {
    source: []const u8,
    prefix: []const u8 = "",
    extensions: ?[]const []const u8 = null,
    mode: u32 = 0o644,
};
pub const Spec = struct { version: u32 = 1, files: []const engine.Entry = &.{}, trees: []const Tree = &.{} };

pub fn read(comptime T: type, a: Allocator, io: Io, path: []const u8) !T {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > 16 * 1024 * 1024) return error.InvalidDocument;
    const bytes = try a.alloc(u8, @intCast(stat.size));
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.InvalidDocument;
    const value = (try std.json.parseFromSlice(T, a, bytes, .{ .allocate = .alloc_always })).value;
    if (value.version != 1) return error.UnsupportedVersion;
    return value;
}

pub fn validate(files: []const engine.Entry) !void {
    for (files, 0..) |file, i| {
        try plan.validatePath(file.path);
        if (!std.fs.path.isAbsolute(file.source)) return error.SourceNotAbsolute;
        if (file.mode & ~@as(u32, 0o777) != 0) return error.InvalidMode;
        for (files[0..i]) |other| {
            if (std.mem.eql(u8, file.path, other.path)) return error.DuplicatePath;
            if (std.mem.startsWith(u8, file.path, other.path) and file.path.len > other.path.len and file.path[other.path.len] == '/') return error.OverlappingPaths;
            if (std.mem.startsWith(u8, other.path, file.path) and other.path.len > file.path.len and other.path[file.path.len] == '/') return error.OverlappingPaths;
        }
    }
}

fn lessThan(_: void, a: engine.Entry, b: engine.Entry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

const Generator = struct {
    a: Allocator,
    io: Io,
    files: std.ArrayList(engine.Entry) = .empty,
    ancestors: std.ArrayList([]const u8) = .empty,

    fn visit(self: *Generator, tree: Tree, source: []const u8, prefix: []const u8) !void {
        const canonical = try Io.Dir.realPathFileAbsoluteAlloc(self.io, source, self.a);
        for (self.ancestors.items) |ancestor| {
            if (std.mem.eql(u8, ancestor, canonical)) return error.SourceCycle;
        }
        try self.ancestors.append(self.a, canonical);
        defer _ = self.ancestors.pop();
        const dir = try Io.Dir.openDirAbsolute(self.io, canonical, .{ .iterate = true });
        defer dir.close(self.io);
        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            const child = try std.fs.path.join(self.a, &.{ canonical, entry.name });
            const path = if (prefix.len == 0) entry.name else try std.fmt.allocPrint(self.a, "{s}/{s}", .{ prefix, entry.name });
            const stat = try dir.statFile(self.io, entry.name, .{ .follow_symlinks = true });
            switch (stat.kind) {
                .directory => try self.visit(tree, child, path),
                .file => {
                    if (tree.extensions) |extensions| {
                        var included = false;
                        for (extensions) |extension| {
                            if (std.ascii.eqlIgnoreCase(std.fs.path.extension(entry.name), extension)) included = true;
                        }
                        if (!included) continue;
                    }
                    try self.files.append(self.a, .{ .path = path, .source = child, .mode = tree.mode });
                },
                else => return error.NotRegularFile,
            }
        }
    }
};

pub fn generate(a: Allocator, io: Io, spec: Spec) !Manifest {
    if (spec.version != 1) return error.UnsupportedVersion;
    var generator: Generator = .{ .a = a, .io = io };
    try generator.files.appendSlice(a, spec.files);
    for (spec.trees) |tree| {
        if (!std.fs.path.isAbsolute(tree.source)) return error.SourceNotAbsolute;
        if (tree.prefix.len != 0) try plan.validatePath(tree.prefix);
        if (tree.mode & ~@as(u32, 0o777) != 0) return error.InvalidMode;
        try generator.visit(tree, tree.source, tree.prefix);
    }
    std.mem.sort(engine.Entry, generator.files.items, {}, lessThan);
    try validate(generator.files.items);
    return .{ .files = generator.files.items };
}

test "generation follows source links, filters extensions and sorts explicit entries" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "fonts", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "fonts/Z.otf", .data = "z" });
    try tmp.dir.writeFile(io, .{ .sub_path = "fonts/readme", .data = "skip" });
    try tmp.dir.symLink(io, "Z.otf", "fonts/A.ttf", .{});
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try tmp.dir.realPathFileAlloc(io, "fonts", a);
    const result = try generate(a, io, .{ .trees = &.{.{ .source = source, .prefix = "nested", .extensions = &.{ ".otf", ".ttf" } }} });
    try std.testing.expectEqual(@as(usize, 2), result.files.len);
    try std.testing.expectEqualStrings("nested/A.ttf", result.files[0].path);
    try std.testing.expectEqualStrings("nested/Z.otf", result.files[1].path);
}

test "generation rejects cycles, broken links and duplicate destination paths" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.symLink(io, ".", "cycle", .{ .is_directory = true });
    try std.testing.expectError(error.SourceCycle, generate(a, io, .{ .trees = &.{.{ .source = source }} }));
    try tmp.dir.deleteFile(io, "cycle");
    try tmp.dir.symLink(io, "absent", "broken", .{});
    try std.testing.expectError(error.FileNotFound, generate(a, io, .{ .trees = &.{.{ .source = source }} }));
    try std.testing.expectError(error.DuplicatePath, validate(&.{ .{ .path = "same", .source = "/one" }, .{ .path = "same", .source = "/two" } }));
}
