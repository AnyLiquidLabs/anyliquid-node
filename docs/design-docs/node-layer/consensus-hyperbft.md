# Module: Consensus (HyperBFT)

**File:** `src/node/consensus/`  
**Depends on:** `net`, `store`, `shared/crypto`

## Responsibilities

- Implement a HotStuff-style BFT protocol with Prepare, Pre-commit, and Commit phases
- Manage validator membership and voting weights
- Rotate leaders by round
- Propose blocks from the mempool
- Form quorum certificates once 2/3 voting power is collected
- Advance rounds with a pacemaker when timeouts occur

## File Layout

```text
src/node/consensus/
├── mod.zig
├── hotstuff.zig
├── pacemaker.zig
├── block.zig
├── vote.zig
└── validator_set.zig
```

## Interface

```zig
pub const Consensus = struct {
    state:         HotStuffState,
    pacemaker:     Pacemaker,
    validator_set: ValidatorSet,
    net:           *P2pNet,
    mempool:       *Mempool,
    store:         *Store,

    pub fn init(cfg: ConsensusConfig, net: *P2pNet, mempool: *Mempool, store: *Store) !Consensus
    pub fn deinit(self: *Consensus) void
    pub fn tick(self: *Consensus, now_ms: i64) !?CommittedBlock
    pub fn onMessage(self: *Consensus, msg: ConsensusMsg, from: PeerId) !void
    pub fn isLeader(self: *Consensus) bool
    pub fn currentRound(self: *Consensus) u64
    pub fn currentHeight(self: *Consensus) u64
};
```

## HotStuff Phases

```text
Round r, leader L:

  L -> ALL: PREPARE(block, round, high_qc)
  Validators -> L: PREPARE_VOTE(block_hash, round)
  L collects 2f+1 votes -> PREPARE_QC

  L -> ALL: PRE_COMMIT(prepare_qc)
  Validators -> L: PRE_COMMIT_VOTE
  L collects 2f+1 votes -> PRE_COMMIT_QC
  Validators lock on PRE_COMMIT_QC

  L -> ALL: COMMIT(pre_commit_qc)
  Validators -> L: COMMIT_VOTE
  L collects 2f+1 votes -> COMMIT_QC

  L -> ALL: DECIDE(commit_qc)
  ALL: finalize the block
```

## Key Structures

```zig
pub const Block = struct {
    height:       u64,
    round:        u64,
    parent_hash:  [32]u8,
    txs_hash:     [32]u8,
    state_root:   [32]u8,
    proposer:     Address,
    timestamp:    i64,
    transactions: []Transaction,
};

pub const Vote = struct {
    block_hash: [32]u8,
    height:     u64,
    round:      u64,
    phase:      Phase,
    voter:      Address,
    signature:  BlsSignature,
};

pub const QuorumCert = struct {
    block_hash: [32]u8,
    phase:      Phase,
    signatures: BlsAggregateSignature,
    signers:    ValidatorBitset,
};

pub const HotStuffState = struct {
    height:        u64,
    round:         u64,
    phase:         Phase,
    locked_qc:     ?QuorumCert,
    high_qc:       ?QuorumCert,
    pending_votes: VoteAccumulator,
    current_block: ?Block,
};
```

## Pacemaker

```zig
pub const Pacemaker = struct {
    round_timeout_ms: u64,
    last_progress:    i64,

    pub fn tick(self: *Pacemaker, state: *HotStuffState, now_ms: i64) ?u64 {
        if (now_ms - self.last_progress > self.round_timeout_ms) {
            return state.round + 1;
        }
        return null;
    }
};

pub fn leaderForRound(validator_set: *ValidatorSet, round: u64) Address {
    return validator_set.validators[round % validator_set.validators.len].address;
}
```

## Test Harness

```zig
// src/node/consensus/consensus_test.zig

test "four validators commit a block across three phases" {
    var cluster = try TestCluster.init(4, alloc);
    defer cluster.deinit();

    cluster.nodes[0].submitTx(sample_tx);
    try cluster.runUntilHeight(1, timeout_ms: 2000);

    for (cluster.nodes) |node| {
        try std.testing.expectEqual(1, node.consensus.currentHeight());
    }
    try std.testing.expectEqual(
        cluster.nodes[0].lastCommittedHash(),
        cluster.nodes[1].lastCommittedHash(),
    );
}

test "leader timeout causes a new leader to take over" {
    var cluster = try TestCluster.init(4, alloc);
    defer cluster.deinit();

    cluster.partitionNode(0);

    try cluster.runUntilHeight(1, timeout_ms: 3000);
    for (cluster.nodes[1..]) |node| {
        try std.testing.expectEqual(1, node.consensus.currentHeight());
    }
}

test "one Byzantine validator does not break liveness" {
    var cluster = try TestCluster.init(4, alloc);
    defer cluster.deinit();

    cluster.makeEquivocating(0);

    try cluster.runUntilHeight(1, timeout_ms: 3000);
    for (cluster.nodes[1..]) |node| {
        try std.testing.expectEqual(1, node.consensus.currentHeight());
    }
}

test "honest nodes never commit conflicting blocks" {
    var cluster = try TestCluster.init(4, alloc);
    defer cluster.deinit();

    try cluster.runUntilHeight(100, timeout_ms: 60_000);

    var h: u64 = 1;
    while (h <= 100) : (h += 1) {
        const expected = cluster.nodes[0].committedHashAt(h);
        for (cluster.nodes[1..]) |node| {
            try std.testing.expectEqual(expected, node.committedHashAt(h));
        }
    }
}

test "100 blocks commit within 60 seconds" {
    var cluster = try TestCluster.init(4, alloc);
    defer cluster.deinit();

    const start = std.time.milliTimestamp();
    try cluster.runUntilHeight(100, timeout_ms: 60_000);
    const elapsed = std.time.milliTimestamp() - start;

    try std.testing.expect(elapsed < 60_000);
}
```
