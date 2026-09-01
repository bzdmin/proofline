// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {InvoiceState} from "./Types.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @title Receivable - the Ethereum source contract. Deliberately small, strictly guarded.
///
/// @notice ProofLine's central claim rests here. Attestcoin proves that this contract emitted
///         a given log in a transaction that succeeded. It does NOT prove the log's semantic
///         claim is true. Everything we want to be true must therefore be made unreachable
///         otherwise, by this contract's own require statements.
///
///         So: `InvoicePaid` cannot exist unless mUSD actually moved into escrow.
///         `InvoiceLate` cannot exist before the due date. `InvoiceDefaulted` cannot exist
///         before grace expires. The requires ARE the trust boundary, and they are tested
///         with the same seriousness as the accounting library.
///
///         Deliberately absent: no owner, no pause, no upgrade path, no credit logic. The
///         Ethereum side is dumb about credit and strict about facts.
contract Receivable {
    struct Invoice {
        address seller;
        address buyer;      // nominated at issuance; the ACTUAL payer is recorded in the event
        address token;
        uint256 amount;
        uint64  dueDate;
        uint64  paidAt;
        InvoiceState state;
    }

    /// All four events share one payload shape, in one order:
    ///   topics: [signature, id, seller, buyer]   data: (token, amount, dueDate, ts)
    /// Distinct signatures keep the log unambiguous; the uniform layout gives the ASC one
    /// decode path instead of four.
    event InvoiceIssued(uint256 indexed id, address indexed seller, address indexed buyer,
                        address token, uint256 amount, uint64 dueDate, uint64 ts);
    event InvoicePaid(uint256 indexed id, address indexed seller, address indexed buyer,
                      address token, uint256 amount, uint64 dueDate, uint64 ts);
    event InvoiceLate(uint256 indexed id, address indexed seller, address indexed buyer,
                      address token, uint256 amount, uint64 dueDate, uint64 ts);
    event InvoiceDefaulted(uint256 indexed id, address indexed seller, address indexed buyer,
                           address token, uint256 amount, uint64 dueDate, uint64 ts);

    event BuyerRegistered(address indexed buyer, uint64 ts);
    event Withdrawn(address indexed seller, address indexed token, uint256 amount);

    mapping(uint256 => Invoice) public invoices;
    mapping(address => bool) public registeredBuyer;
    mapping(address => mapping(address => uint256)) public escrowed; // seller => token => amount

    uint256 public nextInvoiceId = 1;
    uint64  public immutable GRACE;

    error AlreadyRegistered();
    error BuyerNotRegistered(address buyer);
    error BuyerIsSeller();
    error ZeroAmount();
    error DueDateInPast();
    error WrongState(InvoiceState actual);
    error SelfPayment();
    error ShortPayment(uint256 expected, uint256 received);
    error NotYetDue(uint64 dueDate, uint64 nowTs);
    error StillInGrace(uint64 graceEnds, uint64 nowTs);
    error NothingToWithdraw();

    /// GRACE is a constructor parameter: minutes on testnet so the demo can reach the
    /// default cliff in one sitting, 24h documented as the production value.
    constructor(uint64 grace) { GRACE = grace; }

    /// Buyers register THEMSELVES. If the seller could register their own counterparties the
    /// control would be a no-op wearing a state machine; self-registration at least proves an
    /// independent funded key exists behind the address, which then has to move real value.
    /// This is not Sybil resistance and the documentation says so.
    function registerAsBuyer() external {
        if (registeredBuyer[msg.sender]) revert AlreadyRegistered();
        registeredBuyer[msg.sender] = true;
        emit BuyerRegistered(msg.sender, uint64(block.timestamp));
    }

    function issueInvoice(address buyer, address token, uint256 amount, uint64 dueDate)
        external returns (uint256 id)
    {
        if (!registeredBuyer[buyer]) revert BuyerNotRegistered(buyer);
        if (buyer == msg.sender)     revert BuyerIsSeller();
        if (amount == 0)             revert ZeroAmount();
        if (dueDate <= block.timestamp) revert DueDateInPast();

        id = nextInvoiceId++;
        invoices[id] = Invoice({
            seller: msg.sender, buyer: buyer, token: token, amount: amount,
            dueDate: dueDate, paidAt: 0, state: InvoiceState.Open
        });

        emit InvoiceIssued(id, msg.sender, buyer, token, amount, dueDate, uint64(block.timestamp));
    }

    /// The event is strictly downstream of a successful transfer, and the amount asserted is
    /// the amount this contract actually received - measured, not taken from a return value.
    /// A fee-on-transfer token returns true while delivering less; that is exactly the class
    /// of thing this check exists to catch.
    function payInvoice(uint256 id) external {
        Invoice storage inv = invoices[id];
        if (inv.state != InvoiceState.Open && inv.state != InvoiceState.Late) {
            revert WrongState(inv.state);
        }
        if (msg.sender == inv.seller) revert SelfPayment();

        uint256 before = IERC20(inv.token).balanceOf(address(this));
        IERC20(inv.token).transferFrom(msg.sender, address(this), inv.amount);
        uint256 received = IERC20(inv.token).balanceOf(address(this)) - before;
        if (received != inv.amount) revert ShortPayment(inv.amount, received);

        inv.state = InvoiceState.Paid;
        inv.paidAt = uint64(block.timestamp);
        escrowed[inv.seller][inv.token] += received;

        // The counterparty recorded is msg.sender - whoever actually moved the money - not
        // the nominated buyer. Both remain recoverable from the log: nominated at issuance,
        // actual at settlement.
        emit InvoicePaid(id, inv.seller, msg.sender, inv.token, received, inv.dueDate, inv.paidAt);
    }

    /// Permissionless. Anyone may poke it, including our own worker. The contract makes a
    /// false emission impossible: the temporal fact is enforced here, so Attestcoin proving
    /// this log means the state was genuinely reached.
    function markLate(uint256 id) external {
        Invoice storage inv = invoices[id];
        if (inv.state != InvoiceState.Open) revert WrongState(inv.state);
        if (block.timestamp <= inv.dueDate) revert NotYetDue(inv.dueDate, uint64(block.timestamp));

        inv.state = InvoiceState.Late;
        emit InvoiceLate(id, inv.seller, inv.buyer, inv.token, inv.amount, inv.dueDate,
                         uint64(block.timestamp));
    }

    /// Permissionless, and reachable from Open or Late: an invoice can blow past grace
    /// without anyone having bothered to mark it late first.
    function markDefault(uint256 id) external {
        Invoice storage inv = invoices[id];
        if (inv.state != InvoiceState.Open && inv.state != InvoiceState.Late) {
            revert WrongState(inv.state);
        }
        uint64 graceEnds = inv.dueDate + GRACE;
        if (block.timestamp <= graceEnds) revert StillInGrace(graceEnds, uint64(block.timestamp));

        inv.state = InvoiceState.Defaulted;
        emit InvoiceDefaulted(id, inv.seller, inv.buyer, inv.token, inv.amount, inv.dueDate,
                              uint64(block.timestamp));
    }

    function withdraw(address token) external {
        uint256 amount = escrowed[msg.sender][token];
        if (amount == 0) revert NothingToWithdraw();
        escrowed[msg.sender][token] = 0;
        IERC20(token).transfer(msg.sender, amount);
        emit Withdrawn(msg.sender, token, amount);
    }

    function stateOf(uint256 id) external view returns (InvoiceState) { return invoices[id].state; }
}
