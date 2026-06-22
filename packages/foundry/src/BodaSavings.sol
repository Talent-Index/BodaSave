// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20}          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit}    from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20Metadata}  from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20}       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable}         from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step}    from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable}        from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title  BodaBodaSavings  (v4.1)
/// @author Team
/// @notice Savings + loan-repayment platform for bodaboda riders in Kenya.
///
///         WHERE THE MONEY LIVES
///         ─────────────────────
///         All USDC/USDT deposited sits in THIS contract's balance as a single
///         commingled pool. Per-rider struct fields are the ledger that tracks
///         each rider's claim on that pool:
///           • savingsBalance — rider's withdrawable savings (in the pool)
///           • loanBalance    — accumulated loan-portion awaiting the next scheduled
///                              settlement (in the pool)
///         When a settlement fires, the loan-portion leaves the pool to the lender.
///
///         SOLVENCY INVARIANT (must always hold):
///           stablecoin.balanceOf(this) >= totalSavingsHeld + totalUnsettledLoanBalance
///
///         CORE FLOW
///         ─────────
///         1. Owner registers verified lenders (deployment or addLender()).
///         2. Rider self-registers: identity + lender choice + split ratio
///            (off-chain KYC pre-approved; owner controls the on-chain KYC hash).
///         3. Rider deposits via deposit() or depositWithPermit() (on-chain wallet),
///            OR an off-chain fiat payment (M-Pesa via IntaSend) is relayed on-chain
///            via creditDeposit() [V4.1-1]. Either path is split by the rider's
///            SplitRatio into savings vs loan portions, identically.
///         4. The loan-portion accumulates in loanBalance. On the lender's collection
///            cadence, settleLoanRepayment() sweeps it to the lender. There is NO
///            manual lock/release — settlement is scheduled and passive.
///         5. Rider withdraws savings: requestWithdrawal() → (auto- or owner-approval)
///            → WITHDRAWAL_DELAY elapses → claimWithdrawal().
///
/// @dev    v4.1 CHANGES (on top of v4's V4-1…V4-7 and SEC-A…SEC-C)
///         ───────────────────────────────────────────────────────────────
///         [V4.1-1] creditDeposit(rider, amount) — a relayer-only entry point that
///                  applies the SAME split/rounding/loan-cleared logic as a normal
///                  deposit, but pulls stablecoin FROM THE RELAYER rather than from
///                  the rider, and credits an explicit rider address rather than
///                  msg.sender. This is the on-chain leg of the off-chain fiat rail
///                  (M-Pesa via IntaSend): the backend converts a completed M-Pesa
///                  payment into testnet USDC and calls this on the rider's behalf
///                  once the rider's identity has been correlated off-chain.
///                  It is NOT a mint — the relayer must actually hold and transfer
///                  real (testnet) stablecoin, so the solvency invariant is preserved
///                  with no special-casing.
///         [V4.1-2] RELAYER ROLE — a single privileged address, separate from owner,
///                  settable only by the owner. Deliberately narrow: the relayer can
///                  ONLY call creditDeposit(), nothing else. This means a compromised
///                  always-online backend key cannot pause the contract, rewrite KYC,
///                  swap the stablecoin, or touch any other privileged path — only
///                  credit deposits, and only with stablecoin it actually transfers.
///
///         v4 CHANGES (on top of the v3.1 audit remediation AUD-1…AUD-5) — unchanged
///         from the prior version, retained here for context:
///         [V4-1]  POT MECHANISM REMOVED, replaced by scheduled auto-settlement.
///         [V4-2]  DYNAMIC SETTLEMENT DUE DATE, read at check time.
///         [V4-3]  LOAN-CLEARED ROUTING — surplus over target flows to savings.
///         [V4-4]  MUTABLE SPLIT RATIO via updateSplitRatio().
///         [V4-5]  TIERED WITHDRAWAL APPROVAL with owner revocation window.
///         [V4-6]  SPLIT ROUNDING ACCUMULATOR — remainder carries per rider.
///         [V4-7]  SOLVENCY AGGREGATES backing isSolvent()/getTotalObligations().
///
///         SECURITY HARDENING (beyond the agreed feature scope)
///         ─────────────────────────────────────────────────────
///         [SEC-A] Ownable2Step — two-step ownership transfer.
///         [SEC-B] Fee-on-transfer / rebasing safe deposits — credits the ACTUAL
///                 balance delta, never the requested amount. Applies to
///                 creditDeposit() too [V4.1-1].
///         [SEC-C] CEI + nonReentrant on every value-moving path.

