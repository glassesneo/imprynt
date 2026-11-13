const std = @import("std");
const fs = @import("filesystem.zig");
const plan = @import("plan.zig");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    path: []const u8,
    source: []const u8,
    mode: u32 = 0o644,
};

const State = struct {
    version: u32 = 1,
    generation: u64,
    root: []const u8,
    files: []const plan.File,
};

const Journal = struct {
    version: u32 = 1,
    previous_generation: u64,
    next: State,
    actions: []const plan.Action,
};

pub const Options = struct {
    // Internal fault injection: leave on-disk state exactly as after this
    // checkpoint, without running the ordinary error rollback path.
    interrupt_after: ?usize = null,
    interrupt_recovery_after: ?usize = null,
    fail_after: ?usize = null,
};

const Context = struct {
    allocator: Allocator,
    io: Io,
    root: Dir,
    control: Dir,
    root_path: []const u8,
    options: Options,
    checkpoints: usize = 0,
    recovery_checkpoints: usize = 0,

    fn checkpoint(self: *Context) !void {
        defer self.checkpoints += 1;
        if (self.options.interrupt_after == self.checkpoints) return error.InjectedCrash;
        if (self.options.fail_after == self.checkpoints) return error.InjectedFailure;
    }

    fn recoveryCheckpoint(self: *Context) !void {
        defer self.recovery_checkpoints += 1;
        if (self.options.interrupt_recovery_after == self.recovery_checkpoints) return error.InjectedCrash;
    }

    fn discardTransaction(self: *Context) !void {
        // Detach a resolved transaction atomically before recursive cleanup.
        // A crash while deleting its journal must never turn retained originals
        // from an unresolved transaction into anonymous preparation files.
        try fs.move(self.control, "transaction", self.control, "cleanup", self.io);
        try self.recoveryCheckpoint();
        try self.control.deleteTree(self.io, "cleanup");
        try fs.sync(self.control, self.io);
    }

    fn readJson(self: *Context, comptime T: type, dir: Dir, filename: []const u8) !T {
        const file = try dir.openFile(self.io, filename, .{ .follow_symlinks = false });
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.kind != .file or stat.size > 16 * 1024 * 1024) return error.InvalidState;
        const bytes = try self.allocator.alloc(u8, @intCast(stat.size));
        if (try file.readPositionalAll(self.io, bytes, 0) != bytes.len) return error.InvalidState;
        return (try std.json.parseFromSlice(T, self.allocator, bytes, .{ .allocate = .alloc_always })).value;
    }

    fn writeJson(self: *Context, dir: Dir, filename: []const u8, value: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        if (bytes.len > 16 * 1024 * 1024) return error.DocumentTooLarge;
        try fs.writeExclusive(dir, self.io, filename, bytes, 0o600);
    }

    fn state(self: *Context) !State {
        const result = self.readJson(State, self.control, "state.json") catch |err| switch (err) {
            error.FileNotFound => return .{ .generation = 0, .root = self.root_path, .files = &.{} },
            else => return err,
        };
        if (result.version != 1) return error.UnsupportedVersion;
        if (!std.mem.eql(u8, result.root, self.root_path)) return error.RootChanged;
        return result;
    }

    fn name(self: *Context, prefix: []const u8, index: usize) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}-{d}", .{ prefix, index });
    }

    fn validateAction(self: *Context, tx: Dir, action: plan.Action, index: usize, committed: bool) !void {
        try plan.validatePath(action.path);
        const old = try fs.observe(tx, self.io, try self.name("old", index));
        const staged = try fs.observe(tx, self.io, try self.name("new", index));
        const actual = try fs.observe(self.root, self.io, action.path);
        if (old != .missing and !fs.matches(old, action.before)) return error.RecoveryConflict;
        if (staged != .missing and !fs.matches(staged, action.after)) return error.RecoveryConflict;
        if (committed) {
            if (!fs.matches(actual, action.after) or staged != .missing) return error.RecoveryConflict;
            return;
        }
        if (action.before != null and old == .missing) {
            if (!fs.matches(actual, action.before)) return error.RecoveryConflict;
        } else if (staged != .missing) {
            // A staged file has not been installed. An occupied target is not
            // ours, even when its contents happen to match the desired file.
            if (actual != .missing and !(action.before != null and fs.matches(actual, action.before)))
                return error.RecoveryConflict;
        } else {
            if (actual != .missing and
                !fs.matches(actual, action.after) and
                !(action.before != null and fs.matches(actual, action.before)))
                return error.RecoveryConflict;
        }
    }

    fn recover(self: *Context) !void {
        try self.control.deleteTree(self.io, "cleanup");
        try fs.sync(self.control, self.io);
        const tx = self.control.openDir(self.io, "transaction", .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer tx.close(self.io);
        const journal = self.readJson(Journal, tx, "journal.json") catch |err| switch (err) {
            error.FileNotFound => {
                // Before journal publication, only private preparation files
                // exist; no managed destination may have been changed.
                try self.discardTransaction();
                return;
            },
            else => return err,
        };
        if (journal.version != 1 or journal.next.version != 1) return error.UnsupportedVersion;
        if (!std.mem.eql(u8, journal.next.root, self.root_path)) return error.RootChanged;
        const current = try self.state();
        const committed = current.generation == journal.next.generation;
        if (!committed and current.generation != journal.previous_generation) return error.InvalidJournal;
        // Validate the whole recovery before making even one rollback change.
        for (journal.actions, 0..) |action, i| {
            for (journal.actions[0..i]) |other|
                if (std.mem.eql(u8, action.path, other.path)) return error.InvalidJournal;
            try self.validateAction(tx, action, i, committed);
        }
        if (!committed) {
            var i = journal.actions.len;
            while (i > 0) {
                i -= 1;
                const action = journal.actions[i];
                try self.validateAction(tx, action, i, false);
                const p = try fs.parent(self.root, self.io, action.path);
                defer p.close(self.io);
                const old_name = try self.name("old", i);
                const has_old = try fs.observe(tx, self.io, old_name) != .missing;
                const actual = try fs.observe(self.root, self.io, action.path);
                if (has_old) {
                    if (actual != .missing and !fs.matches(actual, action.before)) {
                        try fs.remove(p.dir, self.io, p.basename);
                        try self.recoveryCheckpoint();
                    }
                    if (try fs.observe(self.root, self.io, action.path) == .missing) {
                        try fs.move(tx, old_name, p.dir, p.basename, self.io);
                        try self.recoveryCheckpoint();
                    }
                } else if (action.before == null and actual != .missing) {
                    try fs.remove(p.dir, self.io, p.basename);
                    try self.recoveryCheckpoint();
                }
            }
        }
        try self.discardTransaction();
    }

    fn apply(self: *Context, entries: []const Entry) !void {
        try self.recover();
        const previous = try self.state();
        // Validate paths before copying sources or creating a transaction.
        for (entries) |entry| {
            try plan.validatePath(entry.path);
            if (entry.mode & ~@as(u32, 0o777) != 0) return error.InvalidMode;
            // Initial slice requires existing parent directories.
            const p = try fs.parent(self.root, self.io, entry.path);
            p.close(self.io);
        }
        try self.control.createDir(self.io, "transaction", .fromMode(0o700));
        try fs.sync(self.control, self.io);
        const tx = try self.control.openDir(self.io, "transaction", .{ .follow_symlinks = false });
        defer tx.close(self.io);
        const desired = try self.allocator.alloc(plan.File, entries.len);
        for (entries, 0..) |entry, i| {
            desired[i] = .{
                .path = entry.path,
                .fingerprint = try fs.copySource(tx, self.io, try self.name("source", i), entry.source, entry.mode),
            };
        }
        var observations: std.ArrayList(plan.Observation) = .empty;
        for (previous.files) |file| try observations.append(self.allocator, .{
            .path = file.path,
            .value = try fs.observe(self.root, self.io, file.path),
        });
        for (desired) |file| {
            var known = false;
            for (previous.files) |old| {
                if (std.mem.eql(u8, old.path, file.path)) known = true;
            }
            if (!known) try observations.append(self.allocator, .{
                .path = file.path,
                .value = try fs.observe(self.root, self.io, file.path),
            });
        }
        const changes = try plan.build(self.allocator, previous.files, desired, observations.items);
        if (changes.conflicts.items.len != 0) return error.Conflict;
        const next: State = .{
            .generation = std.math.add(u64, previous.generation, 1) catch return error.GenerationOverflow,
            .root = self.root_path,
            .files = desired,
        };
        for (changes.actions.items, 0..) |action, i| {
            if (action.after != null) {
                for (desired, 0..) |file, source_index| {
                    if (std.mem.eql(u8, action.path, file.path)) {
                        try fs.move(tx, try self.name("source", source_index), tx, try self.name("new", i), self.io);
                        break;
                    }
                }
            }
        }
        try self.writeJson(tx, "state.json", next);
        // Publish the journal atomically: a partial journal never authorizes
        // destination changes.
        try self.writeJson(tx, "journal.next", Journal{
            .previous_generation = previous.generation,
            .next = next,
            .actions = changes.actions.items,
        });
        try fs.move(tx, "journal.next", tx, "journal.json", self.io);
        try self.checkpoint();
        for (changes.actions.items, 0..) |action, i| {
            if (!fs.matches(try fs.observe(self.root, self.io, action.path), action.before)) return error.Conflict;
            const p = try fs.parent(self.root, self.io, action.path);
            defer p.close(self.io);
            if (action.before != null) {
                try fs.move(p.dir, p.basename, tx, try self.name("old", i), self.io);
                // Recheck the moved object; a race must not install over an
                // unexpected replacement that was moved into the backup.
                if (!fs.matches(try fs.observe(tx, self.io, try self.name("old", i)), action.before))
                    return error.RecoveryConflict;
                try self.checkpoint();
            }
            if (action.after != null) {
                try fs.move(tx, try self.name("new", i), p.dir, p.basename, self.io);
                try self.checkpoint();
            }
        }
        for (desired) |file| {
            if (!fs.matches(try fs.observe(self.root, self.io, file.path), file.fingerprint)) return error.Conflict;
        }
        try tx.rename("state.json", self.control, "state.json", self.io);
        try fs.sync(self.control, self.io);
        try fs.sync(tx, self.io);
        try self.checkpoint();
        try self.recover();
    }
};

