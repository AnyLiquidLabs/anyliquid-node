const std = @import("std");
const shared = @import("../../shared/mod.zig");

pub const Oracle = struct {
    allocator: std.mem.Allocator,
    submissions: std.AutoHashMap(shared.types.Address, shared.types.Price),

    pub fn init(allocator: std.mem.Allocator) Oracle {
        return .{
            .allocator = allocator,
            .submissions = std.AutoHashMap(shared.types.Address, shared.types.Price).init(allocator),
        };
    }

    pub fn deinit(self: *Oracle) void {
        self.submissions.deinit();
    }

    pub fn submitPrice(self: *Oracle, from: shared.types.Address, price: shared.types.Price) !void {
        try self.submissions.put(from, price);
    }

    pub fn hasSubmitted(self: *const Oracle, validator: shared.types.Address) bool {
        return self.submissions.contains(validator);
    }
};
