const std = @import("std");
const shared = @import("../shared/mod.zig");
const auth_mod = @import("auth.zig");
const gateway_mod = @import("gateway.zig");
const cache_mod = @import("state_cache.zig");

pub const ConnId = u64;

pub const WsConfig = struct {
    send_buf_size: usize = 4096,
};

pub const Subscription = union(enum) {
    all_mids: void,
    l2_book: struct { coin: []const u8 },
    trades: struct { coin: []const u8 },
    order_updates: struct { user: shared.types.Address },
    user: struct { user: shared.types.Address },
    user_fills: struct { user: shared.types.Address },
    notification: struct { user: shared.types.Address },
};

pub const WsMetrics = struct {
    slow_client_drops: u64 = 0,
};

pub const SubscriptionManager = struct {
    allocator: std.mem.Allocator,
    table: std.StringHashMap(std.ArrayListUnmanaged(ConnId)),

    pub fn init(allocator: std.mem.Allocator) SubscriptionManager {
        return .{
            .allocator = allocator,
            .table = std.StringHashMap(std.ArrayListUnmanaged(ConnId)).init(allocator),
        };
    }

    pub fn deinit(self: *SubscriptionManager) void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.table.deinit();
    }

    pub fn subscribe(self: *SubscriptionManager, conn_id: ConnId, key: []const u8) !void {
        const gop = try self.table.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }

        for (gop.value_ptr.items) |existing| {
            if (existing == conn_id) return;
        }

        try gop.value_ptr.append(self.allocator, conn_id);
    }

    pub fn unsubscribe(self: *SubscriptionManager, conn_id: ConnId, key: []const u8) void {
        if (self.table.getPtr(key)) |list| {
            var idx: usize = 0;
            while (idx < list.items.len) : (idx += 1) {
                if (list.items[idx] == conn_id) {
                    _ = list.swapRemove(idx);
                    break;
                }
            }
        }
    }

    pub fn removeConn(self: *SubscriptionManager, conn_id: ConnId) void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            var idx: usize = 0;
            while (idx < entry.value_ptr.items.len) : (idx += 1) {
                if (entry.value_ptr.items[idx] == conn_id) {
                    _ = entry.value_ptr.swapRemove(idx);
                    break;
                }
            }
        }
    }

    pub fn count(self: *const SubscriptionManager, key: []const u8) usize {
        if (self.table.get(key)) |list| {
            return list.items.len;
        }
        return 0;
    }
};

pub const WsServer = struct {
    allocator: std.mem.Allocator,
    auth: *auth_mod.Auth,
    gateway: *gateway_mod.Gateway,
    cache: *cache_mod.StateCache,
    sub_manager: SubscriptionManager,
    metrics: WsMetrics = .{},
    running: bool = false,

    pub fn init(
        cfg: WsConfig,
        auth: *auth_mod.Auth,
        gateway: *gateway_mod.Gateway,
        cache: *cache_mod.StateCache,
        allocator: std.mem.Allocator,
    ) !WsServer {
        _ = cfg;
        return .{
            .allocator = allocator,
            .auth = auth,
            .gateway = gateway,
            .cache = cache,
            .sub_manager = SubscriptionManager.init(allocator),
        };
    }

    pub fn deinit(self: *WsServer) void {
        self.sub_manager.deinit();
    }

    pub fn start(self: *WsServer) !void {
        self.running = true;
    }

    pub fn stop(self: *WsServer) void {
        self.running = false;
    }

    pub fn onNodeEvent(self: *WsServer, event: shared.protocol.NodeEvent) void {
        _ = self;
        _ = event;
    }
};
