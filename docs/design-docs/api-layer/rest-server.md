# Module: REST Server

**File:** `src/api/rest.zig`  
**Depends on:** `auth`, `gateway`, `state_cache`, `shared/types`

## Responsibilities

- Listen for HTTP requests and route them to handlers
- Serialize and deserialize JSON request and response bodies
- Send authenticated write operations to `Gateway`
- Serve read operations from `StateCache` without IPC

## Interface

```zig
pub const RestServer = struct {
    allocator:   std.mem.Allocator,
    auth:        *Auth,
    gateway:     *Gateway,
    cache:       *StateCache,
    listen_addr: std.net.Address,

    pub fn init(cfg: RestConfig, auth: *Auth, gw: *Gateway, cache: *StateCache) !RestServer
    pub fn start(self: *RestServer) !void
    pub fn stop(self: *RestServer) void
};
```

## Route Table

### Exchange endpoints

| Method | Path | Action Type | Handler |
| --- | --- | --- | --- |
| POST | `/exchange` | `order` | `handlePlaceOrder` |
| POST | `/exchange` | `cancel` | `handleCancelOrder` |
| POST | `/exchange` | `cancelByCloid` | `handleCancelByCloid` |
| POST | `/exchange` | `batchOrders` | `handleBatchOrders` |
| POST | `/exchange` | `updateLeverage` | `handleUpdateLeverage` |
| POST | `/exchange` | `updateIsolatedMargin` | `handleUpdateMargin` |
| POST | `/exchange` | `withdraw` | `handleWithdraw` |

### Info endpoints

| Method | Path | `type` Field | Handler |
| --- | --- | --- | --- |
| POST | `/info` | `meta` | `handleMeta` |
| POST | `/info` | `allMids` | `handleAllMids` |
| POST | `/info` | `l2Book` | `handleL2Book` |
| POST | `/info` | `recentTrades` | `handleRecentTrades` |
| POST | `/info` | `userState` | `handleUserState` |
| POST | `/info` | `openOrders` | `handleOpenOrders` |
| POST | `/info` | `userFills` | `handleUserFills` |
| POST | `/info` | `fundingHistory` | `handleFundingHistory` |

## Key Data Structures

```zig
pub const PlaceOrderRequest = struct {
    action: OrderAction,
    nonce: u64,
    signature: EIP712Signature,
};

pub const OrderAction = struct {
    type:     []const u8,
    orders:   []OrderWire,
    grouping: Grouping,
};

pub const OrderWire = struct {
    a: u32,
    b: bool,
    p: []const u8,
    s: []const u8,
    r: bool,
    t: OrderType,
    c: ?[]const u8,
};

pub const ApiResponse = union(enum) {
    ok:  OkResponse,
    err: ErrResponse,

    pub fn toJson(self: ApiResponse, alloc: std.mem.Allocator) ![]u8
};
```

## Handler Pattern

```zig
fn handlePlaceOrder(ctx: *RequestCtx) !void {
    const req = try json.parse(PlaceOrderRequest, ctx.body, ctx.arena);
    try validateOrderParams(req.action.orders);
    const ack = try ctx.gateway.sendAction(req.action, req.nonce, req.signature);
    try ctx.writeJson(ApiResponse{ .ok = .{ .data = ack } });
}
```

## Error Set

```zig
pub const ApiError = error{
    InvalidJson,
    SignatureInvalid,
    NonceExpired,
    RateLimitExceeded,
    AssetNotFound,
    OrderNotFound,
    InsufficientMargin,
    NodeTimeout,
    NodeUnavailable,
};
```

## Harness Concerns

REST tests should be able to verify:

- that write paths can replace `Gateway` and observe forwarded payloads
- that read paths can seed `StateCache` and prove IPC was not used
- that HTTP status codes and JSON error bodies map deterministically from typed errors
- that time-sensitive paths use a fake clock rather than wall-clock timing

## Test Harness

```zig
// src/api/rest_test.zig

const harness = @import("test_harness.zig");

test "POST /exchange place order with valid signature succeeds" {
    var h = try harness.init(.{
        .mock_gateway = true,
        .mock_node_response = .{ .order_id = 12345, .status = .resting },
    });
    defer h.deinit();

    const resp = try h.post("/exchange", valid_place_order_json);
    try std.testing.expectEqual(resp.status, 200);
    try std.testing.expectEqualStrings("resting", resp.body.status);
}

test "POST /exchange with invalid signature returns 401" {
    var h = try harness.init(.{});
    defer h.deinit();

    const resp = try h.post("/exchange", tampered_signature_json);
    try std.testing.expectEqual(resp.status, 401);
}

test "POST /info l2Book is served from cache without IPC" {
    var h = try harness.init(.{
        .cache_seed = .{ .btc_book = sample_btc_book },
    });
    defer h.deinit();

    const resp = try h.post("/info", l2book_request_json);
    try std.testing.expectEqual(resp.status, 200);
    try std.testing.expect(h.gateway_call_count == 0);
}

test "POST /exchange gateway timeout returns 504" {
    var h = try harness.init(.{
        .mock_gateway = true,
        .mock_gateway_timeout = true,
    });
    defer h.deinit();

    const resp = try h.post("/exchange", valid_place_order_json);
    try std.testing.expectEqual(resp.status, 504);
}

test "rate limit exceedance returns 429" {
    var h = try harness.init(.{ .rate_limit = .{ .per_ip_rps = 10 } });
    defer h.deinit();

    var i: usize = 0;
    while (i < 15) : (i += 1) {
        _ = try h.post("/info", meta_request_json);
    }
    const resp = try h.post("/info", meta_request_json);
    try std.testing.expectEqual(resp.status, 429);
}
```

## Performance Notes

- Each request gets its own arena allocator and frees in a single shot when the handler returns.
- JSON parsing holds slices into the request body instead of copying strings.
- `io_uring` batches accept and read operations to reduce syscalls.
