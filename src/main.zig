const std = @import("std");
const nodus = @import("nodus");
const repo_root = ".";

const parser = @import("cli/parser.zig");
const registry = @import("cli/registry.zig");
const usage = @import("cli/usage.zig");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const alloc = debug_allocator.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    const parsed = parser.parse(&args) orelse {
        usage.print();
        return;
    };

    const cmd = registry.find(parsed.command) orelse {
        std.debug.print("unknown command: {s}\n", .{parsed.command});
        usage.print();
        return;
    };

    try cmd.run(alloc, &args);
}
