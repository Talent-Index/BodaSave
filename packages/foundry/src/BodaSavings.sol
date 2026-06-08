// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20}          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit}    from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20}       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata}  from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable}         from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable}        from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title  BodaBodaSavings  (v3.1)
/// @author Team
/// @notice Savings + loan repayment platform for bodaboda riders in Kenya.
///
///         Core flow
///         ─────────
///         1. Owner registers verified lenders at deployment (or via addLender()).
///         2. Rider self-registers: personal details + lender choice + split ratio.
///            Owner must have pre-approved KYC off-chain (Smile Identity / NTSA).
///         3. Rider deposits via:
///              a) deposit()            — standard approve → deposit (two steps)
///              b) depositWithPermit()  — EIP-2612 permit  → deposit (one step, no approve tx)
///            Split is determined by the rider's chosen SplitRatio, not hardcoded 50/50.
///         4. Rider locks loanBalance into the pot to schedule repayment.
///            Pot deadline = lender's collectionCycle (seconds), SNAPSHOTTED at lock time.
///         5. Rider withdraws savings: requestWithdrawal() → owner approves →
///            WITHDRAWAL_DELAY elapses → claimWithdrawal().
///
/// @dev    v3.1 Changes (audit remediation on top of v3)
///         ────────────────────────────────────────────────
///         [AUD-1]  SafeERC20 used for ALL token movements. Removes silent failures
///                  against non-standard tokens (e.g. USDT-style no-return-value).
///         [AUD-2]  Pot deadline is SNAPSHOTTED into the Rider struct at lock time
///                  (potDeadline) and settled against the snapshot. An owner changing
///                  the lender cycle mid-pot can no longer retroactively move a
///                  rider's deadline.
///         [AUD-3]  Withdrawal claim/deny no longer gated on KYC/license expiry.
///                  Savings are the rider's own money — claimWithdrawal() and the
///                  cancel paths use onlyRegistered, not onlyVerified. Owner can also
///                  revoke an ALREADY-APPROVED withdrawal, and a rider can cancel
///                  their own pending/approved request. Eliminates the stuck-state.
///         [AUD-4]  setStablecoin() now requires ALL internal aggregate accounting
///                  to be zero (not just the live token balance) and enforces that
///                  the new token reports the same decimals as the old one.
///         [AUD-5]  _getSplitPercentages() unreachable branch now reverts instead of
///                  silently returning 50/50, removing the latent default mismatch.
///
///         v3 features (unchanged): [ID-1..ID-8] identity, split, schedule,
///         self-registration, depositWithPermit, getRiderProfile.

