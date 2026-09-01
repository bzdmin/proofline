// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Tier, Terms} from "./Types.sol";

interface ITierSource {
    function getTerms(address borrower) external view returns (Terms memory);
}

/// @title CreditAccess - CONSUMER TWO of the credit primitive.
///
/// @notice A security-deposit policy for service agreements. It is not a lending product and
///         has nothing to do with invoices, and that is the entire point of its existence:
///
///             one CreditFile  ->  Treasury (working capital)
///                             ->  CreditAccess (deposit requirement)
///
///         Two independent applications consuming the same proof-backed credit state, neither
///         knowing the other exists. "Reusable primitive" is otherwise just a claim on a
///         slide; this contract is what makes it checkable.
///
///         It reads `tier` and nothing else. Not drawable, not limit, not debt - because
///         those are lending concepts, and touching them would couple this contract to
///         Treasury through the back door and quietly weaken the demonstration.
///
///         Deliberately boring. If it needed to be clever it would not be evidence.
contract CreditAccess {
    ITierSource public immutable creditFile;

    /// Deposit required as a fraction of the agreement value, in basis points.
    /// A worse credit standing means more money up front.
    uint16 public constant DEPOSIT_NEW      = 10_000; // 100%
    uint16 public constant DEPOSIT_STANDARD =  7_500; //  75%
    uint16 public constant DEPOSIT_GOOD     =  4_000; //  40%
    uint16 public constant DEPOSIT_TRUSTED  =      0; //   0%
    uint16 public constant DEPOSIT_WATCH    = 10_000; // 100%

    struct Agreement {
        address provider;
        address client;
        uint256 value;
        uint256 depositPaid;
        bool    open;
    }

    mapping(uint256 => Agreement) public agreements;
    uint256 public nextAgreementId = 1;

    event AgreementOpened(uint256 indexed id, address indexed client, address indexed provider,
                          uint256 value, Tier tier, uint16 depositBps, uint256 depositRequired);

    error FrozenCreditCannotContract(address client);
    error WrongDeposit(uint256 required, uint256 sent);

    constructor(ITierSource _creditFile) { creditFile = _creditFile; }

    /// The whole consumer surface: tier in, deposit requirement out.
    function requiredDepositBps(address client) public view returns (uint16) {
        Tier t = creditFile.getTerms(client).tier;
        if (t == Tier.TRUSTED)  return DEPOSIT_TRUSTED;
        if (t == Tier.GOOD)     return DEPOSIT_GOOD;
        if (t == Tier.STANDARD) return DEPOSIT_STANDARD;
        if (t == Tier.WATCH)    return DEPOSIT_WATCH;
        return DEPOSIT_NEW;     // NEW, and FROZEN is refused outright below
    }

    function requiredDeposit(address client, uint256 value) public view returns (uint256) {
        return (value * requiredDepositBps(client)) / 10_000;
    }

    /// A frozen borrower cannot open an agreement at all - the same proven default that
    /// stops them borrowing also stops them contracting here, through no shared code.
    function openAgreement(address provider, uint256 value) external payable returns (uint256 id) {
        Tier t = creditFile.getTerms(msg.sender).tier;
        if (t == Tier.FROZEN) revert FrozenCreditCannotContract(msg.sender);

        uint256 required = (value * requiredDepositBps(msg.sender)) / 10_000;
        if (msg.value != required) revert WrongDeposit(required, msg.value);

        id = nextAgreementId++;
        agreements[id] = Agreement({
            provider: provider, client: msg.sender, value: value,
            depositPaid: msg.value, open: true
        });

        emit AgreementOpened(id, msg.sender, provider, value, t, requiredDepositBps(msg.sender), required);
    }
}
