# Module: P2P Network

**File:** `src/node/net/`  
**Depends on:** `shared/protocol`, `shared/crypto`

## Responsibilities

- Discover peers through static seeds plus Kademlia-style expansion
- Gossip transactions and oracle submissions
- Deliver direct peer-to-peer consensus messages
- Synchronize blocks for lagging or new nodes

## Interface

```zig
pub const P2pNet = struct {
    pub fn init(cfg: NetConfig, alloc: std.mem.Allocator) !P2pNet
    pub fn deinit(self: *P2pNet) void
    pub fn broadcast(self: *P2pNet, msg: P2pMsg) void
    pub fn sendTo(self: *P2pNet, peer: PeerId, msg: P2pMsg) !void
    pub fn recv(self: *P2pNet) []ReceivedMsg
    pub fn connectedPeers(self: *P2pNet) []PeerId
    pub fn syncBlocks(self: *P2pNet, from_height: u64, to_height: u64) ![]Block
};

pub const P2pMsg = union(enum) {
    tx:           Transaction,
    oracle_price: OracleSubmission,
    consensus:    ConsensusMsg,
    block_req:    BlockRequest,
    block_resp:   BlockResponse,
};
```

## Gossip Protocol

```text
- fanout to k=8 random peers on each broadcast
- carry a TTL and decrement it on each hop
- use message_id = hash(payload)
- deduplicate with a seen-cache LRU of 10,000 entries
```

## Test Harness

```zig
test "gossip reaches all nodes in a three-hop network" {
    var cluster = try NetCluster.init(10, alloc);
    defer cluster.deinit();

    cluster.nodes[0].broadcast(.{ .tx = sample_tx });

    try waitUntil(fn() bool {
        for (cluster.nodes[1..]) |n| {
            if (!n.hasSeen(sample_tx.hash())) return false;
        }
        return true;
    }, timeout_ms: 1000);
}

test "duplicate messages are not forwarded twice" {
    var cluster = try NetCluster.init(4, alloc);
    defer cluster.deinit();

    cluster.nodes[0].broadcast(.{ .tx = sample_tx });
    cluster.nodes[1].broadcast(.{ .tx = sample_tx });

    try std.testing.expectEqual(1, cluster.nodes[2].receiveCount(sample_tx.hash()));
}
```
