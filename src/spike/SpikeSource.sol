// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title SpikeSource — throwaway G0-A source contract for Ethereum Sepolia.
/// @notice Deliberately minimal. Shares NO code with Receivable.sol. Its only job is
///         to emit provable logs in the shapes G0-A needs, including the awkward ones.
contract SpikeSource {
    /// keccak256("SpikePing(uint256,address,uint256)")
    event SpikePing(uint256 indexed id, address indexed who, uint256 amount);

    uint256 public nextId = 1;

    /// Q1/Q2/Q3: one transaction, one log. The happy path.
    function ping(uint256 amount) external returns (uint256 id) {
        id = nextId++;
        emit SpikePing(id, msg.sender, amount);
    }

    /// Q6: one transaction, MANY logs. The official replay key is per-transaction,
    /// so this proves whether a single submission fans out to N credit events.
    function pingBatch(uint256 n) external {
        for (uint256 i = 0; i < n; i++) {
            emit SpikePing(nextId++, msg.sender, 1000 + i);
        }
    }

    /// Q7: emits, then reverts. The transaction is still mined, with receiptStatus 0.
    /// Tells us whether gate `receiptStatus == 1` fires, or whether the logs are simply
    /// absent and a different require trips first. Either answer is a finding.
    function pingThenRevert(uint256 amount) external {
        emit SpikePing(nextId, msg.sender, amount);
        revert("spike: deliberate revert after emit");
    }
}

/// @notice Q5: an identical event from an address that is NOT the authorized source.
///         Same signature, same shape, different emitter. Must be rejected.
contract SpikeImposter {
    event SpikePing(uint256 indexed id, address indexed who, uint256 amount);

    function ping(uint256 id, uint256 amount) external {
        emit SpikePing(id, msg.sender, amount);
    }
}