// Internal application API. Both directories must already exist, be disjoint,
// and share a filesystem. The control directory is private to this state.
// The public CLI/schema are intentionally not exposed by this first slice.
pub fn apply(
    allocator: Allocator,
    io: Io,
    root_path: []const u8,
    control_path: []const u8,
    entries: []const Entry,
    options: Options,
) !void {
    if (!std.fs.path.isAbsolute(root_path) or !std.fs.path.isAbsolute(control_path)) return error.PathNotAbsolute;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const canonical_root = try Dir.realPathFileAbsoluteAlloc(io, root_path, a);
    const canonical_control = try Dir.realPathFileAbsoluteAlloc(io, control_path, a);
    if (contains(canonical_root, canonical_control) or contains(canonical_control, canonical_root))
        return error.OverlappingDirectories;
    const root = try Dir.openDirAbsolute(io, canonical_root, .{ .follow_symlinks = false });
    defer root.close(io);
    const control = try Dir.openDirAbsolute(io, canonical_control, .{ .follow_symlinks = false });
    defer control.close(io);
    const lock = control.openFile(io, "lock", .{
        .mode = .read_write,
        .follow_symlinks = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.FileNotFound => try control.createFile(io, "lock", .{
            .exclusive = true,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = .fromMode(0o600),
        }),
        else => return err,
    };
    defer lock.close(io);
    if ((try lock.stat(io)).kind != .file) return error.InvalidState;
    var context: Context = .{
        .allocator = a,
        .io = io,
        .root = root,
        .control = control,
        .root_path = canonical_root,
        .options = options,
    };
    context.apply(entries) catch |err| {
        if (err != error.InjectedCrash) context.recover() catch return error.RecoveryRequired;
        return err;
    };
}

fn contains(root: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, root, path) or std.mem.eql(u8, root, "/") or
        (path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/');
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: [:0]const u8,
    control: [:0]const u8,
    source: [:0]const u8,

    fn init() !Fixture {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(io, "root", .default_dir);
        try tmp.dir.createDir(io, "control", .fromMode(0o700));
        try fs.writeExclusive(tmp.dir, io, "source", "version one", 0o644);
        const a = std.testing.allocator;
        const root = try tmp.dir.realPathFileAlloc(io, "root", a);
        errdefer a.free(root);
        const control = try tmp.dir.realPathFileAlloc(io, "control", a);
        errdefer a.free(control);
        const source = try tmp.dir.realPathFileAlloc(io, "source", a);
        return .{ .tmp = tmp, .root = root, .control = control, .source = source };
    }

    fn deinit(self: *Fixture) void {
        const a = std.testing.allocator;
        a.free(self.root);
        a.free(self.control);
        a.free(self.source);
        self.tmp.cleanup();
    }

    fn run(self: *Fixture, entries: []const Entry, options: Options) !void {
        return apply(std.testing.allocator, std.testing.io, self.root, self.control, entries, options);
    }

    fn entry(self: Fixture) Entry {
        return .{ .path = "A.ttf", .source = self.source };
    }

    fn expectFile(self: Fixture, path: []const u8, expected: []const u8) !void {
        var buffer: [128]u8 = undefined;
        try std.testing.expectEqualStrings(expected, try self.tmp.dir.readFile(std.testing.io, path, &buffer));
    }
};

test "real-file install, update, idempotence and removal preserve manual siblings" {
    var f = try Fixture.init();
    defer f.deinit();
    const io = std.testing.io;
    try f.tmp.dir.writeFile(io, .{ .sub_path = "root/manual.ttf", .data = "manual" });
    try f.run(&.{f.entry()}, .{});
    try f.expectFile("root/A.ttf", "version one");
    try f.run(&.{f.entry()}, .{});
    try f.tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "version two" });
    try f.run(&.{f.entry()}, .{});
    try f.expectFile("root/A.ttf", "version two");
    try f.run(&.{}, .{});
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(io, "root/A.ttf", .{}));
    try f.expectFile("root/manual.ttf", "manual");
}

