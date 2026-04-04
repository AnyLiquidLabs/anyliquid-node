const std = @import("std");
const shared = @import("../shared/mod.zig");
const state_cache = @import("state_cache.zig");

pub const AuthError = error{
    NonceTooOld,
    NonceTooNew,
    NonceReused,
    RateLimitExceeded,
    SignatureInvalid,
};

pub const Error = AuthError || std.mem.Allocator.Error;

pub const AuthConfig = struct {
    chain_id: u64 = 1337,
    nonce_max_skew_ms: i64 = 5_000,
    info_weight_per_min: u32 = 1_200,
    exchange_actions_per_min: u32 = 300,
    now_fn: *const fn () i64 = defaultNowMs,
};

pub const Bucket = struct {
    tokens: f64,
    last_refill_ms: i64,

    pub fn consume(self: *Bucket, capacity: f64, refill_per_minute: f64, cost: f64, now_ms: i64) AuthError!void {
        const elapsed_ms = @max(now_ms - self.last_refill_ms, 0);
        const refill = (refill_per_minute * @as(f64, @floatFromInt(elapsed_ms))) / 60_000.0;
        self.tokens = @min(capacity, self.tokens + refill);
        self.last_refill_ms = now_ms;

        if (self.tokens < cost) {
            return AuthError.RateLimitExceeded;
        }

        self.tokens -= cost;
    }
};

pub const NonceStore = struct {
    allocator: std.mem.Allocator,
    table: std.AutoHashMap(shared.types.Address, std.ArrayListUnmanaged(u64)),

    pub fn init(allocator: std.mem.Allocator) NonceStore {
        return .{
            .allocator = allocator,
            .table = std.AutoHashMap(shared.types.Address, std.ArrayListUnmanaged(u64)).init(allocator),
        };
    }

    pub fn deinit(self: *NonceStore) void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.table.deinit();
    }

    pub fn checkAndRecord(
        self: *NonceStore,
        addr: shared.types.Address,
        nonce: u64,
        now_ms: i64,
        max_skew_ms: i64,
    ) Error!void {
        const nonce_ms: i64 = @intCast(nonce);
        if (nonce_ms < now_ms - max_skew_ms) {
            return AuthError.NonceTooOld;
        }
        if (nonce_ms > now_ms + max_skew_ms) {
            return AuthError.NonceTooNew;
        }

        const gop = try self.table.getOrPut(addr);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }

        for (gop.value_ptr.items) |used_nonce| {
            if (used_nonce == nonce) {
                return AuthError.NonceReused;
            }
        }

        try gop.value_ptr.append(self.allocator, nonce);
    }
};

pub const Auth = struct {
    allocator: std.mem.Allocator,
    cfg: AuthConfig,
    nonce_store: NonceStore,
    ip_buckets: std.AutoHashMap(shared.types.IpAddr, Bucket),
    addr_buckets: std.AutoHashMap(shared.types.Address, Bucket),

    pub fn init(cfg: AuthConfig, allocator: std.mem.Allocator) Error!Auth {
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .nonce_store = NonceStore.init(allocator),
            .ip_buckets = std.AutoHashMap(shared.types.IpAddr, Bucket).init(allocator),
            .addr_buckets = std.AutoHashMap(shared.types.Address, Bucket).init(allocator),
        };
    }

    pub fn deinit(self: *Auth) void {
        self.addr_buckets.deinit();
        self.ip_buckets.deinit();
        self.nonce_store.deinit();
    }

    pub fn verifyAction(
        self: *Auth,
        action_hash: [32]u8,
        nonce: u64,
        sig: shared.types.EIP712Signature,
    ) Error!shared.types.Address {
        const typed_hash = shared.crypto.eip712Hash(.{
            .name = "Exchange",
            .version = "1",
            .chain_id = self.cfg.chain_id,
        }, action_hash);
        const signer = shared.crypto.ecrecover(typed_hash, sig.r, sig.s, sig.v) catch {
            return AuthError.SignatureInvalid;
        };

        try self.nonce_store.checkAndRecord(signer, nonce, self.cfg.now_fn(), self.cfg.nonce_max_skew_ms);
        return signer;
    }

    pub fn checkRateLimit(
        self: *Auth,
        ip: shared.types.IpAddr,
        addr: ?shared.types.Address,
    ) Error!void {
        const now_ms = self.cfg.now_fn();

        var ip_entry = try self.ip_buckets.getOrPut(ip);
        if (!ip_entry.found_existing) {
            ip_entry.value_ptr.* = .{
                .tokens = @floatFromInt(self.cfg.info_weight_per_min),
                .last_refill_ms = now_ms,
            };
        }
        try ip_entry.value_ptr.consume(
            @floatFromInt(self.cfg.info_weight_per_min),
            @floatFromInt(self.cfg.info_weight_per_min),
            1.0,
            now_ms,
        );

        if (addr) |address| {
            var addr_entry = try self.addr_buckets.getOrPut(address);
            if (!addr_entry.found_existing) {
                addr_entry.value_ptr.* = .{
                    .tokens = @floatFromInt(self.cfg.exchange_actions_per_min),
                    .last_refill_ms = now_ms,
                };
            }
            try addr_entry.value_ptr.consume(
                @floatFromInt(self.cfg.exchange_actions_per_min),
                @floatFromInt(self.cfg.exchange_actions_per_min),
                1.0,
                now_ms,
            );
        }
    }

    pub fn resolveAuthority(
        self: *Auth,
        signer: shared.types.Address,
        cache: *const state_cache.StateCache,
    ) !shared.types.Address {
        _ = self;
        return cache.getApiWalletOwner(signer) orelse signer;
    }
};

fn defaultNowMs() i64 {
    return std.time.milliTimestamp();
}

test "nonce reuse is rejected" {
    const now_ms = defaultNowMs();
    const secret_key = [_]u8{
        0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33,
        0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33,
        0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33,
        0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33,
    };
    const TestClock = struct {
        var value: i64 = 0;

        fn now() i64 {
            return value;
        }
    };
    TestClock.value = now_ms;

    var auth = try Auth.init(.{
        .now_fn = TestClock.now,
    }, std.testing.allocator);
    defer auth.deinit();

    const nonce: u64 = @intCast(now_ms);
    const action_hash = shared.crypto.keccak256("nonce-reuse");
    const typed_hash = shared.crypto.eip712Hash(.{
        .name = "Exchange",
        .version = "1",
        .chain_id = 1337,
    }, action_hash);
    const sig = try shared.crypto.signPrehashedRecoverable(secret_key, typed_hash);

    _ = try auth.verifyAction(action_hash, nonce, sig);
    try std.testing.expectError(AuthError.NonceReused, auth.verifyAction(action_hash, nonce, sig));
}
