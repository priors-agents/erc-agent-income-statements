// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IChainHistory} from "../../src/IChainHistory.sol";

/// A recorded chain for one agent of one identity registry: block times on a fixed 12-second clock, the agent's
/// owner and wallet changes at log positions, and Transfer logs of any asset. Everything is added in log order.
contract MockChainHistory is IChainHistory {
    struct Change {
        uint64 blockNumber;
        uint32 logIndex;
        bool isOwner; // an ERC-721 Transfer of the agent; otherwise a MetadataSet for agentWallet
        address value; // the new owner or wallet
        bool logged; // false: a change the registry made without emitting its log
    }

    struct AssetLog {
        address asset;
        TransferLog log;
    }

    address public immutable registry;
    uint256 public immutable agentId;
    uint64 public immutable firstBlock;
    uint64 public immutable firstTime;

    Change[] internal _changes;
    AssetLog[] internal _transfers;
    mapping(address => uint64) internal _lastIndex; // getLastIndex(agentId, client) on the Reputation Registry

    constructor(address registry_, uint256 agentId_, uint64 firstBlock_, uint64 firstTime_) {
        registry = registry_;
        agentId = agentId_;
        firstBlock = firstBlock_;
        firstTime = firstTime_;
    }

    function setOwner(uint64 b, uint32 l, address owner) external {
        _changes.push(Change(b, l, true, owner, true));
    }

    function setWallet(uint64 b, uint32 l, address wallet) external {
        _changes.push(Change(b, l, false, wallet, true));
    }

    /// A wallet change with no MetadataSet log: what a registry outside this profile could do.
    function setWalletWithoutLog(uint64 b, uint32 l, address wallet) external {
        _changes.push(Change(b, l, false, wallet, false));
    }

    function setLastIndex(address client, uint64 n) external {
        _lastIndex[client] = n;
    }

    function lastIndex(address, uint256 id, address client) external view returns (uint64) {
        return id == agentId ? _lastIndex[client] : 0;
    }

    function addTransfer(address asset, uint64 b, uint32 l, bytes32 txHash, address from, address to, uint256 value)
        external
    {
        _transfers.push(AssetLog(asset, TransferLog(b, l, txHash, from, to, value)));
    }

    function blockTime(uint64 b) external view returns (uint64) {
        return b >= firstBlock ? firstTime + 12 * (b - firstBlock) : firstTime - 12 * (firstBlock - b);
    }

    function ownerAt(address reg, uint256 id, uint64 b) external view returns (address owner) {
        if (reg != registry || id != agentId) return address(0);
        for (uint256 i; i < _changes.length && _changes[i].blockNumber <= b; ++i) {
            if (_changes[i].isOwner) owner = _changes[i].value;
        }
    }

    function walletAt(address reg, uint256 id, uint64 b) external view returns (address wallet) {
        if (reg != registry || id != agentId) return address(0);
        for (uint256 i; i < _changes.length && _changes[i].blockNumber <= b; ++i) {
            if (!_changes[i].isOwner) wallet = _changes[i].value;
        }
    }

    function changeLogs(address reg, uint256 id, uint64 fromBlock, uint64 toBlock)
        external
        view
        returns (ChangeLog[] memory out)
    {
        if (reg != registry || id != agentId) return out;
        uint256 n;
        for (uint256 i; i < _changes.length; ++i) {
            if (_inRange(_changes[i], fromBlock, toBlock)) ++n;
        }
        out = new ChangeLog[](n);
        n = 0;
        for (uint256 i; i < _changes.length; ++i) {
            Change memory c = _changes[i];
            if (_inRange(c, fromBlock, toBlock)) out[n++] = ChangeLog(c.blockNumber, c.logIndex);
        }
    }

    function transferLogs(address asset, address to, uint64 fromBlock, uint64 toBlock)
        external
        view
        returns (TransferLog[] memory out)
    {
        uint256 n;
        for (uint256 i; i < _transfers.length; ++i) {
            if (_match(_transfers[i], asset, to, fromBlock, toBlock)) ++n;
        }
        out = new TransferLog[](n);
        n = 0;
        for (uint256 i; i < _transfers.length; ++i) {
            if (_match(_transfers[i], asset, to, fromBlock, toBlock)) out[n++] = _transfers[i].log;
        }
    }

    function transferLog(address asset, uint64 b, uint32 l) external view returns (bool found, TransferLog memory log) {
        for (uint256 i; i < _transfers.length; ++i) {
            AssetLog memory t = _transfers[i];
            if (t.asset == asset && t.log.blockNumber == b && t.log.logIndex == l) return (true, t.log);
        }
    }

    function _inRange(Change memory c, uint64 fromBlock, uint64 toBlock) private pure returns (bool) {
        return c.logged && c.blockNumber >= fromBlock && c.blockNumber <= toBlock;
    }

    function _match(AssetLog memory t, address asset, address to, uint64 fromBlock, uint64 toBlock)
        private
        pure
        returns (bool)
    {
        return t.asset == asset && t.log.to == to && t.log.blockNumber >= fromBlock && t.log.blockNumber <= toBlock;
    }
}

/// An ERC-20's `decimals()` and nothing else.
contract MockDecimals {
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }
}

/// A contract with no `decimals()`.
contract NoDecimals {}