contract BodaBodaSavings is Ownable, Pausable, ReentrancyGuard {

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
    error BodaBodaSavings__TransferFailed();           // retained for ABI compat (now unused)
    error BodaBodaSavings__CannotRecoverStablecoin();
    error BodaBodaSavings__ZeroAddressToken();
    error BodaBodaSavings__ContractBalanceMustBeZero();
    error BodaBodaSavings__OutstandingAccounting();     // [AUD-4]
    error BodaBodaSavings__DecimalsMismatch();          // [AUD-4]

    // — General —
    error BodaBodaSavings__ZeroAddress();
    error BodaBodaSavings__ZeroAmount();

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
    error BodaBodaSavings__InsufficientSavings();
    error BodaBodaSavings__InsufficientLoanBalance();

    // — Loan —
    error BodaBodaSavings__LoanAlreadyCleared();
    error BodaBodaSavings__ExceedsAvailablePool();
    error BodaBodaSavings__InvalidSplitRatio();         // [AUD-5]

    // — Pot —
    error BodaBodaSavings__PotAlreadyActive();
    error BodaBodaSavings__NoPotActive();
    error BodaBodaSavings__PotDeadlineNotReached();

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
        SPLIT_50_50,   // 50 % savings | 50 % loan  (previous hardcoded behaviour)
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
        uint256           collectionCycle;   // seconds between pot settlements
        RepaymentSchedule schedule;          // [ID-3] WEEKLY | BIWEEKLY | MONTHLY
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
    ///
    ///         [AUD-2] potDeadline added — absolute timestamp snapshotted at lock
    ///                 time so a later lender-cycle change cannot move it.
    struct Rider {
        // ── Identity [ID-1] ──────────────────────────────────────────
        string     name;           // rider's full name
        bytes1     gender;         // 'M' | 'F' | 'O'  (1 byte, cheaper than string)

        // ── Lender + Split ───────────────────────────────────────────
        address    lenderAddress;
        SplitRatio splitRatio;     // [ID-2] chosen at registration

        // ── Loan (repayment side) ────────────────────────────────────
        uint256    loanTarget;
        uint256    loanBalance;
        uint256    loanRepaid;

        // ── Savings (personal side) ──────────────────────────────────
        uint256    savingsBalance;
        uint256    totalDeposited;
        uint256    totalWithdrawn;
        uint256    withdrawalCount;
        uint256    lastDepositAt;
        uint256    firstDepositAt;

        // ── Pot (sits on loan side) ──────────────────────────────────
        uint256    potBalance;
        uint256    potLockedAt;
        uint256    potDeadline;    // [AUD-2] absolute settle deadline, snapshotted

        // ── Packed flags ─────────────────────────────────────────────
        uint8      age;            // 1 byte
        bool       potActive;      // 1 byte
        bool       registered;     // 1 byte
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

    struct PotRecord {
        uint256 amount;
        uint256 lockedAt;
        uint256 settledAt;
        bool    autoSettled;
    }

    // ================================================================
    //                       STATE VARIABLES
    // ================================================================

    IERC20 public stablecoin;

    mapping(address => Lender)            public lenders;
    address[]                             public lenderList;

    mapping(address => Rider)             public riders;
    mapping(address => RiderKYC)          public riderKYC;
    mapping(address => WithdrawalRequest) public withdrawalRequests;

    mapping(address => WithdrawalRecord[]) private _withdrawalHistory;
    mapping(address => PotRecord[])        private _potHistory;

    /// @dev O(1) category lookup — populated once in constructor
    mapping(bytes32 => bool) private _validCategories;

    uint256 public totalLoanCredits;
    uint256 public totalLoanSettled;
    uint256 public totalLockedInPots;

    /// @dev [AUD-4] Aggregate of all rider savings currently held by the contract,
    ///      including amounts sitting in pending/approved withdrawal requests.
    ///      Used by setStablecoin() to confirm the contract is truly empty of
    ///      obligations before a token swap.
    uint256 public totalSavingsHeld;

    // ================================================================
    //                           EVENTS
    // ================================================================

    event LenderAdded(
        address indexed lenderAddress,
        string name,
        uint256 collectionCycle,
        RepaymentSchedule schedule    // [ID-3]
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
        SplitRatio splitRatio         // [ID-2]
    );
    event RiderKYCUpdated(address indexed rider, uint8 newLevel);
    event LoanTargetUpdated(address indexed rider, uint256 oldTarget, uint256 newTarget);

    event Deposit(
        address indexed rider,
        uint256 totalAmount,
        uint256 savingsPart,
        uint256 loanPart,
        uint256 timestamp
    );

    event LoanCleared(address indexed rider, uint256 totalRepaid, uint256 clearedAt);

    event PotLocked(
        address indexed rider,
        uint256 amount,
        uint256 lockedAt,
        uint256 intendedPayAt,
        uint256 autoDeadline
    );
    event PotReleasedByRider(address indexed rider, uint256 amount, uint256 releasedAt);
    event PotAutoSettled(address indexed rider, uint256 amount, uint256 settledAt);
    event PotExcessReturned(address indexed rider, uint256 excess);

    event WithdrawalRequested(
        address indexed rider,
        uint256 amount,
        bytes32 category,
        uint256 requestedAt
    );
    event WithdrawalApproved(address indexed rider, uint256 amount, uint256 approvedAt);
    event WithdrawalDenied(address indexed rider, uint256 amount, uint256 deniedAt);
    event WithdrawalCancelled(address indexed rider, uint256 amount, uint256 cancelledAt); // [AUD-3]
    event WithdrawalClaimed(address indexed rider, uint256 amount, uint256 claimedAt);

    event StablecoinUpdated(address indexed oldStablecoin, address indexed newStablecoin);
    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);

    // ================================================================
    //                         MODIFIERS
    // ================================================================

    modifier onlyRegistered() {
        if (!riders[msg.sender].registered) revert BodaBodaSavings__RiderNotRegistered();
        _;
    }

    modifier onlyVerified() {
        if (!riders[msg.sender].registered)    revert BodaBodaSavings__RiderNotRegistered();
        RiderKYC storage k = riderKYC[msg.sender];
        if (!k.verified)                       revert BodaBodaSavings__RiderNotVerified();
        if (block.timestamp > k.licenseExpiry) revert BodaBodaSavings__LicenseExpired();
        _;
    }

    // ================================================================
    //                        CONSTRUCTOR
    // ================================================================

    /// @param _stablecoin   USDT / MockUSDC address (must implement decimals())
    /// @param _lenderAddrs  Pre-approved lender wallet addresses
    /// @param _lenderNames  Corresponding lender display names
    /// @param _cycles       Collection cycles in seconds per lender
    /// @param _schedules    RepaymentSchedule per lender [ID-3]
    /// @param initialOwner  Deployer / platform admin
    constructor(
        address            _stablecoin,
        address[] memory   _lenderAddrs,
        string[]  memory   _lenderNames,
        uint256[] memory   _cycles,
        RepaymentSchedule[] memory _schedules,  // [ID-3]
        address            initialOwner
    ) Ownable(initialOwner) {
        if (_stablecoin == address(0))
            revert BodaBodaSavings__StablecoinCannotBeZeroAddress();
        if (_lenderAddrs.length == 0)
            revert BodaBodaSavings__NoLendersProvided();
        if (_lenderAddrs.length != _lenderNames.length  ||
            _lenderAddrs.length != _cycles.length       ||
            _lenderAddrs.length != _schedules.length)
            revert BodaBodaSavings__InvalidCollectionCycle();

        (bool ok,) = _stablecoin.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok) revert BodaBodaSavings__InvalidStablecoinContract();

        stablecoin = IERC20(_stablecoin);

        // O(1) category lookup
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
        RepaymentSchedule _schedule    // [ID-3]
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
            schedule:        _schedule,   // [ID-3]
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
    /// @dev    [AUD-2] This only affects pots locked AFTER the change. Active pots
    ///         keep the deadline snapshotted at their own lock time.
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

    /// @notice Rider self-registers after off-chain KYC approval.
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
        // ── Duplicate check ──
        if (riders[msg.sender].registered)
            revert BodaBodaSavings__RiderAlreadyRegistered();

        // ── Identity validation [ID-1] ──
        if (bytes(_name).length == 0)
            revert BodaBodaSavings__NameRequired();
        if (_age < 18 || _age > 65)
            revert BodaBodaSavings__InvalidAge();
        if (_gender != 0x4d && _gender != 0x46 && _gender != 0x4f)  // 'M', 'F', 'O'
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

        // ── Write KYC record ──
        riderKYC[msg.sender] = RiderKYC({
            verificationHash:  _verificationHash,
            verificationLevel: _kycLevel,
            verified:          true,
            verifiedAt:        block.timestamp,
            licenseExpiry:     _licenseExpiry,
            kycProvider:       _kycProvider
        });

        // ── Write rider record ──
        Rider storage r = riders[msg.sender];
        r.name          = _name;           // [ID-1]
        r.age           = _age;            // [ID-1]
        r.gender        = _gender;         // [ID-1]
        r.lenderAddress = _lenderAddress;
        r.splitRatio    = _ratio;          // [ID-2]
        r.loanTarget    = _loanTarget;
        r.registered    = true;

        emit RiderRegistered(
            msg.sender, _name, _lenderAddress, _loanTarget, _kycLevel, _ratio
        );
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

        // [AUD-1] SafeERC20 — reverts on failure / non-standard tokens.
        stablecoin.safeTransferFrom(msg.sender, address(this), amount);

        _applyDeposit(msg.sender, amount);
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

        // Silent approval — emits no on-chain approve tx, just uses signature.
        IERC20Permit(address(stablecoin)).permit(
            msg.sender,
            address(this),
            amount,
            deadline,
            v, r, s
        );

        // [AUD-1] SafeERC20
        stablecoin.safeTransferFrom(msg.sender, address(this), amount);

        _applyDeposit(msg.sender, amount);
    }

    /// @dev Internal: applies the split and updates rider balances.
    function _applyDeposit(address _rider, uint256 amount) internal {
        (uint256 savingsPct,) = _getSplitPercentages(riders[_rider].splitRatio);

        uint256 savingsPart = (amount * savingsPct) / 100;
        uint256 loanPart    = amount - savingsPart;   // remainder goes to loan

        Rider storage r = riders[_rider];
        r.savingsBalance += savingsPart;
        r.loanBalance    += loanPart;
        r.totalDeposited += amount;

        if (r.firstDepositAt == 0) r.firstDepositAt = block.timestamp;
        r.lastDepositAt = block.timestamp;

        totalLoanCredits += loanPart;
        totalSavingsHeld += savingsPart;   // [AUD-4]

        emit Deposit(_rider, amount, savingsPart, loanPart, block.timestamp);
    }

    /// @dev Returns (savingsPct, loanPct) for a given SplitRatio. [ID-2]
    ///      [AUD-5] Reverts on an unrecognised ratio rather than silently
    ///      returning a default, eliminating the latent 70/30-vs-50/50 mismatch.
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
    //                       POT MECHANISM
    // ================================================================

    /// @notice Rider locks loanBalance into the pot to schedule repayment.
    /// @dev    [AUD-2] The auto-settle deadline is snapshotted into r.potDeadline
    ///         here. A later updateLenderCycle() will NOT change it.
    function lockToPot(uint256 amount, uint256 intendedPayAt)
        external
        nonReentrant
        onlyVerified
        whenNotPaused
    {
        if (amount == 0) revert BodaBodaSavings__ZeroAmount();

        Rider storage r = riders[msg.sender];

        if (r.potActive)                      revert BodaBodaSavings__PotAlreadyActive();
        if (r.loanBalance < amount)           revert BodaBodaSavings__InsufficientLoanBalance();
        if (r.loanRepaid >= r.loanTarget)     revert BodaBodaSavings__LoanAlreadyCleared();

        uint256 cycle    = lenders[r.lenderAddress].collectionCycle;
        uint256 deadline = block.timestamp + cycle;

        r.loanBalance -= amount;
        r.potBalance   = amount;
        r.potLockedAt  = block.timestamp;
        r.potDeadline  = deadline;          // [AUD-2] snapshot
        r.potActive    = true;

        totalLockedInPots += amount;

        emit PotLocked(msg.sender, amount, block.timestamp, intendedPayAt, deadline);
    }

    /// @notice Rider voluntarily releases their pot before the deadline.
    function releaseFromPot()
        external
        nonReentrant
        onlyVerified
        whenNotPaused
    {
        Rider storage r = riders[msg.sender];
        if (!r.potActive) revert BodaBodaSavings__NoPotActive();

        uint256 amount = r.potBalance;
        _settlePot(msg.sender, r, false);

        emit PotReleasedByRider(msg.sender, amount, block.timestamp);
    }

    /// @notice Anyone can settle an expired pot — fully autonomous.
    /// @dev    [AUD-2] Settles against the snapshotted r.potDeadline.
    function settleExpiredPot(address _rider) external nonReentrant {
        Rider storage r = riders[_rider];
        if (!r.potActive) revert BodaBodaSavings__NoPotActive();

        if (block.timestamp < r.potDeadline)
            revert BodaBodaSavings__PotDeadlineNotReached();

        uint256 amount = r.potBalance;
        _settlePot(_rider, r, true);

        emit PotAutoSettled(_rider, amount, block.timestamp);
    }

    /// @dev CEI-safe pot settlement. Caps at remaining loan balance, returns excess.
    function _settlePot(address _rider, Rider storage r, bool autoSettled) internal {
        uint256 amount = r.potBalance;

        uint256 remaining = r.loanTarget > r.loanRepaid
            ? r.loanTarget - r.loanRepaid
            : 0;

        uint256 toSettle = amount > remaining ? remaining : amount;
        uint256 excess   = amount - toSettle;

        // ── Effects ──
        r.loanRepaid      += toSettle;
        totalLoanSettled  += toSettle;
        totalLockedInPots -= amount;

        if (excess > 0) r.loanBalance += excess;

        _potHistory[_rider].push(PotRecord({
            amount:      toSettle,
            lockedAt:    r.potLockedAt,
            settledAt:   block.timestamp,
            autoSettled: autoSettled
        }));

        r.potBalance  = 0;
        r.potLockedAt = 0;
        r.potDeadline = 0;            // [AUD-2] clear snapshot
        r.potActive   = false;

        // ── Interaction ──
        // [AUD-1] SafeERC20
        stablecoin.safeTransfer(r.lenderAddress, toSettle);

        if (excess > 0)  emit PotExcessReturned(_rider, excess);
        if (r.loanRepaid >= r.loanTarget && r.loanTarget > 0) {
            emit LoanCleared(_rider, r.loanRepaid, block.timestamp);
        }
    }

    // ================================================================
    //               SAVINGS WITHDRAWAL  (3-step approval flow)
    // ================================================================

    /// @notice Step 1 — Rider submits a withdrawal request.
    function requestWithdrawal(uint256 amount, bytes32 category)
        external
        nonReentrant
        onlyVerified
        whenNotPaused
    {
        if (amount == 0)                       revert BodaBodaSavings__ZeroWithdrawAmount();
        if (!_validCategories[category])       revert BodaBodaSavings__InvalidWithdrawalCategory();

        Rider storage r = riders[msg.sender];
        if (r.savingsBalance < amount)         revert BodaBodaSavings__InsufficientSavings();

        WithdrawalRequest storage req = withdrawalRequests[msg.sender];
        if (req.status == WithdrawalStatus.Pending ||
            req.status == WithdrawalStatus.Approved)
            revert BodaBodaSavings__WithdrawalAlreadyPending();

        // Amount leaves spendable savings but is still "held" by the contract
        // on the rider's behalf — totalSavingsHeld is unchanged here. [AUD-4]
        r.savingsBalance -= amount;

        withdrawalRequests[msg.sender] = WithdrawalRequest({
            amount:      amount,
            category:    category,
            requestedAt: block.timestamp,
            approvedAt:  0,
            status:      WithdrawalStatus.Pending
        });

        emit WithdrawalRequested(msg.sender, amount, category, block.timestamp);
    }

    /// @notice Step 2a — Owner approves.
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

    /// @notice [AUD-3] Owner revokes an ALREADY-APPROVED request, returning the
    ///         funds to the rider's spendable savings. Closes the stuck-state where
    ///         an approved-but-unclaimable request could trap funds (e.g. if the
    ///         rider can no longer claim for some reason).
    function revokeApprovedWithdrawal(address _rider) external onlyOwner {
        WithdrawalRequest storage req = withdrawalRequests[_rider];
        if (req.status != WithdrawalStatus.Approved) revert BodaBodaSavings__WithdrawalNotApproved();

        uint256 amount = req.amount;
        riders[_rider].savingsBalance += amount;

        delete withdrawalRequests[_rider];

        emit WithdrawalDenied(_rider, amount, block.timestamp);
    }

    /// @notice [AUD-3] Rider cancels their OWN pending or approved request and
    ///         returns the amount to spendable savings. Uses onlyRegistered so a
    ///         rider whose KYC/licence has lapsed can still recover their money.
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
    /// @dev    [AUD-3] Uses onlyRegistered, NOT onlyVerified. Savings are the
    ///         rider's own money; returning them must not be blocked by an
    ///         expired licence or KYC lapse that occurs during the delay window.
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

        // [AUD-4] Money actually leaves the contract now.
        totalSavingsHeld -= amount;

        _withdrawalHistory[msg.sender].push(WithdrawalRecord({
            amount:      amount,
            category:    category,
            requestedAt: reqAt,
            claimedAt:   block.timestamp
        }));

        delete withdrawalRequests[msg.sender];

        // [AUD-1] SafeERC20
        stablecoin.safeTransfer(msg.sender, amount);

        emit WithdrawalClaimed(msg.sender, amount, block.timestamp);
    }

    // ================================================================
    //                      VIEW FUNCTIONS
    // ================================================================

    /// @notice Full rider profile — identity + lender info + split ratio. [ID-6]
    function getRiderProfile(address _rider)
        external
        view
        returns (
            string  memory name,
            uint8          age,
            bytes1         gender,
            bool           registered,
            address        lenderAddress,
            string  memory lenderName,
            RepaymentSchedule lenderSchedule,
            SplitRatio     splitRatio,
            uint256        loanTarget
        )
    {
        Rider  storage r = riders[_rider];
        Lender storage l = lenders[r.lenderAddress];
        return (
            r.name,
            r.age,
            r.gender,
            r.registered,
            r.lenderAddress,
            l.name,
            l.schedule,
            r.splitRatio,
            r.loanTarget
        );
    }

    /// @notice Full analytics snapshot — powers the financial dashboard.
    /// @dev    [AUD-2] potDeadline now returns the snapshotted absolute deadline.
    function getRiderAnalytics(address _rider)
        external
        view
        returns (
            uint256 savingsBalance,
            uint256 loanBalance,
            uint256 totalDeposited,
            uint256 totalWithdrawn,
            uint256 withdrawalCount,
            uint256 lastDepositAt,
            uint256 firstDepositAt,
            bool    potActive,
            uint256 potBalance,
            uint256 potLockedAt,
            uint256 potDeadline
        )
    {
        Rider storage r = riders[_rider];
        return (
            r.savingsBalance,
            r.loanBalance,
            r.totalDeposited,
            r.totalWithdrawn,
            r.withdrawalCount,
            r.lastDepositAt,
            r.firstDepositAt,
            r.potActive,
            r.potBalance,
            r.potLockedAt,
            r.potActive ? r.potDeadline : 0    // [AUD-2]
        );
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
        loanRemaining = r.loanRepaid >= r.loanTarget
            ? 0
            : r.loanTarget - r.loanRepaid;
        isCleared     = r.loanRepaid >= r.loanTarget && r.loanTarget > 0;
        progressBps   = r.loanTarget > 0
            ? (r.loanRepaid * 10_000) / r.loanTarget
            : 0;
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
            k.verificationHash,
            k.verificationLevel,
            k.verifiedAt,
            k.licenseExpiry,
            k.kycProvider,
            k.verified
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
            req.amount,
            req.category,
            req.requestedAt,
            req.approvedAt,
            req.approvedAt > 0 ? req.approvedAt + WITHDRAWAL_DELAY : 0,
            req.status
        );
    }

    function getWithdrawalHistory(address _rider)
        external
        view
        returns (WithdrawalRecord[] memory)
    {
        return _withdrawalHistory[_rider];
    }

    function getPotHistory(address _rider)
        external
        view
        returns (PotRecord[] memory)
    {
        return _potHistory[_rider];
    }

    function getIdleLoanBalance() external view returns (uint256) {
        return totalLoanCredits - totalLoanSettled - totalLockedInPots;
    }

    function getLockedPotTotal() external view returns (uint256) {
        return totalLockedInPots;
    }

    function getContractBalance() external view returns (uint256) {
        return stablecoin.balanceOf(address(this));
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
            RepaymentSchedule schedule,     // [ID-3]
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

    /// @notice Swap stablecoin address.
    /// @dev    [AUD-4] Requires that the contract holds no obligations at all —
    ///         every internal aggregate counter must be zero, not just the live
    ///         token balance (dust or in-flight withdrawals could otherwise allow
    ///         a swap that mis-denominates rider balances). Also enforces that the
    ///         new token reports the SAME decimals as the old one, since all
    ///         internal balances are stored in token-native units.
    function setStablecoin(address _stablecoin) external onlyOwner {
        if (_stablecoin == address(0))
            revert BodaBodaSavings__StablecoinCannotBeZeroAddress();

        // New token must implement decimals().
        (bool ok, bytes memory data) =
            _stablecoin.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length < 32) revert BodaBodaSavings__InvalidStablecoinContract();

        // Decimals must match the existing token. [AUD-4]
        uint8 newDecimals = abi.decode(data, (uint8));
        uint8 oldDecimals = IERC20Metadata(address(stablecoin)).decimals();
        if (newDecimals != oldDecimals) revert BodaBodaSavings__DecimalsMismatch();

        // No outstanding obligations in internal accounting. [AUD-4]
        if (totalSavingsHeld != 0 || totalLockedInPots != 0 ||
            (totalLoanCredits - totalLoanSettled) != 0)
            revert BodaBodaSavings__OutstandingAccounting();

        // Belt-and-braces: live balance must also be zero.
        if (stablecoin.balanceOf(address(this)) != 0)
            revert BodaBodaSavings__ContractBalanceMustBeZero();

        address old = address(stablecoin);
        stablecoin  = IERC20(_stablecoin);
        emit StablecoinUpdated(old, _stablecoin);
    }

    /// @notice Recover accidentally sent non-stablecoin ERC20 tokens.
    function recoverERC20(address _token, address _to, uint256 _amount) external onlyOwner {
        if (_to    == address(0)) revert BodaBodaSavings__ZeroAddress();
        if (_token == address(0)) revert BodaBodaSavings__ZeroAddressToken();
        if (_token == address(stablecoin)) revert BodaBodaSavings__CannotRecoverStablecoin();

        // [AUD-1] SafeERC20
        IERC20(_token).safeTransfer(_to, _amount);

        emit ERC20Recovered(_token, _to, _amount);
    }
}
