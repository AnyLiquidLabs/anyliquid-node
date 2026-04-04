# Module: IPC Server

**File:** `src/node/ipc_server.zig`  
**Depends on:** `shared/protocol`, `engine/*`, `store`

## Responsibilities

- Listen for Unix socket connections from one or more API processes
- Accept action requests, enqueue them, and respond after execution is committed
- Accept query requests and serve them from local state without consensus
- Push Node events to all connected API processes

## Interface

```zig
pub const IpcServer = struct {
    pub fn init(cfg: IpcConfig, state: *GlobalState, mempool: *Mempool) !IpcServer
    pub fn deinit(self: *IpcServer) void
    pub fn tick(self: *IpcServer) void
    pub fn broadcastEvents(self: *IpcServer, events: []NodeEvent) void
};
```

## Action Flow

```text
1. receive action_req frame
2. perform lightweight validation such as format and nonce range
3. add the transaction to mempool
4. suspend the request until the transaction appears in a committed block
5. once block execution completes, map the execution result to action_ack
6. emit action_ack and any relevant NodeEvent frames
```

## Test Harness

```zig
test "place order action returns an ACK after block commit" {
    var node = try TestNode.init(alloc);
    defer node.deinit();

    const client = try IpcClient.connect(node.socketPath());
    const ack_fut = client.sendActionAsync(sample_place_order_action);

    try node.runUntilHeight(1);

    const ack = try ack_fut.await(timeout_ms: 2000);
    try std.testing.expectEqual(.resting, ack.status);
}

test "userState query returns immediately without consensus" {
    var node = try TestNode.init(alloc);
    defer node.deinit();

    const client = try IpcClient.connect(node.socketPath());
    const start = std.time.milliTimestamp();

    const resp = try client.query(.{ .user_state = test_addr });
    const elapsed = std.time.milliTimestamp() - start;

    try std.testing.expect(elapsed < 50);
    _ = resp;
}

test "API client receives pushed fill events" {
    var node = try TestNode.init(alloc);
    defer node.deinit();

    const client = try IpcClient.connect(node.socketPath());
    var received_fills: u32 = 0;
    client.onEvent(fn(e: NodeEvent) void {
        if (e == .fill) received_fills += 1;
    });

    node.submitMatchingOrders(buy_order, sell_order);
    try node.runUntilHeight(1);

    try waitUntil(fn() bool { return received_fills > 0; }, 1000);
}
```
