# Module: Auth Middleware

**File:** `src/api/auth.zig`  
**Depends on:** `shared/types`, `shared/crypto`

## Responsibilities

- Verify EIP-712 structured signatures compatible with Hyperliquid-style exchange actions
- Track nonces with a sliding anti-replay window
- Enforce token-bucket rate limits per IP and per address
- Resolve delegated API wallet authority

## Interface

```zig
pub const Auth = struct {
    allocator:     std.mem.Allocator,
    nonce_store:   NonceStore,
    rate_limiter:  RateLimiter,
    chain_id:      u64,

    pub fn init(cfg: AuthConfig, alloc: std.mem.Allocator) !Auth
    pub fn deinit(self: *Auth) void

    pub fn verifyAction(
        self: *Auth,
        action_hash: [32]u8,
        nonce: u64,
        sig: EIP712Signature,
    ) !Address

    pub fn checkRateLimit(self: *Auth, ip: IpAddr, addr: ?Address) !void
};
```

## EIP-712 Verification

```zig
const DOMAIN = EIP712Domain{
    .name = "Exchange",
    .version = "1",
    .chain_id = HYPERLIQUID_CHAIN_ID,
};

pub fn verifyAction(
    self: *Auth,
    action_hash: [32]u8,
    nonce: u64,
    sig: EIP712Signature,
) !Address {
    const typed_hash = eip712.hashTypedData(DOMAIN, action_hash);
    const signer = try secp256k1.ecrecover(typed_hash, sig.r, sig.s, sig.v);
    try self.nonce_store.checkAndRecord(signer, nonce);
    return signer;
}
```

## Nonce Management

```zig
pub const NonceStore = struct {
    table: std.AutoHashMap(Address, NonceWindow),

    pub fn checkAndRecord(self: *NonceStore, addr: Address, nonce: u64) !void
    // error.NonceTooOld
    // error.NonceTooNew
    // error.NonceReused
};
```

The current design assumes nonce values are Unix-millisecond timestamps with a +/- 5 second acceptance window.

## Rate Limiting

```zig
pub fn RateLimiter(comptime cfg: RateLimitConfig) type {
    return struct {
        ip_buckets:   std.AutoHashMap(IpAddr, Bucket),
        addr_buckets: std.AutoHashMap(Address, Bucket),
    };
}

pub const Bucket = struct {
    tokens:      f64,
    last_refill: i64,

    pub fn consume(self: *Bucket, cost: f64, now_ms: i64) !void
    // error.RateLimitExceeded
};
```

Default quota guidance:

- `/info`: 1200 weight per minute per IP
- `/exchange`: 300 actions per minute per address

## API Wallet Delegation

```zig
pub fn resolveAuthority(
    self: *Auth,
    signer: Address,
    cache: *StateCache,
) !Address {
    return cache.getApiWalletOwner(signer) orelse signer;
}
```

## Harness Concerns

The auth design should expose deterministic test seams:

- a fake clock for nonce validation and bucket refill timing
- a cache mock for API wallet ownership lookup
- readable bucket state or rate-limit counters to confirm refill behavior

## Test Harness

```zig
// src/api/auth_test.zig

test "valid EIP-712 signature returns the signer" {
    const auth = try Auth.init(test_cfg, std.testing.allocator);
    defer auth.deinit();

    const signer = try auth.verifyAction(test_action_hash, test_nonce, valid_signature);
    try std.testing.expectEqual(expected_address, signer);
}

test "tampered signature returns error.SignatureInvalid" {
    const auth = try Auth.init(test_cfg, std.testing.allocator);
    defer auth.deinit();

    try std.testing.expectError(
        error.SignatureInvalid,
        auth.verifyAction(test_action_hash, test_nonce, tampered_sig),
    );
}

test "nonce reuse returns error.NonceReused" {
    var auth = try Auth.init(test_cfg, std.testing.allocator);
    defer auth.deinit();

    _ = try auth.verifyAction(test_action_hash, 1000, valid_sig_nonce_1000);
    try std.testing.expectError(
        error.NonceReused,
        auth.verifyAction(test_action_hash2, 1000, valid_sig2_nonce_1000),
    );
}

test "nonce too old returns error.NonceTooOld" {
    var auth = try Auth.init(test_cfg, std.testing.allocator);
    defer auth.deinit();

    const stale_nonce = std.time.milliTimestamp() - 10_000;
    try std.testing.expectError(
        error.NonceTooOld,
        auth.verifyAction(test_action_hash, @intCast(stale_nonce), stale_sig),
    );
}

test "rate limit exceedance returns error.RateLimitExceeded" {
    var auth = try Auth.init(.{ .info_weight_per_min = 10 }, std.testing.allocator);
    defer auth.deinit();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try auth.checkRateLimit(test_ip, null);
    }
    try std.testing.expectError(error.RateLimitExceeded, auth.checkRateLimit(test_ip, null));
}

test "API wallet resolves to owner address" {
    var auth = try Auth.init(test_cfg, std.testing.allocator);
    defer auth.deinit();

    const resolved = try auth.resolveAuthority(api_wallet_addr, &mock_cache);
    try std.testing.expectEqual(owner_addr, resolved);
}
```