contract BodaBodaSavings is Ownable2Step, Pausable, ReentrancyGuard {

    using SafeERC20 for IERC20;   // [AUD-1]

    // ================================================================
    //                         CONSTANTS
    // ================================================================

    /// @dev 150 seconds for demo. Set to e.g. 172_800 (48 h) for production.
    uint256 public constant WITHDRAWAL_DELAY = 150;

    // ── Withdrawal reason categories ──────────────────────────────────
    bytes32 public constant REASON_MEDICAL           = "MEDICAL";
    bytes32 public constant REASON_REPAIR            = "REPAIR";
    bytes32 public constant REASON_EDUCATION         = "EDUCATION";
    bytes32 public constant REASON_HOUSEHOLD         = "HOUSEHOLD";
    bytes32 public constant REASON_EMERGENCY         = "EMERGENCY";
    bytes32 public constant REASON_FAMILY_OBLIGATION = "FAMILY_OBLIGATION";
    bytes32 public constant REASON_OTHER             = "OTHER";

    // ── KYC verification levels ───────────────────────────────────────
    uint8 public constant KYC_BASIC   = 1;
    uint8 public constant KYC_FULL    = 2;
    uint8 public constant KYC_PREMIUM = 3;

    // ================================================================
    //                       CUSTOM ERRORS
    // ================================================================

    // — Stablecoin —
    error BodaBodaSavings__StablecoinCannotBeZeroAddress();
    error BodaBodaSavings__InvalidStablecoinContract();
    error BodaBodaSavings__CannotRecoverStablecoin();
    error BodaBodaSavings__ZeroAddressToken();
    error BodaBodaSavings__ContractBalanceMustBeZero();
    error BodaBodaSavings__OutstandingAccounting();     // [AUD-4]
    error BodaBodaSavings__DecimalsMismatch();          // [AUD-4]

    // — General —
    error BodaBodaSavings__ZeroAddress();
    error BodaBodaSavings__ZeroAmount();
    error BodaBodaSavings__ArrayLengthMismatch();        // [V4]

    // — Lender —
    error BodaBodaSavings__LenderAlreadyRegistered();
    error BodaBodaSavings__LenderNotFound();
    error BodaBodaSavings__LenderNotActive();
    error BodaBodaSavings__InvalidCollectionCycle();
    error BodaBodaSavings__NoLendersProvided();

    // — Rider —
    error BodaBodaSavings__RiderAlreadyRegistered();
    error BodaBodaSavings__RiderNotRegistered();
    error BodaBodaSavings__RiderNotVerified();
    error BodaBodaSavings__ZeroLoanTarget();
    error BodaBodaSavings__InvalidVerificationHash();
    error BodaBodaSavings__InvalidKycLevel();
    error BodaBodaSavings__LicenseExpired();

    // — Identity [ID-1] —
    error BodaBodaSavings__NameRequired();
    error BodaBodaSavings__InvalidAge();          // must be 18–65
    error BodaBodaSavings__InvalidGender();       // must be 'M', 'F', or 'O'

    // — Deposit / Savings —
    error BodaBodaSavings__ZeroDeposit();
    error BodaBodaSavings__NothingReceived();     // [SEC-B] balance delta was 0
    error BodaBodaSavings__InsufficientSavings();

    // — Loan / Settlement —
    error BodaBodaSavings__InvalidSplitRatio();         // [AUD-5]
    error BodaBodaSavings__SettlementNotDue();          // [V4-1]

    // — Withdrawal —
    error BodaBodaSavings__ZeroWithdrawAmount();
    error BodaBodaSavings__WithdrawalAlreadyPending();
    error BodaBodaSavings__NoWithdrawalPending();
    error BodaBodaSavings__WithdrawalNotApproved();
    error BodaBodaSavings__WithdrawalDelayNotMet();
    error BodaBodaSavings__InvalidWithdrawalCategory();
    error BodaBodaSavings__NoWithdrawalToCancel();      // [AUD-3]

    // — Loan restructure —
    error BodaBodaSavings__NewTargetBelowRepaid();

    // — Relayer [V4.1-2] —
    error BodaBodaSavings__NotRelayer();
    error BodaBodaSavings__RelayerCannotBeZeroAddress();

    // ================================================================
    //                           ENUMS
    // ================================================================

    enum WithdrawalStatus {
        None,
        Pending,
        Approved
    }

    /// @notice How a rider's deposit is split between savings and loan repayment. [ID-2]
    enum SplitRatio {
        SPLIT_70_30,   // 70 % savings | 30 % loan
        SPLIT_60_40,   // 60 % savings | 40 % loan
        SPLIT_50_50,   // 50 % savings | 50 % loan
        SPLIT_40_60,   // 40 % savings | 60 % loan
        SPLIT_30_70    // 30 % savings | 70 % loan
    }

    /// @notice Lender's preferred repayment collection frequency. [ID-3]
    enum RepaymentSchedule {
        WEEKLY,
        BIWEEKLY,
        MONTHLY
    }

    // ================================================================
    //                          STRUCTS
    // ================================================================

    /// @notice On-chain lender record.
    struct Lender {
        string            name;
        address           lenderAddress;
        uint256           collectionCycle;   // seconds between scheduled settlements
        RepaymentSchedule schedule;          // [ID-3]
        bool              verified;
        bool              active;
    }

    /// @notice Off-chain KYC record stored on-chain for audit trail.
    struct RiderKYC {
        bytes32 verificationHash;
        uint8   verificationLevel;
        bool    verified;
        uint256 verifiedAt;
        uint256 licenseExpiry;
        bytes32 kycProvider;
    }

    /// @notice Full rider state — identity + financials.
    /// @dev    [V4-1] pot fields removed; lastSettledAt drives scheduled settlement.
    ///         [V4-6] savingsRemainder carries the split rounding remainder (0..99).
    struct Rider {
        // ── Identity [ID-1] ──
        string     name;
        bytes1     gender;             // 'M' | 'F' | 'O'

        // ── Lender + Split ──
        address    lenderAddress;
        SplitRatio splitRatio;         // [ID-2] mutable via updateSplitRatio [V4-4]

        // ── Loan (repayment side) ──
        uint256    loanTarget;
        uint256    loanBalance;        // accumulated, awaiting scheduled settlement
        uint256    loanRepaid;

        // ── Savings (personal side) ──
        uint256    savingsBalance;
        uint256    totalDeposited;
        uint256    totalWithdrawn;
        uint256    withdrawalCount;
        uint256    lastDepositAt;
        uint256    firstDepositAt;

        // ── Settlement scheduling [V4-1] ──
        uint256    lastSettledAt;      // set at registration; advanced each settlement

        // ── Split rounding carry [V4-6] ──
        uint256    savingsRemainder;   // 0..99, redistributes rounding over time

        // ── Packed ──
        uint8      age;
        bool       registered;
    }

    struct WithdrawalRequest {
        uint256          amount;
        bytes32          category;
        uint256          requestedAt;
        uint256          approvedAt;
        WithdrawalStatus status;
    }

    struct WithdrawalRecord {
        uint256 amount;
        bytes32 category;
        uint256 requestedAt;
        uint256 claimedAt;
    }

    /// @notice A single scheduled loan-repayment settlement. [V4-1] (was PotRecord)
    struct RepaymentRecord {
        uint256 amount;
        uint256 settledAt;
        bool    autoTriggered;   // true if triggered by a keeper / 3rd party
    }

    /// @dev Read-only aggregate of a rider's identity + lender info, returned by
    ///      getRiderProfile(). A single memory struct (named fields, no fragile
    ///      positional tuple) — also sidesteps stack-too-deep on the wide return.
    struct RiderProfileView {
        string            name;
        uint8             age;
        bytes1            gender;
        bool              registered;
        address           lenderAddress;
        string            lenderName;
        RepaymentSchedule lenderSchedule;
        SplitRatio        splitRatio;
        uint256           loanTarget;
    }

    /// @dev Read-only financial dashboard snapshot, returned by getRiderAnalytics().
    struct RiderAnalyticsView {
        uint256 savingsBalance;
        uint256 loanBalance;
        uint256 totalDeposited;
        uint256 totalWithdrawn;
        uint256 withdrawalCount;
        uint256 lastDepositAt;
        uint256 firstDepositAt;
        uint256 loanRepaid;
        uint256 lastSettledAt;
        uint256 nextSettlementDue;
    }

    // ================================================================
    //                       STATE VARIABLES
    // ================================================================

    IERC20 public stablecoin;

    mapping(address => Lender)            public lenders;
    address[]                             public lenderList;

    /// @dev internal (not public): the auto-generated getter for the 17-field Rider
    ///      struct overflows the legacy codegen stack. Exposed via getRider() and the
    ///      purpose-built views (getRiderProfile / getRiderAnalytics / getLoanStatus).
    mapping(address => Rider)             internal riders;
    mapping(address => RiderKYC)          public riderKYC;
    mapping(address => WithdrawalRequest) public withdrawalRequests;

    mapping(address => WithdrawalRecord[]) private _withdrawalHistory;
    mapping(address => RepaymentRecord[])  private _repaymentHistory;

    /// @dev O(1) category lookup — populated once in constructor
    mapping(bytes32 => bool) private _validCategories;

    // ── Solvency aggregates [V4-7] ──
    /// @dev Sum of all riders' loanBalance currently held (unsettled).
    uint256 public totalUnsettledLoanBalance;
    /// @dev Cumulative amount swept to lenders across all settlements.
    uint256 public totalLoanSettled;
    /// @dev Sum of all savings held by the contract, INCLUDING amounts parked in
    ///      pending/approved withdrawal requests (still in the pool until claimed).
    uint256 public totalSavingsHeld;

    /// @dev [V4-5] Withdrawals at or below this auto-approve. DEV PLACEHOLDER value.
    uint256 public autoApprovalThreshold = 50e6; // ~50 USDC (6-decimal) dummy

    /// @dev [V4.1-2] The single address permitted to call creditDeposit(). Settable
    ///      only by owner. address(0) means "no relayer configured" — creditDeposit
    ///      is unreachable in that state, which is the safe default before this is
    ///      explicitly wired up.
    address public relayer;

    // ================================================================
    //                           EVENTS
    // ================================================================

    event LenderAdded(
        address indexed lenderAddress,
        string name,
        uint256 collectionCycle,
        RepaymentSchedule schedule
    );
    event LenderDeactivated(address indexed lenderAddress);
    event LenderReactivated(address indexed lenderAddress);
    event LenderCycleUpdated(address indexed lenderAddress, uint256 newCycle);

    event RiderRegistered(
        address indexed rider,
        string  name,
        address indexed lender,
        uint256 loanTarget,
        uint8   kycLevel,
        SplitRatio splitRatio
    );
    event RiderKYCUpdated(address indexed rider, uint8 newLevel);
    event LoanTargetUpdated(address indexed rider, uint256 oldTarget, uint256 newTarget);
    event SplitRatioUpdated(address indexed rider, SplitRatio oldRatio, SplitRatio newRatio); // [V4-4]

    event Deposit(
        address indexed rider,
        uint256 totalAmount,
        uint256 savingsPart,
        uint256 loanPart,
        uint256 timestamp
    );

    /// @notice [V4.1-1] Emitted for deposits credited via the relayer rather than a
    ///         direct wallet deposit. Carries the relayer address so off-chain
    ///         reconciliation can distinguish the fiat-rail path from on-chain deposits
    ///         without re-deriving it from msg.sender on the Deposit event (which is
    ///         the relayer for this path, not the rider).
    event DepositCredited(
        address indexed rider,
        address indexed relayer,
        uint256 totalAmount,
        uint256 savingsPart,
        uint256 loanPart,
        uint256 timestamp
    );

    event RelayerUpdated(address indexed oldRelayer, address indexed newRelayer); // [V4.1-2]

    event LoanRepaymentSettled(                 // [V4-1]
        address indexed rider,
        address indexed lender,
        uint256 amount,
        uint256 settledAt,
        bool    autoTriggered
    );
    event LoanExcessToSavings(address indexed rider, uint256 excess); // [V4-3]
    event LoanCleared(address indexed rider, uint256 totalRepaid, uint256 clearedAt);

    event WithdrawalRequested(
        address indexed rider,
        uint256 amount,
        bytes32 category,
        uint256 requestedAt,
        bool    autoApproved                    // [V4-5]
    );
    event WithdrawalApproved(address indexed rider, uint256 amount, uint256 approvedAt);
    event WithdrawalDenied(address indexed rider, uint256 amount, uint256 deniedAt);
    event WithdrawalCancelled(address indexed rider, uint256 amount, uint256 cancelledAt); // [AUD-3]
    event WithdrawalClaimed(address indexed rider, uint256 amount, uint256 claimedAt);

    event AutoApprovalThresholdUpdated(uint256 oldThreshold, uint256 newThreshold); // [V4-5]
    event StablecoinUpdated(address indexed oldStablecoin, address indexed newStablecoin);
    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);

    // ================================================================
    //                         MODIFIERS
    // ================================================================

    modifier onlyRegistered() {
        if (!riders[msg.sender].registered) revert BodaBodaSavings__RiderNotRegistered();
        _;
    }

    /// @dev Active-rider gate: registered + KYC-verified + licence not expired.
    ///      Used for INFLOWS / obligation-creating actions (deposit, request).
    ///      NOT used for fund-RECOVERY actions — see AUD-3 rationale on claim/cancel.
    modifier onlyVerified() {
        if (!riders[msg.sender].registered)    revert BodaBodaSavings__RiderNotRegistered();
        RiderKYC storage k = riderKYC[msg.sender];
        if (!k.verified)                       revert BodaBodaSavings__RiderNotVerified();
        if (block.timestamp > k.licenseExpiry) revert BodaBodaSavings__LicenseExpired();
        _;
    }

    /// @dev [V4.1-2] Restricts creditDeposit() to the single configured relayer.
    ///      Deliberately NOT onlyOwner — the relayer is an always-online backend key
    ///      with narrow, single-purpose privilege, kept separate from the owner key.
    modifier onlyRelayer() {
        if (msg.sender != relayer) revert BodaBodaSavings__NotRelayer();
        _;
    }

    // ================================================================
    //                        CONSTRUCTOR
    // ================================================================

    constructor(
        address            _stablecoin,
        address[] memory   _lenderAddrs,
        string[]  memory   _lenderNames,
        uint256[] memory   _cycles,
        RepaymentSchedule[] memory _schedules,
        address            initialOwner
    ) Ownable(initialOwner) {
        if (_stablecoin == address(0))
            revert BodaBodaSavings__StablecoinCannotBeZeroAddress();
        if (_lenderAddrs.length == 0)
            revert BodaBodaSavings__NoLendersProvided();
        if (_lenderAddrs.length != _lenderNames.length  ||
            _lenderAddrs.length != _cycles.length       ||
            _lenderAddrs.length != _schedules.length)
            revert BodaBodaSavings__ArrayLengthMismatch();

        (bool ok, bytes memory data) =
            _stablecoin.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length < 32) revert BodaBodaSavings__InvalidStablecoinContract();

        stablecoin = IERC20(_stablecoin);

        _validCategories[REASON_MEDICAL]           = true;
        _validCategories[REASON_REPAIR]            = true;
        _validCategories[REASON_EDUCATION]         = true;
        _validCategories[REASON_HOUSEHOLD]         = true;
        _validCategories[REASON_EMERGENCY]         = true;
        _validCategories[REASON_FAMILY_OBLIGATION] = true;
        _validCategories[REASON_OTHER]             = true;

        for (uint256 i = 0; i < _lenderAddrs.length; i++) {
            _addLender(_lenderAddrs[i], _lenderNames[i], _cycles[i], _schedules[i]);
        }
    }

    // ================================================================
    //                     LENDER MANAGEMENT
    // ================================================================

    function addLender(
        address           _lenderAddress,
        string calldata   _name,
        uint256           _cycle,
        RepaymentSchedule _schedule
    ) external onlyOwner {
        _addLender(_lenderAddress, _name, _cycle, _schedule);
    }

    function _addLender(
        address           _lenderAddress,
        string memory     _name,
        uint256           _cycle,
        RepaymentSchedule _schedule
    ) internal {
        if (_lenderAddress == address(0))     revert BodaBodaSavings__ZeroAddress();
        if (lenders[_lenderAddress].verified) revert BodaBodaSavings__LenderAlreadyRegistered();
        if (_cycle == 0)                      revert BodaBodaSavings__InvalidCollectionCycle();

        lenders[_lenderAddress] = Lender({
            name:            _name,
            lenderAddress:   _lenderAddress,
            collectionCycle: _cycle,
            schedule:        _schedule,
            verified:        true,
            active:          true
        });

        lenderList.push(_lenderAddress);
        emit LenderAdded(_lenderAddress, _name, _cycle, _schedule);
    }

    function deactivateLender(address _lenderAddress) external onlyOwner {
        if (!lenders[_lenderAddress].verified) revert BodaBodaSavings__LenderNotFound();
        lenders[_lenderAddress].active = false;
        emit LenderDeactivated(_lenderAddress);
    }

    function reactivateLender(address _lenderAddress) external onlyOwner {
        if (!lenders[_lenderAddress].verified) revert BodaBodaSavings__LenderNotFound();
        lenders[_lenderAddress].active = true;
        emit LenderReactivated(_lenderAddress);
    }

    /// @notice Update a lender's collection cycle.
    /// @dev    [V4-2] By design this APPLIES TO EXISTING RIDERS: nextSettlementDue is
    ///         derived from the current cycle, so shortening the cycle can make
    ///         existing riders immediately due, and lengthening defers them. This is
    ///         intentional (new lender terms apply to current borrowers). Owner is
    ///         trusted; behind a multisig + timelock in production.
    function updateLenderCycle(address _lenderAddress, uint256 _newCycle) external onlyOwner {
        if (!lenders[_lenderAddress].verified) revert BodaBodaSavings__LenderNotFound();
        if (_newCycle == 0)                    revert BodaBodaSavings__InvalidCollectionCycle();
        lenders[_lenderAddress].collectionCycle = _newCycle;
        emit LenderCycleUpdated(_lenderAddress, _newCycle);
    }

    /// @notice Paginated lender list. Pass limit = 0 to return all.
    function getLenders(uint256 offset, uint256 limit)
        external view returns (address[] memory)
    {
        uint256 total = lenderList.length;
        if (offset >= total) return new address[](0);
        uint256 remaining = total - offset;
        uint256 count = (limit == 0 || limit > remaining) ? remaining : limit;
        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = lenderList[offset + i];
        }
        return result;
    }

    function getLenderCount() external view returns (uint256) {
        return lenderList.length;
    }

    // ================================================================
    //                    RIDER REGISTRATION  [ID-4]
    // ================================================================

    function registerRider(
        string  calldata  _name,
        uint8             _age,
        bytes1            _gender,
        address           _lenderAddress,
        SplitRatio        _ratio,
        uint256           _loanTarget,
        bytes32           _verificationHash,
        uint8             _kycLevel,
        uint256           _licenseExpiry,
        bytes32           _kycProvider
    ) external {
        if (riders[msg.sender].registered)
            revert BodaBodaSavings__RiderAlreadyRegistered();

        // ── Identity validation [ID-1] ──
        if (bytes(_name).length == 0)
            revert BodaBodaSavings__NameRequired();
        if (_age < 18 || _age > 65)
            revert BodaBodaSavings__InvalidAge();
        if (_gender != bytes1("M") && _gender != bytes1("F") && _gender != bytes1("O"))
            revert BodaBodaSavings__InvalidGender();

        // ── Lender validation ──
        if (!lenders[_lenderAddress].verified)
            revert BodaBodaSavings__LenderNotFound();
        if (!lenders[_lenderAddress].active)
            revert BodaBodaSavings__LenderNotActive();

        // ── Financial validation ──
        if (_loanTarget == 0)
            revert BodaBodaSavings__ZeroLoanTarget();

        // ── KYC validation ──
        if (_verificationHash == bytes32(0))
            revert BodaBodaSavings__InvalidVerificationHash();
        if (_kycLevel < KYC_BASIC || _kycLevel > KYC_PREMIUM)
            revert BodaBodaSavings__InvalidKycLevel();
        if (_licenseExpiry <= block.timestamp)
            revert BodaBodaSavings__LicenseExpired();

        riderKYC[msg.sender] = RiderKYC({
            verificationHash:  _verificationHash,
            verificationLevel: _kycLevel,
            verified:          true,
            verifiedAt:        block.timestamp,
            licenseExpiry:     _licenseExpiry,
            kycProvider:       _kycProvider
        });

        Rider storage r = riders[msg.sender];
        r.name          = _name;
        r.age           = _age;
        r.gender        = _gender;
        r.lenderAddress = _lenderAddress;
        r.splitRatio    = _ratio;
        r.loanTarget    = _loanTarget;
        r.lastSettledAt = block.timestamp;   // [V4-1] settlement schedule starts now
        r.registered    = true;

        emit RiderRegistered(
            msg.sender, _name, _lenderAddress, _loanTarget, _kycLevel, _ratio
        );
    }

    /// @notice Rider changes their own split ratio. [V4-4]
    /// @dev    Affects FUTURE deposits only. onlyRegistered (harmless preference;
    ///         deposits are themselves gated by onlyVerified). Invalid enum values
    ///         are rejected by ABI bounds-checking before this body runs.
    function updateSplitRatio(SplitRatio _newRatio) external onlyRegistered {
        Rider storage r = riders[msg.sender];
        SplitRatio old = r.splitRatio;
        r.splitRatio = _newRatio;
        emit SplitRatioUpdated(msg.sender, old, _newRatio);
    }

    function updateRiderKYC(
        address _rider,
        bytes32 _newHash,
        uint8   _newLevel,
        uint256 _newLicenseExpiry,
        bytes32 _kycProvider
    ) external onlyOwner {
        if (!riders[_rider].registered)       revert BodaBodaSavings__RiderNotRegistered();
        if (_newHash == bytes32(0))            revert BodaBodaSavings__InvalidVerificationHash();
        if (_newLevel < KYC_BASIC || _newLevel > KYC_PREMIUM)
                                               revert BodaBodaSavings__InvalidKycLevel();
        if (_newLicenseExpiry <= block.timestamp) revert BodaBodaSavings__LicenseExpired();

        RiderKYC storage kyc = riderKYC[_rider];
        kyc.verificationHash  = _newHash;
        kyc.verificationLevel = _newLevel;
        kyc.verifiedAt        = block.timestamp;
        kyc.licenseExpiry     = _newLicenseExpiry;
        kyc.kycProvider       = _kycProvider;

        emit RiderKYCUpdated(_rider, _newLevel);
    }

    function updateLoanTarget(address _rider, uint256 _newTarget) external onlyOwner {
        if (!riders[_rider].registered) revert BodaBodaSavings__RiderNotRegistered();
        if (_newTarget == 0)            revert BodaBodaSavings__ZeroLoanTarget();

        Rider storage r = riders[_rider];
        if (_newTarget < r.loanRepaid)  revert BodaBodaSavings__NewTargetBelowRepaid();

        uint256 old = r.loanTarget;
        r.loanTarget = _newTarget;
        emit LoanTargetUpdated(_rider, old, _newTarget);
    }

    // ================================================================
    //                     DEPOSIT FUNCTIONS
    // ================================================================

    /// @notice Standard deposit — caller must approve this contract first.
    function deposit(uint256 amount)
        external
        nonReentrant
        onlyVerified
        whenNotPaused
    {
        if (amount == 0) revert BodaBodaSavings__ZeroDeposit();
        uint256 received = _pullStablecoin(msg.sender, amount);   // [SEC-B]
        _applyDeposit(msg.sender, received);
    }

    /// @notice One-click deposit using EIP-2612 permit — no separate approve tx. [ID-5]
    function depositWithPermit(
        uint256 amount,
        uint256 deadline,
        uint8   v,
        bytes32 r,
        bytes32 s
    )
        external
        nonReentrant
        onlyVerified
        whenNotPaused
    {
        if (amount == 0) revert BodaBodaSavings__ZeroDeposit();

        // Silent approval via signature — no separate on-chain approve tx.
        IERC20Permit(address(stablecoin)).permit(
            msg.sender, address(this), amount, deadline, v, r, s
        );

        uint256 received = _pullStablecoin(msg.sender, amount);   // [SEC-B]
        _applyDeposit(msg.sender, received);
    }

    /// @notice [V4.1-1] Relayer-only entry point crediting a deposit that originated
    ///         off-chain (e.g. a completed M-Pesa payment via IntaSend), on behalf of
    ///         a rider who is not the caller and is not msg.sender.
    /// @dev    Differs from deposit() in exactly two ways: (1) stablecoin is pulled
    ///         FROM THE RELAYER (msg.sender here), not from the rider — the rider
    ///         never approved this contract for an off-chain payment, nor should they
    ///         need to; (2) the rider whose balance is credited is an explicit
    ///         parameter, not msg.sender. Everything else — the split/rounding/
    ///         loan-cleared routing in _applyDeposit, the fee-on-transfer-safe pull in
    ///         _pullStablecoin, CEI ordering, reentrancy guard, pause gate — is
    ///         identical to a normal deposit. No onlyVerified gate: the rider already
    ///         passed KYC at registration: this is not a new consent point, it is
    ///         crediting funds that arrived via a different rail.
    ///
    ///         NOT a mint: the relayer must hold and actually transfer real stablecoin
    ///         into the contract. If the relayer's wallet is empty, this reverts via
    ///         the same SafeERC20 path as any other transferFrom failure. The solvency
    ///         invariant therefore holds with no special-casing for this path.
    ///
    ///         Idempotency (not double-crediting the same M-Pesa payment) is NOT
    ///         enforced on-chain — there is no invoice-id parameter here by design,
    ///         to keep this function narrow and stateless. That responsibility sits
    ///         with the backend ledger that decides whether to call this function at
    ///         all for a given IntaSend invoice_id. Calling this twice for the same
    ///         off-chain payment WILL double-credit; the backend must prevent that.
    function creditDeposit(address _rider, uint256 amount)
        external
        nonReentrant
        onlyRelayer
        whenNotPaused
    {
        if (_rider == address(0))            revert BodaBodaSavings__ZeroAddress();
        if (!riders[_rider].registered)      revert BodaBodaSavings__RiderNotRegistered();
        if (amount == 0)                     revert BodaBodaSavings__ZeroDeposit();

        uint256 received = _pullStablecoin(msg.sender, amount);   // [SEC-B] relayer is the source
        (uint256 savingsPart, uint256 loanPart) = _applyDepositReturningSplit(_rider, received);

        emit DepositCredited(_rider, msg.sender, received, savingsPart, loanPart, block.timestamp);
    }

    /// @notice Set the relayer address. [V4.1-2] address(0) disables creditDeposit().
    /// @dev    onlyOwner — the relayer key itself can never grant or rotate its own
    ///         privilege. In production this should be a dedicated, low-balance,
    ///         frequently-rotated backend key, never the owner key.
    function setRelayer(address _relayer) external onlyOwner {
        address old = relayer;
        relayer = _relayer;
        emit RelayerUpdated(old, _relayer);
    }

    /// @dev [SEC-B] Pulls tokens and returns the ACTUAL balance delta, so a
    ///      fee-on-transfer/rebasing token can never cause the ledger to credit more
    ///      than was truly received. Reverts if nothing arrived.
    function _pullStablecoin(address from, uint256 amount) internal returns (uint256 received) {
        uint256 balBefore = stablecoin.balanceOf(address(this));
        stablecoin.safeTransferFrom(from, address(this), amount);
        received = stablecoin.balanceOf(address(this)) - balBefore;
        if (received == 0) revert BodaBodaSavings__NothingReceived();
    }

    /// @dev Internal: applies the split and updates rider balances + aggregates, then
    ///      emits the wallet-deposit event. [V4-3] Once the loan is cleared, the whole
    ///      deposit becomes savings. [V4-6] Split rounding remainder carries per rider.
    function _applyDeposit(address _rider, uint256 amount) internal {
        (uint256 savingsPart, uint256 loanPart) = _applyDepositReturningSplit(_rider, amount);
        emit Deposit(_rider, amount, savingsPart, loanPart, block.timestamp);
    }

    /// @dev [V4.1-1] Shared split/rounding/loan-cleared/aggregate logic, factored out
    ///      so creditDeposit() can reuse it exactly while emitting its own
    ///      DepositCredited event (which needs the relayer address — a shape Deposit's
    ///      event doesn't carry). No behavioural change versus the prior single-purpose
    ///      _applyDeposit: the body below is byte-for-byte the same logic, just
    ///      returning the split instead of emitting Deposit directly.
    function _applyDepositReturningSplit(address _rider, uint256 amount)
        internal
        returns (uint256 savingsPart, uint256 loanPart)
    {
        Rider storage r = riders[_rider];

        bool loanCleared = r.loanTarget > 0 && r.loanRepaid >= r.loanTarget;
        if (loanCleared) {
            // [V4-3] Loan satisfied — rider keeps the full deposit as savings.
            savingsPart = amount;
            loanPart    = 0;
        } else {
            (uint256 savingsPct,) = _getSplitPercentages(r.splitRatio);
            // [V4-6] numerator carries the prior remainder; savingsPart is the floor,
            //        the new remainder (0..99) rolls to the next deposit.
            uint256 numerator  = amount * savingsPct + r.savingsRemainder;
            savingsPart        = numerator / 100;
            r.savingsRemainder = numerator % 100;
            loanPart           = amount - savingsPart;   // exact; never underflows
        }

        r.savingsBalance += savingsPart;
        r.loanBalance    += loanPart;
        r.totalDeposited += amount;

        if (r.firstDepositAt == 0) r.firstDepositAt = block.timestamp;
        r.lastDepositAt = block.timestamp;

        totalSavingsHeld          += savingsPart;   // [V4-7]
        totalUnsettledLoanBalance += loanPart;      // [V4-7]
    }

    /// @dev Returns (savingsPct, loanPct) for a given SplitRatio. [ID-2]
    ///      [AUD-5] Reverts on an unrecognised ratio (defensive; enum-bounds checking
    ///      already rejects invalid external inputs).
    function _getSplitPercentages(SplitRatio ratio)
        internal
        pure
        returns (uint256 savingsPct, uint256 loanPct)
    {
        if (ratio == SplitRatio.SPLIT_70_30) return (70, 30);
        if (ratio == SplitRatio.SPLIT_60_40) return (60, 40);
        if (ratio == SplitRatio.SPLIT_50_50) return (50, 50);
        if (ratio == SplitRatio.SPLIT_40_60) return (40, 60);
        if (ratio == SplitRatio.SPLIT_30_70) return (30, 70);
        revert BodaBodaSavings__InvalidSplitRatio();
    }

    // ================================================================
    //               LOAN SETTLEMENT (scheduled, passive)  [V4-1]
    // ================================================================

    /// @notice Sweep a rider's accumulated loanBalance to their lender, once the
    ///         lender's collection cycle has elapsed since the last settlement.
    ///
    /// @dev    PERMISSIONLESS by design — your backend keeper calls it on schedule,
    ///         but anyone may, making settlement autonomous. There is no attack
    ///         surface: settlement always sweeps the FULL current loanBalance to the
    ///         rider's own lender, is gated to once-per-cycle, follows CEI, and is
    ///         nonReentrant. A caller can only advance an already-due schedule (never
    ///         pull it forward), at their own gas cost.
    ///
    ///         The clock resets to block.timestamp on each settlement, so keeper
    ///         latency cannot accumulate into unbounded drift; the trade-off is that a
    ///         consistently-late keeper lengthens the effective cycle slightly — a
    ///         tuning concern, not a safety one.
    ///
    ///         No KYC/licence gate: a loan repayment is an obligation and must settle
    ///         even if the rider's licence has lapsed. A zero-balance settlement is a
    ///         harmless no-op that simply advances the schedule.
    function settleLoanRepayment(address _rider)
        external
        nonReentrant
        whenNotPaused
    {
        Rider storage r = riders[_rider];
        if (!r.registered) revert BodaBodaSavings__RiderNotRegistered();

        uint256 cycle = lenders[r.lenderAddress].collectionCycle;
        if (block.timestamp < r.lastSettledAt + cycle)
            revert BodaBodaSavings__SettlementNotDue();

        uint256 amount    = r.loanBalance;
        uint256 remaining = r.loanTarget > r.loanRepaid
            ? r.loanTarget - r.loanRepaid
            : 0;

        uint256 toSettle = amount > remaining ? remaining : amount;
        uint256 excess   = amount - toSettle;          // [V4-3] surplus over target

        bool autoTriggered = msg.sender != _rider;

        // ── Effects (full CEI; token transfer is the final statement) ──
        r.lastSettledAt            = block.timestamp;
        r.loanBalance              = 0;                 // fully drained
        totalUnsettledLoanBalance -= amount;            // [V4-7] whole balance leaves

        if (toSettle > 0) {
            r.loanRepaid     += toSettle;
            totalLoanSettled += toSettle;
        }
        if (excess > 0) {
            // [V4-3] Surplus beyond the loan target becomes the rider's savings
            //        rather than stranded loan-side funds.
            r.savingsBalance += excess;
            totalSavingsHeld += excess;                 // [V4-7]
        }

        _repaymentHistory[_rider].push(RepaymentRecord({
            amount:        toSettle,
            settledAt:     block.timestamp,
            autoTriggered: autoTriggered
        }));

        // ── Interaction ──
        if (toSettle > 0) {
            stablecoin.safeTransfer(r.lenderAddress, toSettle);   // [AUD-1]
        }

        emit LoanRepaymentSettled(
            _rider, r.lenderAddress, toSettle, block.timestamp, autoTriggered
        );
        if (excess > 0) emit LoanExcessToSavings(_rider, excess);
        if (r.loanTarget > 0 && r.loanRepaid >= r.loanTarget) {
            emit LoanCleared(_rider, r.loanRepaid, block.timestamp);
        }
    }

    // ================================================================
    //               SAVINGS WITHDRAWAL  (request → approve → claim)
    // ================================================================

    /// @notice Step 1 — Rider submits a withdrawal request.
    /// @dev    [V4-5] Requests <= autoApprovalThreshold are auto-approved here but
    ///         STILL subject to WITHDRAWAL_DELAY, during which the owner may
    ///         revokeApprovedWithdrawal() if off-chain monitoring flags fraud.
    ///
    ///         SECURITY — THRESHOLD SPLITTING: a rider could split a large withdrawal
    ///         into several sub-threshold requests over time to evade manual review.
    ///         One active request at a time bounds instantaneous exposure, and the
    ///         delay window allows owner revocation, but a determined drip is not
    ///         fully prevented on-chain. Production MUST add off-chain cumulative-
    ///         window monitoring (and/or an on-chain rolling per-rider cap) before
    ///         raising the threshold to a material value.
    function requestWithdrawal(uint256 amount, bytes32 category)
        external
        nonReentrant
        onlyVerified
        whenNotPaused
    {
        if (amount == 0)                 revert BodaBodaSavings__ZeroWithdrawAmount();
        if (!_validCategories[category]) revert BodaBodaSavings__InvalidWithdrawalCategory();

        Rider storage r = riders[msg.sender];
        if (r.savingsBalance < amount)   revert BodaBodaSavings__InsufficientSavings();

        WithdrawalRequest storage existing = withdrawalRequests[msg.sender];
        if (existing.status == WithdrawalStatus.Pending ||
            existing.status == WithdrawalStatus.Approved)
            revert BodaBodaSavings__WithdrawalAlreadyPending();

        // Amount leaves spendable savings but remains in the pool (totalSavingsHeld
        // unchanged) until claimed or returned.
        r.savingsBalance -= amount;

        bool autoApproved = amount <= autoApprovalThreshold;   // [V4-5]

        withdrawalRequests[msg.sender] = WithdrawalRequest({
            amount:      amount,
            category:    category,
            requestedAt: block.timestamp,
            approvedAt:  autoApproved ? block.timestamp : 0,
            status:      autoApproved ? WithdrawalStatus.Approved : WithdrawalStatus.Pending
        });

        emit WithdrawalRequested(msg.sender, amount, category, block.timestamp, autoApproved);
        if (autoApproved) emit WithdrawalApproved(msg.sender, amount, block.timestamp);
    }

    /// @notice Step 2a — Owner approves a PENDING (above-threshold) request.
    function approveWithdrawal(address _rider) external onlyOwner {
        WithdrawalRequest storage req = withdrawalRequests[_rider];
        if (req.status != WithdrawalStatus.Pending) revert BodaBodaSavings__NoWithdrawalPending();

        req.approvedAt = block.timestamp;
        req.status     = WithdrawalStatus.Approved;

        emit WithdrawalApproved(_rider, req.amount, block.timestamp);
    }

    /// @notice Step 2b — Owner denies a PENDING request. Amount returned to savings.
    function denyWithdrawal(address _rider) external onlyOwner {
        WithdrawalRequest storage req = withdrawalRequests[_rider];
        if (req.status != WithdrawalStatus.Pending) revert BodaBodaSavings__NoWithdrawalPending();

        uint256 amount = req.amount;
        riders[_rider].savingsBalance += amount;
        delete withdrawalRequests[_rider];

        emit WithdrawalDenied(_rider, amount, block.timestamp);
    }

    /// @notice [AUD-3] Owner revokes an ALREADY-APPROVED request (manual or auto),
    ///         returning funds to savings. The safety valve for the auto-approval
    ///         delay window and for any approved-but-unclaimable situation.
    function revokeApprovedWithdrawal(address _rider) external onlyOwner {
        WithdrawalRequest storage req = withdrawalRequests[_rider];
        if (req.status != WithdrawalStatus.Approved) revert BodaBodaSavings__WithdrawalNotApproved();

        uint256 amount = req.amount;
        riders[_rider].savingsBalance += amount;
        delete withdrawalRequests[_rider];

        emit WithdrawalDenied(_rider, amount, block.timestamp);
    }

    /// @notice [AUD-3] Rider cancels their own pending/approved request, returning the
    ///         amount to spendable savings. onlyRegistered + NOT whenNotPaused so a
    ///         rider whose licence lapsed (or during a pause) can still recover their
    ///         own money. No token leaves the contract here.
    function cancelWithdrawal()
        external
        nonReentrant
        onlyRegistered
    {
        WithdrawalRequest storage req = withdrawalRequests[msg.sender];
        if (req.status != WithdrawalStatus.Pending &&
            req.status != WithdrawalStatus.Approved)
            revert BodaBodaSavings__NoWithdrawalToCancel();

        uint256 amount = req.amount;
        riders[msg.sender].savingsBalance += amount;
        delete withdrawalRequests[msg.sender];

        emit WithdrawalCancelled(msg.sender, amount, block.timestamp);
    }

    /// @notice Step 3 — Rider claims after approval + WITHDRAWAL_DELAY.
    /// @dev    [AUD-3] onlyRegistered, NOT onlyVerified — returning a rider's own
    ///         savings must not be blocked by a licence/KYC lapse during the delay.
    function claimWithdrawal()
        external
        nonReentrant
        onlyRegistered
        whenNotPaused
    {
        WithdrawalRequest storage req = withdrawalRequests[msg.sender];
        if (req.status != WithdrawalStatus.Approved)
            revert BodaBodaSavings__WithdrawalNotApproved();
        if (block.timestamp < req.approvedAt + WITHDRAWAL_DELAY)
            revert BodaBodaSavings__WithdrawalDelayNotMet();

        uint256 amount   = req.amount;
        bytes32 category = req.category;
        uint256 reqAt    = req.requestedAt;

        Rider storage r = riders[msg.sender];
        r.totalWithdrawn  += amount;
        r.withdrawalCount += 1;

        totalSavingsHeld -= amount;   // [V4-7] money leaves the pool now

        _withdrawalHistory[msg.sender].push(WithdrawalRecord({
            amount:      amount,
            category:    category,
            requestedAt: reqAt,
            claimedAt:   block.timestamp
        }));

        delete withdrawalRequests[msg.sender];

        stablecoin.safeTransfer(msg.sender, amount);   // [AUD-1] final statement

        emit WithdrawalClaimed(msg.sender, amount, block.timestamp);
    }

    // ================================================================
    //                      VIEW FUNCTIONS
    // ================================================================

    /// @notice Full raw rider record. Replaces the removed public-mapping getter.
    /// @dev    Returns a single memory struct (one stack slot — legacy-codegen safe).
    function getRider(address _rider) external view returns (Rider memory) {
        return riders[_rider];
    }

    /// @notice Full rider profile — identity + lender info + split ratio. [ID-6]
    /// @dev    Returns a named memory struct (see RiderProfileView).
    function getRiderProfile(address _rider)
        external
        view
        returns (RiderProfileView memory p)
    {
        Rider  storage r = riders[_rider];
        Lender storage l = lenders[r.lenderAddress];
        p.name           = r.name;
        p.age            = r.age;
        p.gender         = r.gender;
        p.registered     = r.registered;
        p.lenderAddress  = r.lenderAddress;
        p.lenderName     = l.name;
        p.lenderSchedule = l.schedule;
        p.splitRatio     = r.splitRatio;
        p.loanTarget     = r.loanTarget;
    }

    /// @notice Financial dashboard snapshot.
    /// @dev    [V4-1] pot fields replaced by settlement-scheduling fields.
    ///         Returns a named memory struct (see RiderAnalyticsView).
    function getRiderAnalytics(address _rider)
        external
        view
        returns (RiderAnalyticsView memory a)
    {
        Rider storage r = riders[_rider];
        a.savingsBalance    = r.savingsBalance;
        a.loanBalance       = r.loanBalance;
        a.totalDeposited    = r.totalDeposited;
        a.totalWithdrawn    = r.totalWithdrawn;
        a.withdrawalCount   = r.withdrawalCount;
        a.lastDepositAt     = r.lastDepositAt;
        a.firstDepositAt    = r.firstDepositAt;
        a.loanRepaid        = r.loanRepaid;
        a.lastSettledAt     = r.lastSettledAt;
        a.nextSettlementDue = _nextSettlementDue(r);
    }

    /// @notice Absolute timestamp at which this rider's loan-portion next settles.
    /// @dev    [V4-2] Derived from the CURRENT lender cycle, so it reflects any
    ///         updateLenderCycle() immediately.
    function getNextSettlementDue(address _rider) external view returns (uint256) {
        return _nextSettlementDue(riders[_rider]);
    }

    /// @notice True if this rider is currently due (or overdue) for settlement.
    function isSettlementDue(address _rider) external view returns (bool) {
        Rider storage r = riders[_rider];
        if (!r.registered) return false;
        return block.timestamp >= _nextSettlementDue(r);
    }

    function _nextSettlementDue(Rider storage r) internal view returns (uint256) {
        return r.lastSettledAt + lenders[r.lenderAddress].collectionCycle;
    }

    function getLoanStatus(address _rider)
        external
        view
        returns (
            uint256 loanTarget,
            uint256 loanBalance,
            uint256 loanRepaid,
            uint256 loanRemaining,
            bool    isCleared,
            uint256 progressBps
        )
    {
        Rider storage r = riders[_rider];
        loanTarget    = r.loanTarget;
        loanBalance   = r.loanBalance;
        loanRepaid    = r.loanRepaid;
        loanRemaining = r.loanRepaid >= r.loanTarget ? 0 : r.loanTarget - r.loanRepaid;
        isCleared     = r.loanTarget > 0 && r.loanRepaid >= r.loanTarget;
        progressBps   = r.loanTarget > 0 ? (r.loanRepaid * 10_000) / r.loanTarget : 0;
    }

    function getRiderKYC(address _rider)
        external
        view
        returns (
            bytes32 verificationHash,
            uint8   verificationLevel,
            uint256 verifiedAt,
            uint256 licenseExpiry,
            bytes32 kycProvider,
            bool    verified
        )
    {
        RiderKYC storage k = riderKYC[_rider];
        return (
            k.verificationHash, k.verificationLevel, k.verifiedAt,
            k.licenseExpiry, k.kycProvider, k.verified
        );
    }

    function getWithdrawalRequest(address _rider)
        external
        view
        returns (
            uint256          amount,
            bytes32          category,
            uint256          requestedAt,
            uint256          approvedAt,
            uint256          claimableAt,
            WithdrawalStatus status
        )
    {
        WithdrawalRequest storage req = withdrawalRequests[_rider];
        return (
            req.amount, req.category, req.requestedAt, req.approvedAt,
            req.approvedAt > 0 ? req.approvedAt + WITHDRAWAL_DELAY : 0,
            req.status
        );
    }

    function getWithdrawalHistory(address _rider)
        external view returns (WithdrawalRecord[] memory)
    {
        return _withdrawalHistory[_rider];
    }

    function getRepaymentHistory(address _rider)
        external view returns (RepaymentRecord[] memory)
    {
        return _repaymentHistory[_rider];
    }

    /// @notice Idle (unsettled) loan funds held across all riders. [V4-7]
    function getIdleLoanBalance() external view returns (uint256) {
        return totalUnsettledLoanBalance;
    }

    /// @notice Total claims the pool must cover. [V4-7]
    function getTotalObligations() external view returns (uint256) {
        return totalSavingsHeld + totalUnsettledLoanBalance;
    }

    function getContractBalance() external view returns (uint256) {
        return stablecoin.balanceOf(address(this));
    }

    /// @notice Solvency check — true iff the pool covers every claim against it.
    function isSolvent() external view returns (bool) {
        return stablecoin.balanceOf(address(this)) >= totalSavingsHeld + totalUnsettledLoanBalance;
    }

    function isVerifiedRider(address _rider) external view returns (bool) {
        return riders[_rider].registered && riderKYC[_rider].verified;
    }

    function getLender(address _lenderAddress)
        external
        view
        returns (
            string  memory name,
            uint256        collectionCycle,
            RepaymentSchedule schedule,
            bool           verified,
            bool           active
        )
    {
        Lender storage l = lenders[_lenderAddress];
        return (l.name, l.collectionCycle, l.schedule, l.verified, l.active);
    }

    // ================================================================
    //                      ADMIN FUNCTIONS
    // ================================================================

    function pause() external onlyOwner { _pause(); }

    function unpause() external onlyOwner { _unpause(); }

    /// @notice Set the auto-approval threshold. [V4-5] (DEV placeholder default.)
    function setAutoApprovalThreshold(uint256 _threshold) external onlyOwner {
        uint256 old = autoApprovalThreshold;
        autoApprovalThreshold = _threshold;
        emit AutoApprovalThresholdUpdated(old, _threshold);
    }

    /// @notice Swap stablecoin address.
    /// @dev    [AUD-4] Requires the contract to hold no obligations at all — every
    ///         internal aggregate must be zero, not just the live balance — and the
    ///         new token must report the SAME decimals as the old one (all internal
    ///         balances are in token-native units).
    function setStablecoin(address _stablecoin) external onlyOwner {
        if (_stablecoin == address(0))
            revert BodaBodaSavings__StablecoinCannotBeZeroAddress();

        (bool ok, bytes memory data) =
            _stablecoin.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length < 32) revert BodaBodaSavings__InvalidStablecoinContract();

        uint8 newDecimals = abi.decode(data, (uint8));
        uint8 oldDecimals = IERC20Metadata(address(stablecoin)).decimals();
        if (newDecimals != oldDecimals) revert BodaBodaSavings__DecimalsMismatch();

        if (totalSavingsHeld != 0 || totalUnsettledLoanBalance != 0)
            revert BodaBodaSavings__OutstandingAccounting();
        if (stablecoin.balanceOf(address(this)) != 0)
            revert BodaBodaSavings__ContractBalanceMustBeZero();

        address old = address(stablecoin);
        stablecoin  = IERC20(_stablecoin);
        emit StablecoinUpdated(old, _stablecoin);
    }

    /// @notice Recover accidentally sent non-stablecoin ERC20 tokens.
    function recoverERC20(address _token, address _to, uint256 _amount) external onlyOwner {
        if (_to    == address(0))           revert BodaBodaSavings__ZeroAddress();
        if (_token == address(0))           revert BodaBodaSavings__ZeroAddressToken();
        if (_token == address(stablecoin))  revert BodaBodaSavings__CannotRecoverStablecoin();

        IERC20(_token).safeTransfer(_to, _amount);   // [AUD-1]
        emit ERC20Recovered(_token, _to, _amount);
    }
}
