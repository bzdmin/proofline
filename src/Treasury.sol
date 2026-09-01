// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Terms} from "./Types.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface ITermsSource {
    function getTermsWithDebt(address borrower, uint256 debt) external view returns (Terms memory);
}

/// @title Treasury - CONSUMER ONE of the credit primitive.
///
/// @notice Working capital lent against terms it does not compute. Treasury holds capital,
///         tracks its own exposure, and asks CreditFile what a borrower may draw. It contains
///         no tier logic, no scoring, and no copy of the underwriting formula: if the policy
///         changes, Treasury does not.
///
///         Deliberately absent: no shares, no NAV, no ERC-4626, no utilisation curve, no
///         interest-rate model. Single funder, simple interest. The lending mechanics are not
///         the interesting part of this project and are kept small on purpose.
contract Treasury {
    IERC20 public immutable asset;
    ITermsSource public immutable creditFile;
    address public immutable funder;

    struct Loan {
        uint256 principal;   // includes interest accrued at the last touch
        uint64  since;       // when interest last started accruing
        uint16  aprBps;      // rate fixed at draw time, from the terms then in force
    }

    mapping(address => Loan) public loans;
    uint256 public totalPrincipal;

    uint256 private constant YEAR = 365 days;

    event Funded(address indexed funder, uint256 amount);
    event Borrowed(address indexed borrower, uint256 amount, uint16 aprBps, uint256 newDebt);
    event Repaid(address indexed borrower, uint256 amount, uint256 remainingDebt);

    error NotFunder();
    error ZeroAmount();
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error ExceedsDrawable(uint256 requested, uint256 drawable);
    error NoDebt();

    constructor(IERC20 _asset, ITermsSource _creditFile, address _funder) {
        asset = _asset;
        creditFile = _creditFile;
        funder = _funder;
    }

    function fund(uint256 amount) external {
        if (msg.sender != funder) revert NotFunder();
        if (amount == 0) revert ZeroAmount();
        asset.transferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    function available() public view returns (uint256) { return asset.balanceOf(address(this)); }

    /// Principal plus simple interest since the last touch, at the rate fixed when drawn.
    function debtOf(address borrower) public view returns (uint256) {
        Loan memory l = loans[borrower];
        if (l.principal == 0) return 0;
        uint256 elapsed = block.timestamp - l.since;
        return l.principal + (l.principal * l.aprBps * elapsed) / (10_000 * YEAR);
    }

    /// Terms are read live, with this Treasury's own exposure reported in. A tier that
    /// dropped since the last draw is enforced at the moment of the next one.
    function borrow(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        uint256 debt = debtOf(msg.sender);
        Terms memory t = creditFile.getTermsWithDebt(msg.sender, debt);

        if (amount > t.drawable) revert ExceedsDrawable(amount, t.drawable);
        uint256 liquid = available();
        if (amount > liquid) revert InsufficientLiquidity(amount, liquid);

        // Fold accrued interest into principal, then restart the clock at the current rate.
        loans[msg.sender] = Loan({
            principal: debt + amount,
            since: uint64(block.timestamp),
            aprBps: t.aprBps
        });
        totalPrincipal = totalPrincipal + amount;

        asset.transfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount, t.aprBps, debt + amount);
    }

    /// Repay any amount up to the outstanding debt. Overpayment is clamped rather than
    /// refunded, so a borrower cannot accidentally donate to the treasury.
    function repay(uint256 amount) external {
        uint256 debt = debtOf(msg.sender);
        if (debt == 0) revert NoDebt();
        if (amount == 0) revert ZeroAmount();

        uint256 paid = amount > debt ? debt : amount;
        asset.transferFrom(msg.sender, address(this), paid);

        uint256 remaining = debt - paid;
        if (remaining == 0) {
            delete loans[msg.sender];
        } else {
            loans[msg.sender] = Loan({
                principal: remaining,
                since: uint64(block.timestamp),
                aprBps: loans[msg.sender].aprBps
            });
        }
        totalPrincipal = totalPrincipal > paid ? totalPrincipal - paid : 0;
        emit Repaid(msg.sender, paid, remaining);
    }
}
