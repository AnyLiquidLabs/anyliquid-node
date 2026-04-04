# Module: WebSocket Server

**File:** `src/api/websocket.zig`  
**Depends on:** `auth`, `gateway`, `state_cache`, `shared/types`

## Responsibilities

- Manage WebSocket handshakes, reads, writes, and heartbeats
- Maintain a topic-to-subscriber registry
- Fan out Node events received via `Gateway`
- Support authenticated `action` messages in addition to subscriptions

## Interface

```zig
pub const WsServer = struct {
    allocator:   std.mem.Allocator,
    auth:        *Auth,
    gateway:     *Gateway,
    cache:       *StateCache,
    sub_manager: SubscriptionManager,

    pub fn init(cfg: WsConfig, auth: *Auth, gw: *Gateway, cache: *StateCache) !WsServer
    pub fn start(self: *WsServer) !void
    pub fn stop(self: *WsServer) void
    pub fn onNodeEvent(self: *WsServer, event: NodeEvent) void
};
```

## Topics

| Topic | Meaning | Auth Required |
| --- | --- | --- |
| `allMids` | latest midpoint for all assets | no |
| `l2Book` `{ coin }` | L2 order book for one asset | no |
| `trades` `{ coin }` | recent trades for one asset | no |
| `orderUpdates` | order updates for the current user | yes |
| `user` | account and position updates for the current user | yes |
| `userFills` | fills for the current user | yes |
| `notification` | system notifications such as liquidation warnings | yes |

## Message Formats

### Client -> Server

```json
{ "method": "subscribe", "subscription": { "type": "l2Book", "coin": "BTC" } }
{ "method": "unsubscribe", "subscription": { "type": "l2Book", "coin": "BTC" } }
{ "method": "action", "action": { ... }, "nonce": 123, "signature": { ... } }
{ "method": "ping" }
```

### Server -> Client

```json
{ "channel": "subscriptionResponse", "data": { "method": "subscribe", "subscription": { ... } } }
{ "channel": "l2Book", "data": { "coin": "BTC", "levels": [[...], [...]], "time": 1234567890 } }
{ "channel": "pong" }
{ "channel": "error", "data": "Subscription requires authentication" }
```

## Key Structures

```zig
pub const Subscription = union(enum) {
    all_mids:      void,
    l2_book:       struct { coin: []const u8 },
    trades:        struct { coin: []const u8 },
    order_updates: struct { user: Address },
    user:          struct { user: Address },
    user_fills:    struct { user: Address },
    notification:  struct { user: Address },
};

pub const SubscriptionManager = struct {
    table: std.StringHashMap(ConnList),

    pub fn subscribe(self: *SubscriptionManager, conn_id: ConnId, sub: Subscription) !void
    pub fn unsubscribe(self: *SubscriptionManager, conn_id: ConnId, sub: Subscription) void
    pub fn removeConn(self: *SubscriptionManager, conn_id: ConnId) void
    pub fn fanOut(self: *SubscriptionManager, event: NodeEvent) void
};

pub const Connection = struct {
    id:        ConnId,
    socket:    std.posix.socket_t,
    user:      ?Address,
    send_buf:  RingBuffer(4096),
    last_ping: i64,
};
```

## Push Rate Control

Each connection maintains a fixed-size send ring buffer. If a client falls behind:

- drop the oldest message
- increment the `slow_client` metric
- disconnect the client after repeated overflows

## Harness Concerns

The WebSocket design should make these states observable:

- connection state: connected, authenticated, disconnected
- subscription registration and removal
- correct fan-out to all matching subscribers
- backpressure counters and disconnect thresholds

## Test Harness

```zig
// src/api/websocket_test.zig

const harness = @import("test_harness.zig");

test "subscribe l2Book receives a snapshot immediately" {
    var h = try harness.initWs(.{
        .cache_seed = .{ .btc_book = sample_btc_book },
    });
    defer h.deinit();

    const conn = try h.connect();
    try conn.send("{\"method\":\"subscribe\",\"subscription\":{\"type\":\"l2Book\",\"coin\":\"BTC\"}}");

    const msg = try conn.recv(timeout_ms);
    try std.testing.expectEqualStrings("l2Book", msg.channel);
}

test "orderUpdates subscription requires authentication" {
    var h = try harness.initWs(.{});
    defer h.deinit();

    const conn = try h.connect();
    try conn.send("{\"method\":\"subscribe\",\"subscription\":{\"type\":\"orderUpdates\"}}");

    const msg = try conn.recv(timeout_ms);
    try std.testing.expectEqualStrings("error", msg.channel);
}

test "l2Book fan-out reaches all subscribers" {
    var h = try harness.initWs(.{});
    defer h.deinit();

    const c1 = try h.connect();
    const c2 = try h.connect();
    try c1.subscribeL2Book("BTC");
    try c2.subscribeL2Book("BTC");

    h.injectNodeEvent(.{ .l2_book_update = sample_update });

    const m1 = try c1.recv(timeout_ms);
    const m2 = try c2.recv(timeout_ms);
    try std.testing.expectEqualStrings("l2Book", m1.channel);
    try std.testing.expectEqualStrings("l2Book", m2.channel);
}

test "slow client overflow does not block others" {
    var h = try harness.initWs(.{ .send_buf_size = 64 });
    defer h.deinit();

    const fast = try h.connect();
    const slow = try h.connect();
    try fast.subscribeL2Book("ETH");
    try slow.subscribeL2Book("ETH");

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        h.injectNodeEvent(.{ .l2_book_update = sample_update });
    }

    _ = try fast.recv(timeout_ms);
    try std.testing.expect(h.metrics.slow_client_drops > 0);
}

test "server responds to ping with pong" {
    var h = try harness.initWs(.{});
    defer h.deinit();

    const conn = try h.connect();
    try conn.send("{\"method\":\"ping\"}");

    const msg = try conn.recv(timeout_ms);
    try std.testing.expectEqualStrings("pong", msg.channel);
}

test "disconnect removes all subscriptions for the connection" {
    var h = try harness.initWs(.{});
    defer h.deinit();

    const conn = try h.connect();
    try conn.subscribeL2Book("BTC");
    try conn.close();

    try std.testing.expectEqual(@as(usize, 0), h.subscriptionCount("l2Book:BTC"));
}
```