test "preflight rejects occupied and modified files without partial application" {
    var f = try Fixture.init();
    defer f.deinit();
    const io = std.testing.io;
    try f.tmp.dir.writeFile(io, .{ .sub_path = "root/A.ttf", .data = "manual" });
    try std.testing.expectError(error.Conflict, f.run(&.{ f.entry(), .{ .path = "B.ttf", .source = f.source } }, .{}));
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(io, "root/B.ttf", .{}));
    try f.expectFile("root/A.ttf", "manual");
    try f.tmp.dir.deleteFile(io, "root/A.ttf");
    try f.run(&.{f.entry()}, .{});
    try f.tmp.dir.writeFile(io, .{ .sub_path = "root/A.ttf", .data = "replaced" });
    try std.testing.expectError(error.Conflict, f.run(&.{}, .{}));
    try f.expectFile("root/A.ttf", "replaced");
}

test "every installation checkpoint recovers before applying the next manifest" {
    for (0..3) |checkpoint| {
        var f = try Fixture.init();
        defer f.deinit();
        try std.testing.expectError(error.InjectedCrash, f.run(&.{f.entry()}, .{ .interrupt_after = checkpoint }));
        try f.run(&.{}, .{});
        try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(std.testing.io, "root/A.ttf", .{}));
    }
}

