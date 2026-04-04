# Module: Gateway

**File:** `src/api/gateway.zig`  
**Depends on:** `shared/protocol`, `shared/types`

## Responsibilities

- Maintain the IPC connection to Node over Unix socket or internal TCP
- Send actions and wait for ACKs with synchronous semantics backed by async internals
- Subscribe to Node event streams and forward them to the WebSocket server and local cache
- Reconnect automatically and expose connection health

## Interface

```zig
pub const Gateway = struct {
    allocator: std.mem.Allocator,
    conn:      IpcConn,
    on_event:  EventCallback,

    pub fn init(cfg: GatewayConfig, on_event: EventCallback, alloc: std.mem.Allocator) !Gateway
    pub fn deinit(self: *Gateway) void

    pub fn sendAction(
        self: *Gateway,
        action: ActionPayload,
        nonce: u64,
        signature: EIP712Signature,
    ) !ActionAck

    pub fn query(self: *Gateway, req: QueryRequest) !QueryResponse
    pub fn isConnected(self: *Gateway) bool
};

pub const EventCallback = *const fn (event: NodeEvent) void;
```

## IPC Frame Protocol

```text
┌──────────┬──────────┬──────────┬──────────────────────┐
│  len     │  msg_id  │  type    │  payload             │
│  u32 BE  │  u32     │  u8      │  msgpack bytes       │
└──────────┴──────────┴──────────┴──────────────────────┘
```

`msg_id` pairs requests and responses. Pushed events use `msg_id = 0`.

```zig
pub const MsgType = enum(u8) {
    action_req = 0x01,
    query_req = 0x02,

    action_ack = 0x81,
    query_resp = 0x82,
    error_resp = 0x8F,

    event_l2_book = 0xA1,
    event_trades = 0xA2,
    event_all_mids = 0xA3,
    event_order_upd = 0xA4,
    event_user = 0xA5,
    event_fill = 0xA6,
    event_liquidation = 0xA7,
    event_funding = 0xA8,
};
```

## Pending Map

```zig
const PendingMap = std.AutoHashMap(u32, PendingRequest);

const PendingRequest = struct {
    response_chan: Channel(ActionAck),
    deadline_ms:   i64,
};
```

The read loop dispatches by `msg_id`:

- `msg_id != 0`: find the pending waiter and complete it
- `msg_id == 0`: decode a pushed event and call `on_event`

## Reconnect Strategy

```zig
const reconnect_delays = [_]u64{ 100, 500, 1000, 2000, 5000 };
```

During reconnect, `sendAction` fails fast with `error.NodeUnavailable`. The API layer does not queue writes locally.

## Harness Concerns

Gateway tests should be able to control:

- whether Node returns an ACK, an error, or never responds
- whether the connection is down, reconnecting, or restored
- whether pushed events interleave with in-flight responses

## Test Harness

```zig
// src/api/gateway_test.zig

test "sendAction receives ACK from mock node" {
    var mock_node = try MockNode.start(test_socket_path);
    defer mock_node.stop();

    mock_node.willRespond(.{ .order_id = 42, .status = .resting });

    var gw = try Gateway.init(.{ .socket_path = test_socket_path }, noop_cb, alloc);
    defer gw.deinit();

    const ack = try gw.sendAction(sample_action, 1000, sample_sig);
    try std.testing.expectEqual(42, ack.order_id);
}

test "sendAction timeout returns error.NodeTimeout" {
    var mock_node = try MockNode.start(test_socket_path);
    defer mock_node.stop();

    mock_node.willHang();

    var gw = try Gateway.init(.{ .socket_path = test_socket_path, .timeout_ms = 100 }, noop_cb, alloc);
    defer gw.deinit();

    try std.testing.expectError(error.NodeTimeout, gw.sendAction(sample_action, 1000, sample_sig));
}

test "event push invokes callback with the correct event" {
    var received: ?NodeEvent = null;
    const cb = struct {
        fn f(e: NodeEvent) void {
            received = e;
        }
    }.f;

    var mock_node = try MockNode.start(test_socket_path);
    defer mock_node.stop();

    var gw = try Gateway.init(.{ .socket_path = test_socket_path }, cb, alloc);
    defer gw.deinit();

    mock_node.pushEvent(.{ .l2_book_update = sample_book_update });
    try waitUntil(fn() bool { return received != null; }, 500);

    try std.testing.expect(received.?.l2_book_update.coin[0] == 'B');
}

test "reconnect resumes after node restart" {
    var mock_node = try MockNode.start(test_socket_path);

    var gw = try Gateway.init(.{ .socket_path = test_socket_path }, noop_cb, alloc);
    defer gw.deinit();

    mock_node.stop();
    try std.testing.expect(!gw.isConnected());

    mock_node = try MockNode.start(test_socket_path);
    defer mock_node.stop();

    try waitUntil(fn() bool { return gw.isConnected(); }, 6000);
    try std.testing.expect(gw.isConnected());
}

test "reconnect window returns error.NodeUnavailable" {
    var mock_node = try MockNode.start(test_socket_path);
    var gw = try Gateway.init(.{ .socket_path = test_socket_path }, noop_cb, alloc);
    defer gw.deinit();

    mock_node.stop();

    try std.testing.expectError(
        error.NodeUnavailable,
        gw.sendAction(sample_action, 1000, sample_sig),
    );
}
```
