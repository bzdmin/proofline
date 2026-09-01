// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Minimal mintable ERC-20 standing in for mUSD. 6 decimals, open mint - buyers fund
/// themselves, which is why we deploy our own rather than chase a testnet USDC faucet
/// across four addresses.
contract MockERC20 {
    string public name = "Mock USD";
    string public symbol = "mUSD";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Delivers less than requested while returning true. This is the exact class of token the
/// balance-delta assertion in Receivable.payInvoice exists to catch - and the reason we
/// measure what arrived instead of trusting the return value.
contract FeeOnTransferERC20 is MockERC20 {
    uint256 public feeBps = 100; // 1%

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        uint256 fee = (amount * feeBps) / 10_000;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;   // silently short
        return true;
    }
}

/// Returns true without moving anything at all. The pathological case.
contract LyingERC20 is MockERC20 {
    function transferFrom(address, address, uint256) external pure override returns (bool) {
        return true;
    }
}
