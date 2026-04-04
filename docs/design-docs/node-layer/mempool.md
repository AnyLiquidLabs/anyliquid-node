# Module: Mempool

**File:** `src/node/mempool.zig`  
**Depends on:** `shared/types`

## Responsibilities

- Accept and queue pending transactions
- Deduplicate by `(address, nonce)`
- Preserve proposer ordering, currently FIFO
- Return a batch of ordered transactions for block proposal

## Interface

```zig
pub const Mempool = struct {
    pub fn init(cfg: MempoolConfig, alloc: std.mem.Allocator) Mempool
    pub fn deinit(self: *Mempool) void
    pub fn add(self: *Mempool, tx: Transaction) !void
    pub fn peek(self: *Mempool, max_txs: usize) []const Transaction
    pub fn removeConfirmed(self: *Mempool, txs: []const Transaction) void
    pub fn size(self: *Mempool) usize
};
```

Typed errors:

- `error.DuplicateTx`: a transaction with the same `(address, nonce)` is already pending
- `error.MempoolFull`: capacity has been exceeded

## Test Harness

```zig
test "add and peek preserve FIFO order" {
    var mp = Mempool.init(.{ .max_size = 1000 }, alloc);
    defer mp.deinit();

    try mp.add(tx_a);
    try mp.add(tx_b);
    try mp.add(tx_c);

    const batch = mp.peek(10);
    try std.testing.expectEqual(tx_a.hash(), batch[0].hash());
}

test "duplicate nonce is rejected" {
    var mp = Mempool.init(.{ .max_size = 1000 }, alloc);
    defer mp.deinit();

    try mp.add(tx_nonce_100);
    try std.testing.expectError(error.DuplicateTx, mp.add(tx_same_nonce_100));
}

test "removeConfirmed reduces the pending size" {
    var mp = Mempool.init(.{ .max_size = 1000 }, alloc);
    defer mp.deinit();

    try mp.add(tx_a);
    try mp.add(tx_b);
    mp.removeConfirmed(&.{tx_a});

    try std.testing.expectEqual(1, mp.size());
}
```
