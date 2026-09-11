// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title NetTermsDesk - a third application, added after the fact.
///
/// @notice Trade credit from a supplier: how many days a business may take to pay for
///         inventory, decided from its verified sales history.
///
///         It was written and deployed ten days after CreditFile, from an address with no role
///         in any ProofLine contract, and nothing in CreditFile changed to allow it. That is
///         the reusability claim done rather than stated.
///
///         It imports nothing from ProofLine. It declares the return shape of the public
///         getCreditFile() itself, as any third party holding only the ABI would, and applies
///         its own policy to the raw file. ProofLine's tiers and rates play no part: the
///         credit file is the shared input, the judgment stays with the application.
contract NetTermsDesk {
    /// The return shape of CreditFile.getCreditFile, copied from its public ABI.
    struct RawFile {
        uint32  settled;
        uint32  onTime;
        uint32  defaults;
        uint32  openDelinquencies;
        uint32  counterparties;
        uint256 verifiedVolume;
        uint256 outstandingReceivables;
        uint256 maxSettledAmount;
        uint256 currentLimit;
        uint64  lastUpdated;
    }

    ICreditFileReader public immutable creditFile;

    /// Net 60 also needs this much verified sales volume, in mUSD base units (6 decimals).
    uint256 public constant NET60_MIN_VOLUME = 40_000e6;

    struct Decision { uint16 netDays; uint64 decidedAt; }
    mapping(address => Decision) public lastDecision;

    event TermsDecided(address indexed business, uint16 netDays, uint32 settled,
                       uint32 counterparties, uint256 verifiedVolume, string basis);

    constructor(ICreditFileReader _creditFile) { creditFile = _creditFile; }

    /// Payment terms this desk would offer now, and why.
    function quote(address business) public view returns (uint16 netDays, string memory basis) {
        return _policy(creditFile.getCreditFile(business));
    }

    /// One transaction, callable by anyone: read the file, decide, record.
    function decide(address business) external returns (uint16 netDays) {
        RawFile memory f = creditFile.getCreditFile(business);
        string memory basis;
        (netDays, basis) = _policy(f);
        lastDecision[business] = Decision(netDays, uint64(block.timestamp));
        emit TermsDecided(business, netDays, f.settled, f.counterparties, f.verifiedVolume, basis);
    }

    /// This desk's own rules. Worst facts first, then the best rung down.
    function _policy(RawFile memory f) internal pure returns (uint16, string memory) {
        if (f.defaults > 0)          return (0, "verified default: cash in advance");
        if (f.openDelinquencies > 0) return (0, "open delinquency: cash in advance");
        if (f.settled >= 5 && f.counterparties >= 3 && f.verifiedVolume >= NET60_MIN_VOLUME)
            return (60, "net 60");
        if (f.settled >= 3 && f.counterparties >= 2) return (30, "net 30");
        return (0, "thin file: cash in advance");
    }
}

interface ICreditFileReader {
    function getCreditFile(address business) external view returns (NetTermsDesk.RawFile memory);
}