test "every update checkpoint rolls back before commit and keeps new state after commit" {
    const io = std.testing.io;
    for (0..4) |checkpoint| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.run(&.{f.entry()}, .{});
        try f.tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "version two" });
        try std.testing.expectError(error.InjectedCrash, f.run(&.{f.entry()}, .{ .interrupt_after = checkpoint }));
        // Missing source proves recovery uses retained files, not old sources.
        try f.tmp.dir.deleteFile(io, "source");
        try std.testing.expectError(error.FileNotFound, f.run(&.{f.entry()}, .{}));
        try f.expectFile("root/A.ttf", if (checkpoint == 3) "version two" else "version one");
        try f.run(&.{}, .{});
    }
}

test "every deletion checkpoint recovers and does not require a source" {
    const io = std.testing.io;
    for (0..3) |checkpoint| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.run(&.{f.entry()}, .{});
        try f.tmp.dir.deleteFile(io, "source");
        try std.testing.expectError(error.InjectedCrash, f.run(&.{}, .{ .interrupt_after = checkpoint }));
        try f.run(&.{}, .{});
        try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(io, "root/A.ttf", .{}));
    }
}

test "recovery preserves an external replacement and journal" {
    const io = std.testing.io;
    var f = try Fixture.init();
    defer f.deinit();
    try f.run(&.{f.entry()}, .{});
    try f.tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "version two" });
    try std.testing.expectError(error.InjectedCrash, f.run(&.{f.entry()}, .{ .interrupt_after = 2 }));
    try f.tmp.dir.writeFile(io, .{ .sub_path = "root/A.ttf", .data = "manual replacement" });
    try std.testing.expectError(error.RecoveryRequired, f.run(&.{}, .{}));
    try f.expectFile("root/A.ttf", "manual replacement");
    _ = try f.tmp.dir.statFile(io, "control/transaction/journal.json", .{});
    try f.expectFile("control/transaction/old-0", "version one");
}

