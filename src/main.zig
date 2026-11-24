const std = @import("std");
const imprynt = @import("imprynt");
const manifest = imprynt.manifest;

const Command = enum { apply, recover, retire, generate };
const Arguments = struct {
    command: Command,
    root: ?[]const u8 = null,
    state: ?[]const u8 = null,
    manifest: ?[]const u8 = null,
    spec: ?[]const u8 = null,
    output: ?[]const u8 = null,
};

const usage =
    \\Usage:
    \\  imprynt apply --root ABSOLUTE --state ABSOLUTE --manifest FILE
    \\  imprynt recover --root ABSOLUTE --state ABSOLUTE
    \\  imprynt retire --state ABSOLUTE
    \\  imprynt generate --spec FILE --output FILE
    \\
    \\Root and state directories must already exist, be disjoint, and share a
    \\filesystem. State is private to imprynt; do not edit or delete its contents.
    \\
;

fn parse(args: []const []const u8) !Arguments {
    if (args.len == 0) return error.InvalidArguments;
    var result: Arguments = .{ .command = std.meta.stringToEnum(Command, args[0]) orelse return error.InvalidArguments };
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 == args.len) return error.InvalidArguments;
        const field: *?[]const u8 = if (std.mem.eql(u8, args[i], "--root"))
            &result.root
        else if (std.mem.eql(u8, args[i], "--state"))
            &result.state
        else if (std.mem.eql(u8, args[i], "--manifest"))
            &result.manifest
        else if (std.mem.eql(u8, args[i], "--spec"))
            &result.spec
        else if (std.mem.eql(u8, args[i], "--output"))
            &result.output
        else
            return error.InvalidArguments;
        if (field.* != null) return error.InvalidArguments;
        field.* = args[i + 1];
    }
    switch (result.command) {
        .generate => {
            if (result.spec == null or result.output == null or result.root != null or result.state != null or result.manifest != null) return error.InvalidArguments;
        },
        .retire => {
            if (result.state == null or result.root != null or result.manifest != null or result.spec != null or result.output != null) return error.InvalidArguments;
        },
        .apply, .recover => {
            if (result.root == null or result.state == null or result.spec != null or result.output != null) return error.InvalidArguments;
            if ((result.command == .apply) != (result.manifest != null)) return error.InvalidArguments;
        },
    }
    return result;
}

fn reportConflict(io: std.Io, conflict: imprynt.plan.Conflict) void {
    var buffer: [4096]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "imprynt: conflict: {s} ({s})\n", .{ conflict.path, @tagName(conflict.reason) }) catch return;
    std.Io.File.stderr().writeStreamingAll(io, message) catch {};
}

fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, usage);
        return;
    }
    const options = try parse(args[1..]);
    switch (options.command) {
        .apply, .recover => {
            // Recovery is independent of the new manifest, including a missing
            // or malformed one. Applying reacquires the lock and checks again.
            try imprynt.engine.recover(a, init.io, options.root.?, options.state.?);
            if (options.command == .apply) {
                const desired = try manifest.read(manifest.Manifest, a, init.io, options.manifest.?);
                try manifest.validate(desired.files);
                try imprynt.engine.apply(a, init.io, options.root.?, options.state.?, desired.files, .{ .on_conflict = reportConflict });
            }
        },
        .retire => try imprynt.engine.retire(a, init.io, options.state.?),
        .generate => {
            const spec = try manifest.read(manifest.Spec, a, init.io, options.spec.?);
            const generated = try manifest.generate(a, init.io, spec);
            const bytes = try std.json.Stringify.valueAlloc(a, generated, .{});
            if (bytes.len > 16 * 1024 * 1024) return error.DocumentTooLarge;
            const file = try std.Io.Dir.cwd().createFile(init.io, options.output.?, .{ .exclusive = true });
            defer file.close(init.io);
            try file.writeStreamingAll(init.io, bytes);
        },
    }
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        const message = std.fmt.allocPrint(init.arena.allocator(), "imprynt: {s}\n{s}", .{
            @errorName(err),
            if (err == error.InvalidArguments) usage else if (err == error.RecoveryRequired or err == error.RecoveryConflict) "State retained: do not delete the journal or retained originals.\n" else "",
        }) catch "imprynt: failed\n";
        std.Io.File.stderr().writeStreamingAll(init.io, message) catch {};
        std.process.exit(1);
    };
}

test "CLI requires explicit complete arguments and rejects duplicate or irrelevant flags" {
    try std.testing.expectError(error.InvalidArguments, parse(&.{}));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "apply", "--root", "/root", "--state", "/state" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "recover", "--root", "/root", "--state", "/state", "--manifest", "files" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "recover", "--root", "/root", "--root", "/root", "--state", "/state" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "retire", "--root", "/root", "--state", "/state" }));
    const result = try parse(&.{ "recover", "--root", "/root", "--state", "/state" });
    try std.testing.expectEqual(Command.recover, result.command);
}
