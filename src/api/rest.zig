const std = @import("std");
const shared = @import("../shared/mod.zig");
const auth_mod = @import("auth.zig");
const gateway_mod = @import("gateway.zig");
const cache_mod = @import("state_cache.zig");

pub const RestConfig = struct {
    listen_addr: []const u8 = "127.0.0.1:8080",
};

pub const RestServer = struct {
    allocator: std.mem.Allocator,
    auth: *auth_mod.Auth,
    gateway: *gateway_mod.Gateway,
    cache: *cache_mod.StateCache,
    listen_addr: []const u8,
    running: bool = false,

    pub fn init(
        cfg: RestConfig,
        auth: *auth_mod.Auth,
        gateway: *gateway_mod.Gateway,
        cache: *cache_mod.StateCache,
        allocator: std.mem.Allocator,
    ) !RestServer {
        return .{
            .allocator = allocator,
            .auth = auth,
            .gateway = gateway,
            .cache = cache,
            .listen_addr = cfg.listen_addr,
        };
    }

    pub fn start(self: *RestServer) !void {
        self.running = true;
    }

    pub fn stop(self: *RestServer) void {
        self.running = false;
    }

    pub fn handlePlaceOrder(self: *RestServer, req: shared.types.PlaceOrderRequest) !shared.protocol.ActionAck {
        return self.handlePlaceOrderFromIp(0, req);
    }

    pub fn handlePlaceOrderFromIp(
        self: *RestServer,
        ip: shared.types.IpAddr,
        req: shared.types.PlaceOrderRequest,
    ) !shared.protocol.ActionAck {
        const action = shared.types.ActionPayload{ .order = req.action };
        const action_hash = try shared.crypto.hashActionForSignature(self.allocator, action, req.nonce);
        const signer = try self.auth.verifyAction(action_hash, req.nonce, req.signature);
        try self.auth.checkRateLimit(ip, signer);
        const authority = try self.auth.resolveAuthority(signer, self.cache);

        return try self.gateway.sendAction(.{
            .action = action,
            .nonce = req.nonce,
            .signature = req.signature,
            .user = authority,
        });
    }
};