test "a stable root symlink is allowed, retargeting it is rejected" {
    const io = std.testing.io;
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.symLink(io, "root", "alias", .{ .is_directory = true });
    const alias = try std.fs.path.join(std.testing.allocator, &.{ f.root, "../alias" });
    defer std.testing.allocator.free(alias);
    try apply(std.testing.allocator, io, alias, f.control, &.{f.entry()}, .{});
    try f.tmp.dir.deleteFile(io, "alias");
    try f.tmp.dir.createDir(io, "other", .default_dir);
    try f.tmp.dir.symLink(io, "other", "alias", .{ .is_directory = true });
    try std.testing.expectError(error.RootChanged, apply(std.testing.allocator, io, alias, f.control, &.{}, .{}));
    try f.expectFile("root/A.ttf", "version one");
}

test "rollback itself can be interrupted and safely restarted" {
    const io = std.testing.io;
    for (0..3) |checkpoint| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.run(&.{f.entry()}, .{});
        try f.tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "version two" });
        try std.testing.expectError(error.InjectedCrash, f.run(&.{f.entry()}, .{ .interrupt_after = 2 }));
        try std.testing.expectError(error.InjectedCrash, f.run(&.{}, .{ .interrupt_recovery_after = checkpoint }));
        try f.tmp.dir.deleteFile(io, "source");
        try std.testing.expectError(error.FileNotFound, f.run(&.{f.entry()}, .{}));
        try f.expectFile("root/A.ttf", "version one");
        try f.run(&.{}, .{});
    }
}

test "ordinary application failures attempt rollback immediately" {
    const io = std.testing.io;
    for (0..3) |checkpoint| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.run(&.{f.entry()}, .{});
        try f.tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "version two" });
        try std.testing.expectError(error.InjectedFailure, f.run(&.{f.entry()}, .{ .fail_after = checkpoint }));
        try f.expectFile("root/A.ttf", "version one");
        try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(io, "control/transaction", .{}));
    }
}

