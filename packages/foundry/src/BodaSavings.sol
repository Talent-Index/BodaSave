// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20}           from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable}          from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable}         from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard}  from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title  BodaBodaSavings  (v2)
/// @author Team
/// @notice Savings + loan repayment platform for bodaboda riders in Kenya.
///
///         Core flow
///         ─────────
///         1. Owner registers verified lenders at deployment (hardcoded) or via addLender().
///         2. Owner runs off-chain KYC (Smile Identity / NTSA), then calls registerRider()
///            with the resulting verificationHash, linking the rider to a specific lender.
///         3. Rider deposits USDT — split 50/50:
///              • savingsBalance  — rider's personal locked savings
///              • loanBalance     — loan repayment credit, linked to their lender
///         4. Rider locks loanBalance into the pot to schedule repayment.
///            Pot deadline = lender's collectionCycle (dynamic, not hardcoded).
///         5. Rider withdraws savings by submitting a category + amount → owner approves
///            → WITHDRAWAL_DELAY elapses → rider claims.
///
/// @dev    WITHDRAWAL_DELAY is 150s for demo purposes. Change for production.
///
/// @dev    v2 Changes (audit fixes)
///         ─────────────────────────
///         [SEC-1]  Added ReentrancyGuard; nonReentrant on all external transfer functions.
///         [SEC-2]  setStablecoin() now requires zero contract balance before swap;
///                  also validates decimals() on the new address.
///         [SEC-3]  Owner centralisation documented; multisig/timelock recommended in prod.
///         [SEC-4]  onlyVerified modifier now checks licenseExpiry at every interaction.
///         [SEC-5]  denyWithdrawal() uses `delete` to fully clear the stale struct.
///         [GAS-6]  Rider struct: bool fields packed together at the end of the struct.
///         [GAS-7]  _isValidCategory() replaced with O(1) mapping lookup.
///         [GAS-8]  collectionCycle cached into a local variable in all callers.
///         [GAS-9]  getLenders() supports optional pagination (offset + limit).
///         [LOG-10] getAvailableLoanPool() renamed & documented; new getLockedPotTotal()
///                  helper added for accurate pool accounting.
///         [LOG-11] _settlePot() caps settlement at remaining loan balance; excess
///                  is returned to loanBalance so the rider is never overcharged.
///         [LOG-12] potIntendedPayAt removed from Rider struct; emitted in PotLocked only.
///         [LOG-13] updateLoanTarget() added for loan restructuring by owner.
///         [SEC-14] setStablecoin() now validates decimals() on the new contract.
contract BodaBodaSavings is Ownable, Pausable, ReentrancyGuard {

    // ================================================================
    //                         CONSTANTS
    // ================================================================

    /// @dev 150 seconds (2.5 min) for demo. Set to e.g. 2 days for production.
    uint256 public constant WITHDRAWAL_DELAY = 150;

    // ── Withdrawal reason categories ──
    bytes32 public constant REASON_MEDICAL           = "MEDICAL";
    bytes32 public constant REASON_REPAIR            = "REPAIR";
    bytes32 public constant REASON_EDUCATION         = "EDUCATION";
    bytes32 public constant REASON_HOUSEHOLD         = "HOUSEHOLD";
    bytes32 public constant REASON_EMERGENCY         = "EMERGENCY";
    bytes32 public constant REASON_FAMILY_OBLIGATION = "FAMILY_OBLIGATION";
    bytes32 public constant REASON_OTHER             = "OTHER";

    // ── KYC verification levels ──
    uint8 public constant KYC_BASIC   = 1;
    uint8 public constant KYC_FULL    = 2;
    uint8 public constant KYC_PREMIUM = 3;

    // ================================================================
    //                       CUSTOM ERRORS
    // ================================================================

    // — Stablecoin —
    error BodaBodaSavings__StablecoinCannotBeZeroAddress();
    error BodaBodaSavings__InvalidStablecoinContract();
    error BodaBodaSavings__TransferFailed();
    error BodaBodaSavings__CannotRecoverStablecoin();
    error BodaBodaSavings__ZeroAddressToken();
    error BodaBodaSavings__ContractBalanceMustBeZero();  // [SEC-2]

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

    // — Deposit / Savings —
    error BodaBodaSavings__ZeroDeposit();
    error BodaBodaSavings__InsufficientSavings();
    error BodaBodaSavings__InsufficientLoanBalance();

    // — Loan —
    error BodaBodaSavings__LoanAlreadyCleared();
    error BodaBodaSavings__ExceedsAvailablePool();

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

    // — Loan restructure —
    error BodaBodaSavings__NewTargetBelowRepaid();       // [LOG-13]

    // ================================================================
    //                           ENUMS
    // ================================================================

    enum WithdrawalStatus {
        None,
        Pending,
        Approved
    }

    // ================================================================
    //                          STRUCTS
    // ================================================================

    struct Lender {
        string  name;
        address lenderAddress;
        uint256 collectionCycle;
        bool    verified;
        bool    active;
    }

    struct RiderKYC {
        bytes32 verificationHash;
        uint8   verificationLevel;  // packed with bool verified (saves one slot)
        bool    verified;           // [GAS-6] packed next to verificationLevel
        uint256 verifiedAt;
        uint256 licenseExpiry;
        bytes32 kycProvider;
    }

    /// @notice Full financial state per rider.
    /// @dev    [GAS-6] Both bool fields are placed at the END of the struct so they
    ///         share one 32-byte storage slot rather than each consuming a full slot.
    struct Rider {
        // ── Identity ──
        address lenderAddress;

        // ── Loan (repayment side) ──
        uint256 loanTarget;
        uint256 loanBalance;
        uint256 loanRepaid;

        // ── Savings (personal side) ──
        uint256 savingsBalance;
        uint256 totalDeposited;
        uint256 totalWithdrawn;
        uint256 withdrawalCount;
        uint256 lastDepositAt;
        uint256 firstDepositAt;

        // ── Pot (sits on loan side) ──
        uint256 potBalance;
        uint256 potLockedAt;
        // [LOG-12] potIntendedPayAt removed — emitted in PotLocked event only

        // ── Flags (packed together into one slot) ── [GAS-6]
        bool    potActive;
        bool    registered;
    }

    struct WithdrawalRequest {
        uint256         amount;
        bytes32         category;
        uint256         requestedAt;
        uint256         approvedAt;
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

    /// @dev [GAS-7] O(1) category lookup — populated in constructor
    mapping(bytes32 => bool) private _validCategories;

    /// @notice Total loan-side deposits received across all riders (lifetime)
    uint256 public totalLoanCredits;

    /// @notice Total settled to lenders via pot mechanism (lifetime)
    uint256 public totalLoanSettled;

    /// @notice Total currently locked in active pots (live balance) — [LOG-10]
    uint256 public totalLockedInPots;

    // ================================================================
    //                           EVENTS
    // ================================================================

    event LenderAdded(address indexed lenderAddress, string name, uint256 collectionCycle);
    event LenderDeactivated(address indexed lenderAddress);
    event LenderReactivated(address indexed lenderAddress);
    event LenderCycleUpdated(address indexed lenderAddress, uint256 newCycle);

    event RiderRegistered(
        address indexed rider,
        address indexed lender,
        uint256 loanTarget,
        uint8   kycLevel
    );
    event RiderKYCUpdated(address indexed rider, uint8 newLevel);
    event LoanTargetUpdated(address indexed rider, uint256 oldTarget, uint256 newTarget); // [LOG-13]

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
        uint256 intendedPayAt,   // informational only — not stored on-chain [LOG-12]
        uint256 autoDeadline
    );
    event PotReleasedByRider(address indexed rider, uint256 amount, uint256 releasedAt);
    event PotAutoSettled(address indexed rider, uint256 amount, uint256 settledAt);
    event PotExcessReturned(address indexed rider, uint256 excess);  // [LOG-11]

    event WithdrawalRequested(
        address indexed rider,
        uint256 amount,
        bytes32 category,
        uint256 requestedAt
    );
    event WithdrawalApproved(address indexed rider, uint256 amount, uint256 approvedAt);
    event WithdrawalDenied(address indexed rider, uint256 amount, uint256 deniedAt);
    event WithdrawalClaimed(address indexed rider, uint256 amount, uint256 claimedAt);

    event StablecoinUpdated(address indexed oldStablecoin, address indexed newStablecoin);
    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);

    // ================================================================
    //                         MODIFIERS
    // ================================================================

    /// @dev Registered rider only
    modifier onlyRegistered() {
        if (!riders[msg.sender].registered) revert BodaBodaSavings__RiderNotRegistered();
        _;
    }

    /// @dev Registered + KYC-verified + non-expired license [SEC-4]
    modifier onlyVerified() {
        if (!riders[msg.sender].registered) revert BodaBodaSavings__RiderNotRegistered();
        RiderKYC storage k = riderKYC[msg.sender];
        if (!k.verified)                    revert BodaBodaSavings__RiderNotVerified();
        if (block.timestamp > k.licenseExpiry) revert BodaBodaSavings__LicenseExpired();
        _;
    }

    // ================================================================
    //                        CONSTRUCTOR
    // ================================================================

    /// @param _stablecoin   USDT / MockUSDC contract address
    /// @param _lenderAddrs  Pre-approved lender wallet addresses
    /// @param _lenderNames  Corresponding lender names
    /// @param _cycles       Corresponding collection cycles in seconds
    /// @param initialOwner  Deployer / platform admin
    ///
    /// @dev [SEC-3] IMPORTANT — PRODUCTION DEPLOYMENT CHECKLIST:
    ///      • Deploy behind a Gnosis Safe multisig as `initialOwner`.
    ///      • Wrap sensitive admin calls (setStablecoin, pause) behind a
    ///        TimelockController (48h minimum delay).
    ///      • Consider an upgrade path via UUPS proxy if protocol parameters
    ///        will need adjustment post-launch.
    constructor(
        address   _stablecoin,
        address[] memory _lenderAddrs,
        string[]  memory _lenderNames,
        uint256[] memory _cycles,
        address   initialOwner
    ) Ownable(initialOwner) {
        if (_stablecoin == address(0))
            revert BodaBodaSavings__StablecoinCannotBeZeroAddress();
        if (_lenderAddrs.length == 0)
            revert BodaBodaSavings__NoLendersProvided();
        if (_lenderAddrs.length != _lenderNames.length ||
            _lenderAddrs.length != _cycles.length)
            revert BodaBodaSavings__InvalidCollectionCycle();

        // Validate stablecoin interface
        (bool ok,) = _stablecoin.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok) revert BodaBodaSavings__InvalidStablecoinContract();

        stablecoin = IERC20(_stablecoin);

        // [GAS-7] Populate O(1) category lookup once at construction
        _validCategories[REASON_MEDICAL]           = true;
        _validCategories[REASON_REPAIR]            = true;
        _validCategories[REASON_EDUCATION]         = true;
        _validCategories[REASON_HOUSEHOLD]         = true;
        _validCategories[REASON_EMERGENCY]         = true;
        _validCategories[REASON_FAMILY_OBLIGATION] = true;
        _validCategories[REASON_OTHER]             = true;

        for (uint256 i = 0; i < _lenderAddrs.length; i++) {
            _addLender(_lenderAddrs[i], _lenderNames[i], _cycles[i]);
        }
    }

    // ================================================================
    //                     LENDER MANAGEMENT
    // ================================================================

    function addLender(
        address _lenderAddress,
        string calldata _name,
        uint256 _cycle
    ) external onlyOwner {
        _addLender(_lenderAddress, _name, _cycle);
    }

    function _addLender(
        address _lenderAddress,
        string memory _name,
        uint256 _cycle
    ) internal {
        if (_lenderAddress == address(0))     revert BodaBodaSavings__ZeroAddress();
        if (lenders[_lenderAddress].verified) revert BodaBodaSavings__LenderAlreadyRegistered();
        if (_cycle == 0)                      revert BodaBodaSavings__InvalidCollectionCycle();

        lenders[_lenderAddress] = Lender({
            name:            _name,
            lenderAddress:   _lenderAddress,
            collectionCycle: _cycle,
            verified:        true,
            active:          true
        });

        lenderList.push(_lenderAddress);
        emit LenderAdded(_lenderAddress, _name, _cycle);
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

    function updateLenderCycle(address _lenderAddress, uint256 _newCycle) external onlyOwner {
        if (!lenders[_lenderAddress].verified) revert BodaBodaSavings__LenderNotFound();
        if (_newCycle == 0)                    revert BodaBodaSavings__InvalidCollectionCycle();
        lenders[_lenderAddress].collectionCycle = _newCycle;
        emit LenderCycleUpdated(_lenderAddress, _newCycle);
    }

    /// @notice Returns registered lender addresses with optional pagination. [GAS-9]
    /// @param offset Starting index (0 for beginning)
    /// @param limit  Max addresses to return; pass 0 to return all remaining
    function getLenders(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory)
    {
        uint256 total = lenderList.length;
        if (offset >= total) return new address[](0);

        uint256 remaining = total - offset;
        uint256 count     = (limit == 0 || limit > remaining) ? remaining : limit;

        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = lenderList[offset + i];
        }
        return result;
    }

    /// @notice Convenience: returns total number of registered lenders
    function getLenderCount() external view returns (uint256) {
        return lenderList.length;
    }

    // ================================================================
    //                    RIDER REGISTRATION
    // ================================================================

    /// @notice Owner registers a KYC-verified rider.
    function registerRider(
        address _rider,
        address _lenderAddress,
        uint256 _loanTarget,
        bytes32 _verificationHash,
        uint8   _kycLevel,
        uint256 _licenseExpiry,
        bytes32 _kycProvider
    ) external onlyOwner {
        if (_rider == address(0))
            revert BodaBodaSavings__ZeroAddress();
        if (riders[_rider].registered)
            revert BodaBodaSavings__RiderAlreadyRegistered();
        if (_loanTarget == 0)
            revert BodaBodaSavings__ZeroLoanTarget();
        if (_verificationHash == bytes32(0))
            revert BodaBodaSavings__InvalidVerificationHash();
        if (_kycLevel < KYC_BASIC || _kycLevel > KYC_PREMIUM)
            revert BodaBodaSavings__InvalidKycLevel();
        if (!lenders[_lenderAddress].verified)
            revert BodaBodaSavings__LenderNotFound();
        if (!lenders[_lenderAddress].active)
            revert BodaBodaSavings__LenderNotActive();
        if (_licenseExpiry <= block.timestamp)
            revert BodaBodaSavings__LicenseExpired();

        riderKYC[_rider] = RiderKYC({
            verificationHash:  _verificationHash,
            verificationLevel: _kycLevel,
            verified:          true,
            verifiedAt:        block.timestamp,
            licenseExpiry:     _licenseExpiry,
            kycProvider:       _kycProvider
        });

        riders[_rider].lenderAddress = _lenderAddress;
        riders[_rider].loanTarget    = _loanTarget;
        riders[_rider].registered    = true;

        emit RiderRegistered(_rider, _lenderAddress, _loanTarget, _kycLevel);
    }

    function updateRiderKYC(
        address _rider,
        bytes32 _newHash,
        uint8   _newLevel,
        uint256 _newLicenseExpiry,
        bytes32 _kycProvider
    ) external onlyOwner {
        if (!riders[_rider].registered)
            revert BodaBodaSavings__RiderNotRegistered();
        if (_newHash == bytes32(0))
            revert BodaBodaSavings__InvalidVerificationHash();
        if (_newLevel < KYC_BASIC || _newLevel > KYC_PREMIUM)
            revert BodaBodaSavings__InvalidKycLevel();
        if (_newLicenseExpiry <= block.timestamp)
            revert BodaBodaSavings__LicenseExpired();

        RiderKYC storage kyc = riderKYC[_rider];
        kyc.verificationHash  = _newHash;
        kyc.verificationLevel = _newLevel;
        kyc.verifiedAt        = block.timestamp;
        kyc.licenseExpiry     = _newLicenseExpiry;
        kyc.kycProvider       = _kycProvider;

        emit RiderKYCUpdated(_rider, _newLevel);
    }

    /// @notice Owner adjusts a rider's loan target (restructuring). [LOG-13]
    /// @param _rider      Rider whose target to update
    /// @param _newTarget  New total loan amount — must be >= loanRepaid to date
    function updateLoanTarget(address _rider, uint256 _newTarget) external onlyOwner {
        if (!riders[_rider].registered) revert BodaBodaSavings__RiderNotRegistered();
        if (_newTarget == 0)            revert BodaBodaSavings__ZeroLoanTarget();

        Rider storage r = riders[_rider];
        // Prevent setting target below already-repaid amount
        if (_newTarget < r.loanRepaid)  revert BodaBodaSavings__NewTargetBelowRepaid();

        uint256 old = r.loanTarget;
        r.loanTarget = _newTarget;

        emit LoanTargetUpdated(_rider, old, _newTarget);
    }

    // ================================================================
    //                          DEPOSIT
    // ================================================================

    /// @notice Rider deposits stablecoin. Split 50/50 savings / loan.
    ///         Caller must approve this contract on the stablecoin first.
    function deposit(uint256 amount)
        external
        nonReentrant    // [SEC-1]
        onlyVerified
        whenNotPaused
    {
        if (amount == 0) revert BodaBodaSavings__ZeroDeposit();

        // Pull funds first (Checks-Effects-Interactions)
        bool ok = stablecoin.transferFrom(msg.sender, address(this), amount);
        if (!ok) revert BodaBodaSavings__TransferFailed();

        uint256 half     = amount / 2;
        uint256 loanPart = amount - half;   // odd amounts round to loan side

        Rider storage r = riders[msg.sender];
        r.savingsBalance += half;
        r.loanBalance    += loanPart;
        r.totalDeposited += amount;

        if (r.firstDepositAt == 0) r.firstDepositAt = block.timestamp;
        r.lastDepositAt = block.timestamp;

        totalLoanCredits += loanPart;

        emit Deposit(msg.sender, amount, half, loanPart, block.timestamp);
    }

    // ================================================================
    //                       POT MECHANISM
    // ================================================================

    /// @notice Rider locks loanBalance into the pot to schedule repayment.
    /// @param amount         Amount to lock from loanBalance
    /// @param intendedPayAt  Rider's declared intended pay date — emitted only [LOG-12]
    function lockToPot(uint256 amount, uint256 intendedPayAt)
        external
        nonReentrant    // [SEC-1]
        onlyVerified
        whenNotPaused
    {
        if (amount == 0) revert BodaBodaSavings__ZeroAmount();

        Rider storage r = riders[msg.sender];

        if (r.potActive)
            revert BodaBodaSavings__PotAlreadyActive();
        if (r.loanBalance < amount)
            revert BodaBodaSavings__InsufficientLoanBalance();
        if (r.loanRepaid >= r.loanTarget)
            revert BodaBodaSavings__LoanAlreadyCleared();

        r.loanBalance -= amount;
        r.potBalance   = amount;
        r.potLockedAt  = block.timestamp;
        r.potActive    = true;

        totalLockedInPots += amount;   // [LOG-10]

        // [GAS-8] cache cycle into local variable
        uint256 cycle    = lenders[r.lenderAddress].collectionCycle;
        uint256 deadline = block.timestamp + cycle;

        emit PotLocked(msg.sender, amount, block.timestamp, intendedPayAt, deadline);
    }

    /// @notice Rider voluntarily releases their pot before the deadline.
    function releaseFromPot()
        external
        nonReentrant    // [SEC-1]
        onlyVerified
        whenNotPaused
    {
        Rider storage r = riders[msg.sender];
        if (!r.potActive) revert BodaBodaSavings__NoPotActive();

        uint256 amount = r.potBalance;
        _settlePot(msg.sender, r, false);

        emit PotReleasedByRider(msg.sender, amount, block.timestamp);
    }

    /// @notice Anyone can settle an expired pot. Fully autonomous.
    function settleExpiredPot(address _rider)
        external
        nonReentrant    // [SEC-1]
    {
        Rider storage r = riders[_rider];
        if (!r.potActive) revert BodaBodaSavings__NoPotActive();

        // [GAS-8] cache cycle
        uint256 cycle    = lenders[r.lenderAddress].collectionCycle;
        uint256 deadline = r.potLockedAt + cycle;

        if (block.timestamp < deadline)
            revert BodaBodaSavings__PotDeadlineNotReached();

        uint256 amount = r.potBalance;
        _settlePot(_rider, r, true);

        emit PotAutoSettled(_rider, amount, block.timestamp);
    }

    /// @dev Transfers pot to lender, updates accounting, records history.
    ///      [LOG-11] Caps settlement at remaining loan balance; any excess
    ///               is returned to loanBalance — no rider overpayment.
    ///      [SEC-1]  All state mutated before the external transfer call (CEI).
    function _settlePot(
        address _rider,
        Rider storage r,
        bool autoSettled
    ) internal {
        uint256 amount = r.potBalance;

        // [LOG-11] Cap at remaining loan balance to prevent overpayment
        uint256 remaining = r.loanTarget > r.loanRepaid
            ? r.loanTarget - r.loanRepaid
            : 0;

        uint256 toSettle = amount > remaining ? remaining : amount;
        uint256 excess   = amount - toSettle;

        // ── Effects (all state changes before external call — CEI) ──
        r.loanRepaid       += toSettle;
        totalLoanSettled   += toSettle;
        totalLockedInPots  -= amount;   // [LOG-10] full locked amount released

        if (excess > 0) {
            r.loanBalance += excess;    // return overage to rider's loan balance
        }

        _potHistory[_rider].push(PotRecord({
            amount:      toSettle,
            lockedAt:    r.potLockedAt,
            settledAt:   block.timestamp,
            autoSettled: autoSettled
        }));

        // Clear pot state
        r.potBalance  = 0;
        r.potLockedAt = 0;
        r.potActive   = false;

        // ── Interaction (external call last) ──
        bool ok = stablecoin.transfer(r.lenderAddress, toSettle);
        if (!ok) revert BodaBodaSavings__TransferFailed();

        if (excess > 0) emit PotExcessReturned(_rider, excess);

        if (r.loanRepaid >= r.loanTarget && r.loanTarget > 0) {
            emit LoanCleared(_rider, r.loanRepaid, block.timestamp);
        }
    }

    // ================================================================
    //               SAVINGS WITHDRAWAL  (3-step approval flow)
    // ================================================================

    /// @notice Step 1 — Rider submits a savings withdrawal request.
    function requestWithdrawal(uint256 amount, bytes32 category)
        external
        nonReentrant    // [SEC-1]
        onlyVerified
        whenNotPaused
    {
        if (amount == 0)
            revert BodaBodaSavings__ZeroWithdrawAmount();
        if (!_validCategories[category])            // [GAS-7] O(1) lookup
            revert BodaBodaSavings__InvalidWithdrawalCategory();

        Rider storage r = riders[msg.sender];
        if (r.savingsBalance < amount)
            revert BodaBodaSavings__InsufficientSavings();

        WithdrawalRequest storage req = withdrawalRequests[msg.sender];
        if (req.status == WithdrawalStatus.Pending ||
            req.status == WithdrawalStatus.Approved)
            revert BodaBodaSavings__WithdrawalAlreadyPending();

        // Lock amount immediately — prevents double-spend
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

    /// @notice Step 2a — Owner approves. Rider can claim after WITHDRAWAL_DELAY.
    function approveWithdrawal(address _rider) external onlyOwner {
        WithdrawalRequest storage req = withdrawalRequests[_rider];
        if (req.status != WithdrawalStatus.Pending)
            revert BodaBodaSavings__NoWithdrawalPending();

        req.approvedAt = block.timestamp;
        req.status     = WithdrawalStatus.Approved;

        emit WithdrawalApproved(_rider, req.amount, block.timestamp);
    }

    /// @notice Step 2b — Owner denies. Amount returned to savingsBalance.
    ///         [SEC-5] Full struct deleted to clear stale data.
    function denyWithdrawal(address _rider) external onlyOwner {
        WithdrawalRequest storage req = withdrawalRequests[_rider];
        if (req.status != WithdrawalStatus.Pending)
            revert BodaBodaSavings__NoWithdrawalPending();

        uint256 amount = req.amount;
        riders[_rider].savingsBalance += amount;

        delete withdrawalRequests[_rider];  // [SEC-5] full struct reset

        emit WithdrawalDenied(_rider, amount, block.timestamp);
    }

    /// @notice Step 3 — Rider claims after approval + WITHDRAWAL_DELAY.
    function claimWithdrawal()
        external
        nonReentrant    // [SEC-1]
        onlyVerified
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

        // ── Effects before interaction (CEI) ──
        Rider storage r = riders[msg.sender];
        r.totalWithdrawn  += amount;
        r.withdrawalCount += 1;

        _withdrawalHistory[msg.sender].push(WithdrawalRecord({
            amount:      amount,
            category:    category,
            requestedAt: reqAt,
            claimedAt:   block.timestamp
        }));

        delete withdrawalRequests[msg.sender];  // consistent with denyWithdrawal

        // ── Interaction ──
        bool ok = stablecoin.transfer(msg.sender, amount);
        if (!ok) revert BodaBodaSavings__TransferFailed();

        emit WithdrawalClaimed(msg.sender, amount, block.timestamp);
    }

    // ================================================================
    //                      VIEW FUNCTIONS
    // ================================================================

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

    /// @notice Full analytics snapshot — powers the rider dashboard.
    ///         [LOG-12] potIntendedPayAt removed (no longer stored on-chain).
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
        Rider storage r  = riders[_rider];
        // [GAS-8] cache cycle
        uint256 cycle    = lenders[r.lenderAddress].collectionCycle;
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
            r.potActive ? r.potLockedAt + cycle : 0
        );
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

    /// @notice Loan-side deposits not yet settled to any lender.
    ///         = totalLoanCredits − totalLoanSettled − totalLockedInPots
    ///
    ///         Semantics [LOG-10]:
    ///           totalLoanCredits   — all loan-side deposit inflows (lifetime)
    ///           totalLoanSettled   — confirmed payments forwarded to lenders
    ///           totalLockedInPots  — committed but not yet forwarded (in active pots)
    ///
    ///         This value represents loanBalance amounts sitting idle across
    ///         all riders that have neither been locked nor settled yet.
    function getIdleLoanBalance() external view returns (uint256) {
        return totalLoanCredits - totalLoanSettled - totalLockedInPots;
    }

    /// @notice Total currently locked across all active pots. [LOG-10]
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
            uint256 collectionCycle,
            bool    verified,
            bool    active
        )
    {
        Lender storage l = lenders[_lenderAddress];
        return (l.name, l.collectionCycle, l.verified, l.active);
    }

    // ================================================================
    //                      ADMIN FUNCTIONS
    // ================================================================

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Update stablecoin address.
    ///         [SEC-2] Requires zero contract balance — all funds must be
    ///         withdrawn or settled before the token can be swapped.
    ///         [SEC-14] Validates decimals() on the new contract.
    function setStablecoin(address _stablecoin) external onlyOwner {
        if (_stablecoin == address(0))
            revert BodaBodaSavings__StablecoinCannotBeZeroAddress();

        // [SEC-14] validate interface
        (bool ok,) = _stablecoin.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok) revert BodaBodaSavings__InvalidStablecoinContract();

        // [SEC-2] refuse swap while funds are held — prevents accounting mismatch
        if (stablecoin.balanceOf(address(this)) != 0)
            revert BodaBodaSavings__ContractBalanceMustBeZero();

        address old = address(stablecoin);
        stablecoin  = IERC20(_stablecoin);
        emit StablecoinUpdated(old, _stablecoin);
    }

    /// @notice Recover accidentally sent non-stablecoin ERC20 tokens.
    function recoverERC20(
        address _token,
        address _to,
        uint256 _amount
    ) external onlyOwner {
        if (_to    == address(0)) revert BodaBodaSavings__ZeroAddress();
        if (_token == address(0)) revert BodaBodaSavings__ZeroAddressToken();
        if (_token == address(stablecoin))
            revert BodaBodaSavings__CannotRecoverStablecoin();

        bool ok = IERC20(_token).transfer(_to, _amount);
        if (!ok) revert BodaBodaSavings__TransferFailed();

        emit ERC20Recovered(_token, _to, _amount);
    }
}