test "source symlinks materialize regular files with explicit modes" {
    const io = std.testing.io;
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.symLink(io, "source", "source-link", .{});
    const source_link = try std.fs.path.join(std.testing.allocator, &.{ f.control, "../source-link" });
    defer std.testing.allocator.free(source_link);
    try f.run(&.{.{ .path = "A.ttf", .source = source_link, .mode = 0o640 }}, .{});
    const stat = try f.tmp.dir.statFile(io, "root/A.ttf", .{ .follow_symlinks = false });
    try std.testing.expectEqual(Io.File.Kind.file, stat.kind);
    try std.testing.expectEqual(@as(u32, 0o640), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
}

test "nested existing directories work but symlink parents do not" {
    const io = std.testing.io;
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.createDir(io, "root/fonts", .default_dir);
    try f.run(&.{.{ .path = "fonts/A.ttf", .source = f.source }}, .{});
    try f.expectFile("root/fonts/A.ttf", "version one");
    try f.tmp.dir.symLink(io, "fonts", "root/alias", .{ .is_directory = true });
    if (f.run(&.{.{ .path = "alias/B.ttf", .source = f.source }}, .{})) {
        return error.FollowedSymlink;
    } else |err| {
        try std.testing.expect(err == error.NotDir or err == error.SymLinkLoop);
    }
    try f.expectFile("root/fonts/A.ttf", "version one");
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(io, "root/fonts/B.ttf", .{}));
}

test "a second application cannot acquire the same state lock" {
    const io = std.testing.io;
    var f = try Fixture.init();
    defer f.deinit();
    const lock = try f.tmp.dir.createFile(io, "control/lock", .{ .lock = .exclusive });
    defer lock.close(io);
    try std.testing.expectError(error.WouldBlock, f.run(&.{f.entry()}, .{}));
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(io, "root/A.ttf", .{}));
}

test "external file equal to desired content before installation is not adopted during recovery" {
    const io = std.testing.io;
    var f = try Fixture.init();
    defer f.deinit();
    try std.testing.expectError(error.InjectedCrash, f.run(&.{f.entry()}, .{ .interrupt_after = 0 }));
    try f.tmp.dir.writeFile(io, .{ .sub_path = "root/A.ttf", .data = "version one" });
    try std.testing.expectError(error.RecoveryRequired, f.run(&.{}, .{}));
    try f.expectFile("root/A.ttf", "version one");
    _ = try f.tmp.dir.statFile(io, "control/transaction/journal.json", .{});
}

test "recovery prevalidates every file before starting multi-file rollback" {
    const io = std.testing.io;
    var f = try Fixture.init();
    defer f.deinit();
    const entries = [_]Entry{ f.entry(), .{ .path = "B.ttf", .source = f.source } };
    try f.run(&entries, .{});
    try f.tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "version two" });
    // Both files have been updated, but the state has not been committed.
    try std.testing.expectError(error.InjectedCrash, f.run(&entries, .{ .interrupt_after = 4 }));
    try f.tmp.dir.writeFile(io, .{ .sub_path = "root/A.ttf", .data = "manual" });
    try std.testing.expectError(error.RecoveryRequired, f.run(&.{}, .{}));
    try f.expectFile("root/A.ttf", "manual");
    try f.expectFile("root/B.ttf", "version two");
    try f.expectFile("control/transaction/old-0", "version one");
    try f.expectFile("control/transaction/old-1", "version one");
}

test "post-commit cleanup can be interrupted without rolling back committed files" {
    const io = std.testing.io;
    var f = try Fixture.init();
    defer f.deinit();
    try std.testing.expectError(error.InjectedCrash, f.run(&.{f.entry()}, .{ .interrupt_recovery_after = 0 }));
    try f.expectFile("root/A.ttf", "version one");
    _ = try f.tmp.dir.statFile(io, "control/cleanup", .{});
    try f.run(&.{f.entry()}, .{});
    try f.expectFile("root/A.ttf", "version one");
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.statFile(io, "control/cleanup", .{}));
}

test "corrupt journals are retained with backups rather than treated as preparation" {
    const io = std.testing.io;
    var f = try Fixture.init();
    defer f.deinit();
    try f.run(&.{f.entry()}, .{});
    try f.tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "version two" });
    try std.testing.expectError(error.InjectedCrash, f.run(&.{f.entry()}, .{ .interrupt_after = 1 }));
    try f.tmp.dir.writeFile(io, .{ .sub_path = "control/transaction/journal.json", .data = "{" });
    try std.testing.expectError(error.RecoveryRequired, f.run(&.{}, .{}));
    try f.expectFile("control/transaction/old-0", "version one");
    try f.expectFile("control/transaction/journal.json", "{");
}
