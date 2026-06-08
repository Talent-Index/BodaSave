"use client";

import { useEffect, useState } from "react";
import { formatUnits, keccak256, parseUnits, stringToHex } from "viem";
import {
  useAccount,
  usePublicClient,
  useReadContract,
  useSignTypedData,
  useWaitForTransactionReceipt,
  useWriteContract,
} from "wagmi";
import externalContracts from "~~/contracts/externalContracts";

// ── Contract refs ──────────────────────────────────────────────────
const CHAIN_ID = 84532;
const MOCKUSDC_ADDRESS = externalContracts[CHAIN_ID].MockUSDC.address as `0x${string}`;
const SAVINGS_ADDRESS = externalContracts[CHAIN_ID].BodaBodaSavings.address as `0x${string}`;
const MOCKUSDC_ABI = externalContracts[CHAIN_ID].MockUSDC.abi;
const SAVINGS_ABI = externalContracts[CHAIN_ID].BodaBodaSavings.abi;

// ── Withdrawal categories ──────────────────────────────────────────
const WITHDRAWAL_CATEGORIES = [
  { label: "Medical", value: "MEDICAL" },
  { label: "Motorcycle Repair", value: "REPAIR" },
  { label: "Education", value: "EDUCATION" },
  { label: "Household", value: "HOUSEHOLD" },
  { label: "Emergency", value: "EMERGENCY" },
  { label: "Family Obligation", value: "FAMILY_OBLIGATION" },
  { label: "Other", value: "OTHER" },
] as const;

// SplitRatio enum index → label / savings %
const SPLIT_OPTIONS = [
  { idx: 0, label: "70 / 30", savingsPct: 70, hint: "Save more" },
  { idx: 1, label: "60 / 40", savingsPct: 60, hint: "Balanced+" },
  { idx: 2, label: "50 / 50", savingsPct: 50, hint: "Balanced" },
  { idx: 3, label: "40 / 60", savingsPct: 40, hint: "Repay+" },
  { idx: 4, label: "30 / 70", savingsPct: 30, hint: "Repay fast" },
] as const;
const SPLIT_LABELS: Record<number, string> = Object.fromEntries(SPLIT_OPTIONS.map(o => [o.idx, o.label]));
const SPLIT_SAVINGS_PCT: Record<number, number> = Object.fromEntries(SPLIT_OPTIONS.map(o => [o.idx, o.savingsPct]));

// RepaymentSchedule enum index → label
const SCHEDULE_LABELS: Record<number, string> = { 0: "Weekly", 1: "Bi-weekly", 2: "Monthly" };

const GENDERS = [
  { label: "Male", value: "0x4d" },
  { label: "Female", value: "0x46" },
  { label: "Other", value: "0x4f" },
] as const;

// Pads a SHORT label (e.g. "MEDICAL") into a right-padded bytes32.
// Only safe for strings <= 31 bytes — used for withdrawal categories.
function toBytes32(str: string): `0x${string}` {
  const hex = Buffer.from(str, "utf8").toString("hex").slice(0, 64);
  return `0x${hex.padEnd(64, "0")}` as `0x${string}`;
}

const fmt = (val: unknown) => (val != null ? parseFloat(formatUnits(val as bigint, 6)).toFixed(2) : "0.00");
const shortAddr = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");

const progressColor = (bps: number) => {
  if (bps < 3000) return "bg-gradient-to-r from-red-500 to-orange-500";
  if (bps < 7000) return "bg-gradient-to-r from-yellow-500 to-amber-500";
  return "bg-gradient-to-r from-emerald-500 to-teal-500";
};

type Tab = "deposit" | "withdraw" | "loan" | "stats";

export default function BodaSavingsApp() {
  const { address, isConnected } = useAccount();
  const publicClient = usePublicClient();

  const [activeTab, setActiveTab] = useState<Tab>("deposit");
  const [depositAmount, setDepositAmount] = useState("");
  const [withdrawAmount, setWithdrawAmount] = useState("");
  const [withdrawCategory, setWithdrawCategory] = useState("MEDICAL");
  const [potAmount, setPotAmount] = useState("");
  const [toast, setToast] = useState<{ msg: string; ok: boolean } | null>(null);
  const [permitBusy, setPermitBusy] = useState(false);

  // Registration form state
  const [regName, setRegName] = useState("");
  const [regAge, setRegAge] = useState("");
  const [regGender, setRegGender] = useState("0x4d");
  const [regLender, setRegLender] = useState<string>("");
  const [regSplit, setRegSplit] = useState(2);
  const [regLoanTarget, setRegLoanTarget] = useState("");

  // ── Reads ────────────────────────────────────────────────────────
  const { data: usdcBalance, refetch: refetchUsdc } = useReadContract({
    address: MOCKUSDC_ADDRESS,
    abi: MOCKUSDC_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
  });

  const {
    data: riderProfile,
    refetch: refetchProfile,
    isLoading: profileLoading,
  } = useReadContract({
    address: SAVINGS_ADDRESS,
    abi: SAVINGS_ABI,
    functionName: "getRiderProfile",
    args: address ? [address] : undefined,
  });

  const { data: riderData, refetch: refetchRider } = useReadContract({
    address: SAVINGS_ADDRESS,
    abi: SAVINGS_ABI,
    functionName: "getRiderAnalytics",
    args: address ? [address] : undefined,
  });

  const { data: loanData, refetch: refetchLoan } = useReadContract({
    address: SAVINGS_ADDRESS,
    abi: SAVINGS_ABI,
    functionName: "getLoanStatus",
    args: address ? [address] : undefined,
  });

  const { data: withdrawalReq, refetch: refetchWithdrawal } = useReadContract({
    address: SAVINGS_ADDRESS,
    abi: SAVINGS_ABI,
    functionName: "getWithdrawalRequest",
    args: address ? [address] : undefined,
  });

  const { data: contractBalance } = useReadContract({
    address: SAVINGS_ADDRESS,
    abi: SAVINGS_ABI,
    functionName: "getContractBalance",
  });
  const { data: totalLoanCredits } = useReadContract({
    address: SAVINGS_ADDRESS,
    abi: SAVINGS_ABI,
    functionName: "totalLoanCredits",
  });
  const { data: totalSavingsHeld } = useReadContract({
    address: SAVINGS_ADDRESS,
    abi: SAVINGS_ABI,
    functionName: "totalSavingsHeld",
  });

  // Lender list for registration dropdown
  const { data: lenderAddrs } = useReadContract({
    address: SAVINGS_ADDRESS,
    abi: SAVINGS_ABI,
    functionName: "getLenders",
    args: [BigInt(0), BigInt(0)],
  });

  // ── Writes ───────────────────────────────────────────────────────
  const { writeContract: writeFaucet, data: faucetHash } = useWriteContract();
  const { writeContract: writeRegister, data: registerHash } = useWriteContract();
  const { writeContract: writeDeposit, data: depositHash } = useWriteContract();
  const { writeContract: writeLock, data: lockHash } = useWriteContract();
  const { writeContract: writeRelease, data: releaseHash } = useWriteContract();
  const { writeContract: writeRequest, data: requestHash } = useWriteContract();
  const { writeContract: writeClaim, data: claimHash } = useWriteContract();
  const { writeContract: writeCancel, data: cancelHash } = useWriteContract();

  const { signTypedDataAsync } = useSignTypedData();

  // ── Receipts ─────────────────────────────────────────────────────
  const { isLoading: faucetLoading, isSuccess: faucetOk } = useWaitForTransactionReceipt({ hash: faucetHash });
  const { isLoading: registerLoading, isSuccess: registerOk } = useWaitForTransactionReceipt({ hash: registerHash });
  const { isLoading: depositLoading, isSuccess: depositOk } = useWaitForTransactionReceipt({ hash: depositHash });
  const { isLoading: lockLoading, isSuccess: lockOk } = useWaitForTransactionReceipt({ hash: lockHash });
  const { isLoading: releaseLoading, isSuccess: releaseOk } = useWaitForTransactionReceipt({ hash: releaseHash });
  const { isLoading: requestLoading, isSuccess: requestOk } = useWaitForTransactionReceipt({ hash: requestHash });
  const { isLoading: claimLoading, isSuccess: claimOk } = useWaitForTransactionReceipt({ hash: claimHash });
  const { isLoading: cancelLoading, isSuccess: cancelOk } = useWaitForTransactionReceipt({ hash: cancelHash });

  // ── Toast ────────────────────────────────────────────────────────
  const showToast = (msg: string, ok = true) => {
    setToast({ msg, ok });
    setTimeout(() => setToast(null), 5000);
  };

  const refetchAll = () => {
    refetchUsdc();
    refetchProfile();
    refetchRider();
    refetchLoan();
    refetchWithdrawal();
  };

  // ── Effects ──────────────────────────────────────────────────────
  /* eslint-disable react-hooks/exhaustive-deps */
  useEffect(() => {
    if (faucetOk) {
      refetchUsdc();
      showToast("100 USDC received!");
    }
  }, [faucetOk]);
  useEffect(() => {
    if (registerOk) {
      refetchAll();
      showToast("Registered ✓ Welcome to BodaSave!");
    }
  }, [registerOk]);
  useEffect(() => {
    if (depositOk) {
      refetchAll();
      setDepositAmount("");
      showToast("Deposit successful ✓");
    }
  }, [depositOk]);
  useEffect(() => {
    if (lockOk) {
      refetchAll();
      setPotAmount("");
      showToast("Locked in pot ✓");
    }
  }, [lockOk]);
  useEffect(() => {
    if (releaseOk) {
      refetchAll();
      showToast("Released to lender ✓");
    }
  }, [releaseOk]);
  useEffect(() => {
    if (requestOk) {
      refetchWithdrawal();
      setWithdrawAmount("");
      showToast("Withdrawal requested ✓");
    }
  }, [requestOk]);
  useEffect(() => {
    if (claimOk) {
      refetchAll();
      showToast("Funds claimed ✓");
    }
  }, [claimOk]);
  useEffect(() => {
    if (cancelOk) {
      refetchAll();
      showToast("Withdrawal cancelled ✓");
    }
  }, [cancelOk]);
  /* eslint-enable react-hooks/exhaustive-deps */

  // ── Derived: profile ─────────────────────────────────────────────
  const p = riderProfile as readonly unknown[] | undefined;
  const riderName = (p?.[0] as string) ?? "";
  const isRegistered = Boolean(p?.[3]);
  const lenderName = (p?.[5] as string) ?? "—";
  const lenderSched = Number(p?.[6] ?? 0);
  const splitRatioIdx = Number(p?.[7] ?? 2);
  const savingsPct = SPLIT_SAVINGS_PCT[splitRatioIdx] ?? 50;
  const loanPct = 100 - savingsPct;

  // ── Derived: analytics ───────────────────────────────────────────
  const r = riderData as readonly unknown[] | undefined;
  const savingsBalance = (r?.[0] as bigint) ?? 0n;
  const loanBalance = (r?.[1] as bigint) ?? 0n;
  const totalDeposited = (r?.[2] as bigint) ?? 0n;
  const totalWithdrawn = (r?.[3] as bigint) ?? 0n;
  const potActive = Boolean(r?.[7]);
  const potBalance = (r?.[8] as bigint) ?? 0n;
  const potDeadline = Number((r?.[10] as bigint) ?? 0n);

  // ── Derived: loan ────────────────────────────────────────────────
  const l = loanData as readonly unknown[] | undefined;
  const loanTarget = (l?.[0] as bigint) ?? 0n;
  const loanRepaid = (l?.[2] as bigint) ?? 0n;
  const loanRemaining = (l?.[3] as bigint) ?? 0n;
  const isCleared = Boolean(l?.[4]);
  const progressBps = Number((l?.[5] as bigint) ?? 0n);
  const progressPct = (progressBps / 100).toFixed(1);

  // ── Derived: withdrawal ──────────────────────────────────────────
  const w = withdrawalReq as readonly unknown[] | undefined;
  const wStatus = Number(w?.[5] ?? 0);
  const wClaimableAt = Number((w?.[4] as bigint) ?? 0n);
  const wAmount = (w?.[0] as bigint) ?? 0n;
  const nowSec = Math.floor(Date.now() / 1000);
  const canClaim = wStatus === 2 && nowSec >= wClaimableAt;

  // ── Deposit split preview ────────────────────────────────────────
  const depositNum = parseFloat(depositAmount) || 0;
  const depositSavings = ((depositNum * savingsPct) / 100).toFixed(2);
  const depositLoanPart = ((depositNum * loanPct) / 100).toFixed(2);

  // ── Lenders for the registration dropdown ────────────────────────
  const lenderAddressList = (lenderAddrs as readonly string[] | undefined) ?? [];

  // ── Handlers ─────────────────────────────────────────────────────
  const handleFaucet = () =>
    writeFaucet({ address: MOCKUSDC_ADDRESS, abi: MOCKUSDC_ABI, functionName: "faucet", args: [parseUnits("100", 6)] });

  const handleRegister = () => {
    if (!regName || !regAge || !regLender || !regLoanTarget) {
      showToast("Fill all fields to register.", false);
      return;
    }
    const ageNum = Number(regAge);
    if (ageNum < 18 || ageNum > 65) {
      showToast("Age must be between 18 and 65.", false);
      return;
    }
    // verificationHash: a valid 32-byte keccak hash of the off-chain KYC artifact.
    // kycProvider: short label, fits in bytes32.
    const verificationHash = keccak256(stringToHex(`${regName}-${address}-${Date.now()}`));
    const kycProvider = toBytes32("SMILE_IDENTITY");
    const licenseExpiry = BigInt(Math.floor(Date.now() / 1000) + 365 * 24 * 60 * 60); // +1yr
    writeRegister(
      {
        address: SAVINGS_ADDRESS,
        abi: SAVINGS_ABI,
        functionName: "registerRider",
        args: [
          regName,
          ageNum,
          regGender as `0x${string}`,
          regLender as `0x${string}`,
          regSplit,
          parseUnits(regLoanTarget || "0", 6),
          verificationHash,
          2, // KYC_FULL
          licenseExpiry,
          kycProvider,
        ],
      },
      {
        onError: err => {
          console.error("registerRider failed:", err);
          showToast((err as Error).message?.slice(0, 80) || "Registration failed.", false);
        },
      },
    );
  };

  // One-click deposit via EIP-2612 permit — NO separate approve tx.
  const handleDepositWithPermit = async () => {
    if (!address || !publicClient || !depositAmount) return;
    try {
      setPermitBusy(true);
      const value = parseUnits(depositAmount, 6);
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 60 * 30); // 30 min

      const nonce = (await publicClient.readContract({
        address: MOCKUSDC_ADDRESS,
        abi: MOCKUSDC_ABI,
        functionName: "nonces",
        args: [address],
      })) as bigint;

      const name = (await publicClient.readContract({
        address: MOCKUSDC_ADDRESS,
        abi: MOCKUSDC_ABI,
        functionName: "name",
      })) as string;

      const signature = await signTypedDataAsync({
        domain: { name, version: "1", chainId: CHAIN_ID, verifyingContract: MOCKUSDC_ADDRESS },
        types: {
          Permit: [
            { name: "owner", type: "address" },
            { name: "spender", type: "address" },
            { name: "value", type: "uint256" },
            { name: "nonce", type: "uint256" },
            { name: "deadline", type: "uint256" },
          ],
        },
        primaryType: "Permit",
        message: { owner: address, spender: SAVINGS_ADDRESS, value, nonce, deadline },
      });

      const sig = signature.slice(2);
      const r = `0x${sig.slice(0, 64)}` as `0x${string}`;
      const s = `0x${sig.slice(64, 128)}` as `0x${string}`;
      const v = parseInt(sig.slice(128, 130), 16);

      writeDeposit({
        address: SAVINGS_ADDRESS,
        abi: SAVINGS_ABI,
        functionName: "depositWithPermit",
        args: [value, deadline, v, r, s],
      });
    } catch (e) {
      console.error("Permit signing failed:", e);
      showToast("Signature rejected.", false);
    } finally {
      setPermitBusy(false);
    }
  };

  const handleLock = () =>
    writeLock({
      address: SAVINGS_ADDRESS,
      abi: SAVINGS_ABI,
      functionName: "lockToPot",
      args: [parseUnits(potAmount || "0", 6), BigInt(0)],
    });
  const handleRelease = () =>
    writeRelease({ address: SAVINGS_ADDRESS, abi: SAVINGS_ABI, functionName: "releaseFromPot", args: [] });
  const handleRequest = () =>
    writeRequest({
      address: SAVINGS_ADDRESS,
      abi: SAVINGS_ABI,
      functionName: "requestWithdrawal",
      args: [parseUnits(withdrawAmount || "0", 6), toBytes32(withdrawCategory)],
    });
  const handleClaim = () =>
    writeClaim({ address: SAVINGS_ADDRESS, abi: SAVINGS_ABI, functionName: "claimWithdrawal", args: [] });
  const handleCancel = () =>
    writeCancel({ address: SAVINGS_ADDRESS, abi: SAVINGS_ABI, functionName: "cancelWithdrawal", args: [] });

  // ── Not connected ─────────────────────────────────────────────────
  if (!isConnected) {
    return (
      <div className="min-h-screen bg-[#050d1a] flex items-center justify-center p-4">
        <div className="max-w-sm w-full text-center space-y-6">
          <div className="w-16 h-16 rounded-2xl bg-emerald-500/10 border border-emerald-500/20 flex items-center justify-center mx-auto">
            <svg className="w-8 h-8 text-emerald-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={1.5}
                d="M17 9V7a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2m2 4h10a2 2 0 002-2v-6a2 2 0 00-2-2H9a2 2 0 00-2 2v6a2 2 0 002 2zm7-5a2 2 0 11-4 0 2 2 0 014 0z"
              />
            </svg>
          </div>
          <div>
            <h1 className="text-3xl font-bold text-white">BodaSave</h1>
            <p className="text-slate-400 mt-2 text-sm">Smart savings for bodaboda riders. Save while you repay.</p>
          </div>
          <div className="bg-slate-800/60 border border-slate-700 rounded-xl px-6 py-4 text-slate-300 text-sm">
            Connect your wallet to get started →
          </div>
        </div>
      </div>
    );
  }

  // ── Connected but loading profile ─────────────────────────────────
  if (profileLoading) {
    return (
      <div className="min-h-screen bg-[#050d1a] flex items-center justify-center">
        <p className="text-slate-400 text-sm animate-pulse">Loading your account…</p>
      </div>
    );
  }

  // ── Connected but NOT registered → Registration screen ────────────
  if (!isRegistered) {
    const selectedLenderSplit = SPLIT_OPTIONS.find(o => o.idx === regSplit)!;
    return (
      <div className="min-h-screen bg-[#050d1a] text-white py-8 px-4">
        {toast && (
          <div
            className={`fixed top-5 right-5 z-50 rounded-xl px-5 py-3 shadow-2xl border text-sm font-medium max-w-xs
            ${toast.ok ? "bg-emerald-900/95 border-emerald-500/40 text-emerald-100" : "bg-red-900/95 border-red-500/40 text-red-100"}`}
          >
            {toast.msg}
          </div>
        )}
        <div className="max-w-lg mx-auto space-y-6">
          <div className="text-center">
            <h1 className="text-2xl font-bold">Create Your BodaSave Account</h1>
            <p className="text-slate-400 text-sm mt-1">
              Connected as <span className="text-emerald-400 font-mono">{shortAddr(address)}</span>. Register to start
              saving.
            </p>
          </div>

          <div className="bg-slate-800/50 border border-slate-700/60 rounded-2xl p-6 space-y-5">
            {/* Name */}
            <div>
              <label className="text-xs text-slate-400 block mb-1.5">Full Name</label>
              <input
                value={regName}
                onChange={e => setRegName(e.target.value)}
                placeholder="e.g. John Kamau"
                className="w-full bg-slate-700/50 border border-slate-600 rounded-xl px-4 py-3 text-white placeholder-slate-500 focus:outline-none focus:border-emerald-500 text-sm"
              />
            </div>

            {/* Age + Gender */}
            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className="text-xs text-slate-400 block mb-1.5">Age (18–65)</label>
                <input
                  type="number"
                  value={regAge}
                  onChange={e => setRegAge(e.target.value)}
                  placeholder="32"
                  className="w-full bg-slate-700/50 border border-slate-600 rounded-xl px-4 py-3 text-white placeholder-slate-500 focus:outline-none focus:border-emerald-500 text-sm"
                />
              </div>
              <div>
                <label className="text-xs text-slate-400 block mb-1.5">Gender</label>
                <select
                  value={regGender}
                  onChange={e => setRegGender(e.target.value)}
                  className="w-full bg-slate-700/50 border border-slate-600 rounded-xl px-4 py-3 text-white focus:outline-none focus:border-emerald-500 text-sm"
                >
                  {GENDERS.map(g => (
                    <option key={g.value} value={g.value}>
                      {g.label}
                    </option>
                  ))}
                </select>
              </div>
            </div>

            {/* Lender */}
            <div>
              <label className="text-xs text-slate-400 block mb-1.5">Choose Your Lender</label>
              <select
                value={regLender}
                onChange={e => setRegLender(e.target.value)}
                className="w-full bg-slate-700/50 border border-slate-600 rounded-xl px-4 py-3 text-white focus:outline-none focus:border-emerald-500 text-sm"
              >
                <option value="">— Select a lender —</option>
                {lenderAddressList.map(addr => (
                  <LenderOption key={addr} lenderAddr={addr} />
                ))}
              </select>
              {regLender && <LenderSchedulePreview lenderAddr={regLender} />}
            </div>

            {/* Split ratio */}
            <div>
              <label className="text-xs text-slate-400 block mb-1.5">Savings / Loan Split</label>
              <div className="grid grid-cols-5 gap-2">
                {SPLIT_OPTIONS.map(o => (
                  <button
                    key={o.idx}
                    onClick={() => setRegSplit(o.idx)}
                    className={`rounded-lg py-2 px-1 text-center transition-all border
                      ${
                        regSplit === o.idx
                          ? "bg-emerald-500/15 border-emerald-500 text-emerald-300"
                          : "bg-slate-700/30 border-slate-600/50 text-slate-400 hover:border-slate-500"
                      }`}
                  >
                    <p className="text-xs font-bold">{o.label}</p>
                    <p className="text-[10px] opacity-70 mt-0.5">{o.hint}</p>
                  </button>
                ))}
              </div>
              <p className="text-xs text-slate-500 mt-2">
                {selectedLenderSplit.savingsPct}% to savings · {100 - selectedLenderSplit.savingsPct}% to loan repayment
              </p>
            </div>

            {/* Loan target */}
            <div>
              <label className="text-xs text-slate-400 block mb-1.5">Loan Target (USDC)</label>
              <input
                type="number"
                value={regLoanTarget}
                onChange={e => setRegLoanTarget(e.target.value)}
                placeholder="5000"
                className="w-full bg-slate-700/50 border border-slate-600 rounded-xl px-4 py-3 text-white placeholder-slate-500 focus:outline-none focus:border-emerald-500 text-sm"
              />
            </div>

            <button
              onClick={handleRegister}
              disabled={registerLoading}
              className="w-full bg-emerald-600 hover:bg-emerald-500 text-white py-3.5 rounded-xl font-bold text-sm transition-all disabled:opacity-50"
            >
              {registerLoading ? "Registering…" : "Register & Start Saving"}
            </button>
            <p className="text-xs text-slate-600 text-center">
              KYC is verified off-chain (Smile Identity / NTSA). Your details are recorded on Base Sepolia.
            </p>
          </div>
        </div>
      </div>
    );
  }

  // ── REGISTERED — main app ─────────────────────────────────────────
  const tabs: { id: Tab; label: string }[] = [
    { id: "deposit", label: "Deposit" },
    { id: "withdraw", label: "Withdraw" },
    { id: "loan", label: "Loan & Pot" },
    { id: "stats", label: "Stats" },
  ];

  return (
    <div className="min-h-screen bg-[#050d1a] text-white py-8 px-4">
      {toast && (
        <div
          className={`fixed top-5 right-5 z-50 rounded-xl px-5 py-3 shadow-2xl border text-sm font-medium max-w-xs
          ${toast.ok ? "bg-emerald-900/95 border-emerald-500/40 text-emerald-100" : "bg-red-900/95 border-red-500/40 text-red-100"}`}
        >
          {toast.msg}
        </div>
      )}

      <div className="max-w-3xl mx-auto space-y-6">
        {/* Header — NAME prominent, address muted underneath */}
        <div className="flex items-start justify-between">
          <div>
            <h1 className="text-2xl font-bold text-white flex items-center gap-2">👋 {riderName}</h1>
            <p className="text-slate-600 text-xs mt-0.5 font-mono">{shortAddr(address)} · Base Sepolia</p>
          </div>
          <div className="text-right space-y-1">
            <div className="bg-emerald-950/60 border border-emerald-600/30 text-emerald-400 text-xs px-3 py-1.5 rounded-lg">
              ✓ KYC Verified
            </div>
            <p className="text-xs text-slate-500">
              {lenderName} · {SCHEDULE_LABELS[lenderSched]} · {SPLIT_LABELS[splitRatioIdx]}
            </p>
          </div>
        </div>

        {/* Balance row */}
        <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
          {[
            { label: "Wallet", val: fmt(usdcBalance), color: "text-white" },
            { label: "Savings", val: fmt(savingsBalance), color: "text-emerald-400" },
            { label: "Loan Credit", val: fmt(loanBalance), color: "text-sky-400" },
            { label: "Loan Repaid", val: fmt(loanRepaid), color: "text-teal-400" },
          ].map(c => (
            <div key={c.label} className="bg-slate-800/50 border border-slate-700/60 rounded-xl p-4">
              <p className="text-xs text-slate-500 mb-1">{c.label}</p>
              <p className={`text-xl font-bold ${c.color}`}>{c.val}</p>
              <p className="text-xs text-slate-600 mt-0.5">USDC</p>
            </div>
          ))}
        </div>

        {/* Loan progress */}
        {loanTarget > 0n && (
          <div className="bg-slate-800/50 border border-slate-700/60 rounded-xl p-5">
            <div className="flex justify-between items-center mb-2">
              <span className="text-sm text-slate-300 font-medium">Loan Repayment Progress</span>
              <span className="text-sm font-bold">{progressPct}%</span>
            </div>
            <div className="h-2.5 bg-slate-700 rounded-full overflow-hidden">
              <div
                className={`h-full ${progressColor(progressBps)} rounded-full transition-all duration-700`}
                style={{ width: `${Math.min(progressBps / 100, 100)}%` }}
              />
            </div>
            <div className="flex justify-between mt-2 text-xs text-slate-500">
              <span>{fmt(loanRepaid)} repaid</span>
              <span>
                {fmt(loanRemaining)} remaining of {fmt(loanTarget)}
              </span>
            </div>
            {isCleared && (
              <p className="text-center text-emerald-400 font-semibold mt-3 text-sm">🎉 Loan fully cleared!</p>
            )}
          </div>
        )}

        {/* Tabs */}
        <div className="bg-slate-800/50 border border-slate-700/60 rounded-2xl overflow-hidden">
          <div className="flex border-b border-slate-700/60">
            {tabs.map(t => (
              <button
                key={t.id}
                onClick={() => setActiveTab(t.id)}
                className={`flex-1 py-3.5 text-sm font-semibold transition-all
                  ${activeTab === t.id ? "text-emerald-400 border-b-2 border-emerald-500 bg-emerald-500/5" : "text-slate-500 hover:text-slate-300"}`}
              >
                {t.label}
              </button>
            ))}
          </div>

          <div className="p-6">
            {/* ── DEPOSIT ── */}
            {activeTab === "deposit" && (
              <div className="max-w-md mx-auto space-y-4">
                <div>
                  <h3 className="text-lg font-bold">Make a Deposit</h3>
                  <p className="text-slate-400 text-sm mt-0.5">
                    Splits {savingsPct}/{loanPct} — savings / loan credit (your {SPLIT_LABELS[splitRatioIdx]} ratio).
                    One signature, no approval transaction.
                  </p>
                </div>

                <div className="flex gap-2">
                  <input
                    type="number"
                    value={depositAmount}
                    onChange={e => setDepositAmount(e.target.value)}
                    placeholder="0.00 USDC"
                    className="flex-1 bg-slate-700/50 border border-slate-600 rounded-xl px-4 py-3 text-white placeholder-slate-500 focus:outline-none focus:border-emerald-500 text-sm"
                  />
                  <button
                    onClick={handleFaucet}
                    disabled={faucetLoading}
                    className="bg-slate-700 hover:bg-slate-600 border border-slate-600 text-slate-300 px-4 py-3 rounded-xl text-xs font-medium transition-all disabled:opacity-50 whitespace-nowrap"
                  >
                    {faucetLoading ? "..." : "+ 100 USDC"}
                  </button>
                </div>

                {depositAmount && (
                  <div className="grid grid-cols-2 gap-2 text-sm">
                    <div className="bg-emerald-950/40 border border-emerald-800/30 rounded-lg p-3">
                      <p className="text-xs text-emerald-600 mb-0.5">→ Savings ({savingsPct}%)</p>
                      <p className="font-bold text-emerald-400">{depositSavings} USDC</p>
                    </div>
                    <div className="bg-sky-950/40 border border-sky-800/30 rounded-lg p-3">
                      <p className="text-xs text-sky-600 mb-0.5">→ Loan Credit ({loanPct}%)</p>
                      <p className="font-bold text-sky-400">{depositLoanPart} USDC</p>
                    </div>
                  </div>
                )}

                <button
                  onClick={handleDepositWithPermit}
                  disabled={!depositAmount || depositLoading || permitBusy}
                  className="w-full bg-emerald-600 hover:bg-emerald-500 text-white py-3.5 rounded-xl font-bold text-sm transition-all disabled:opacity-50"
                >
                  {permitBusy ? "Sign in wallet…" : depositLoading ? "Depositing…" : "Sign & Deposit"}
                </button>
                <p className="text-xs text-slate-600 text-center">
                  Uses EIP-2612 permit — gasless approval bundled into one signature.
                </p>
              </div>
            )}

            {/* ── WITHDRAW ── */}
            {activeTab === "withdraw" && (
              <div className="max-w-md mx-auto space-y-4">
                <div>
                  <h3 className="text-lg font-bold">Withdraw Savings</h3>
                  <p className="text-slate-400 text-sm mt-0.5">Requires owner approval + 2.5 min cooling-off period.</p>
                </div>

                {wStatus > 0 && (
                  <div
                    className={`rounded-xl p-4 border text-sm space-y-2
                    ${wStatus === 1 ? "bg-amber-950/40 border-amber-600/30 text-amber-300" : "bg-emerald-950/40 border-emerald-600/30 text-emerald-300"}`}
                  >
                    <p className="font-semibold">{wStatus === 1 ? "⏳ Pending approval" : "✅ Approved"}</p>
                    <p className="text-xs opacity-80">Amount: {fmt(wAmount)} USDC</p>
                    {wStatus === 2 && !canClaim && (
                      <p className="text-xs opacity-60">
                        Claimable at {new Date(wClaimableAt * 1000).toLocaleTimeString()}
                      </p>
                    )}
                    <div className="flex gap-2 pt-1">
                      {canClaim && (
                        <button
                          onClick={handleClaim}
                          disabled={claimLoading}
                          className="flex-1 bg-emerald-600 hover:bg-emerald-500 text-white py-2.5 rounded-lg font-bold text-sm transition-all disabled:opacity-50"
                        >
                          {claimLoading ? "Claiming..." : "Claim Funds"}
                        </button>
                      )}
                      <button
                        onClick={handleCancel}
                        disabled={cancelLoading}
                        className="flex-1 bg-slate-700 hover:bg-slate-600 text-slate-300 py-2.5 rounded-lg font-bold text-sm transition-all disabled:opacity-50"
                      >
                        {cancelLoading ? "Cancelling..." : "Cancel Request"}
                      </button>
                    </div>
                  </div>
                )}

                {wStatus === 0 && (
                  <>
                    <div>
                      <label className="text-xs text-slate-400 block mb-1.5">
                        Amount — available: {fmt(savingsBalance)} USDC
                      </label>
                      <input
                        type="number"
                        value={withdrawAmount}
                        onChange={e => setWithdrawAmount(e.target.value)}
                        placeholder="0.00 USDC"
                        className="w-full bg-slate-700/50 border border-slate-600 rounded-xl px-4 py-3 text-white placeholder-slate-500 focus:outline-none focus:border-orange-500 text-sm"
                      />
                    </div>
                    <div>
                      <label className="text-xs text-slate-400 block mb-1.5">Reason</label>
                      <select
                        value={withdrawCategory}
                        onChange={e => setWithdrawCategory(e.target.value)}
                        className="w-full bg-slate-700/50 border border-slate-600 rounded-xl px-4 py-3 text-white focus:outline-none focus:border-orange-500 text-sm"
                      >
                        {WITHDRAWAL_CATEGORIES.map(c => (
                          <option key={c.value} value={c.value}>
                            {c.label}
                          </option>
                        ))}
                      </select>
                    </div>
                    <button
                      onClick={handleRequest}
                      disabled={!withdrawAmount || requestLoading}
                      className="w-full bg-orange-600 hover:bg-orange-500 text-white py-3.5 rounded-xl font-bold text-sm transition-all disabled:opacity-50"
                    >
                      {requestLoading ? "Submitting..." : "Request Withdrawal"}
                    </button>
                  </>
                )}
              </div>
            )}

            {/* ── LOAN & POT ── */}
            {activeTab === "loan" && (
              <div className="max-w-md mx-auto space-y-4">
                <div>
                  <h3 className="text-lg font-bold">Loan & Pot</h3>
                  <p className="text-slate-400 text-sm mt-0.5">
                    Lock loan balance into pot → auto-releases to <span className="text-sky-400">{lenderName}</span>{" "}
                    after your {SCHEDULE_LABELS[lenderSched].toLowerCase()} cycle.
                  </p>
                </div>

                <div className="grid grid-cols-2 gap-3">
                  <div className="bg-slate-700/30 border border-slate-700/60 rounded-xl p-4">
                    <p className="text-xs text-slate-500 mb-1">Loan Credit</p>
                    <p className="text-xl font-bold text-sky-400">{fmt(loanBalance)}</p>
                    <p className="text-xs text-slate-600 mt-0.5">Ready to lock</p>
                  </div>
                  <div className="bg-slate-700/30 border border-slate-700/60 rounded-xl p-4">
                    <p className="text-xs text-slate-500 mb-1">Pot</p>
                    <p className={`text-xl font-bold ${potActive ? "text-amber-400" : "text-slate-600"}`}>
                      {potActive ? fmt(potBalance) : "Empty"}
                    </p>
                    {potActive && potDeadline > 0 && (
                      <p className="text-xs text-slate-500 mt-0.5">
                        Auto-settles {new Date(potDeadline * 1000).toLocaleDateString()}
                      </p>
                    )}
                  </div>
                </div>

                {!potActive ? (
                  <>
                    <div>
                      <label className="text-xs text-slate-400 block mb-1.5">
                        Amount to lock — available: {fmt(loanBalance)} USDC
                      </label>
                      <input
                        type="number"
                        value={potAmount}
                        onChange={e => setPotAmount(e.target.value)}
                        placeholder="0.00 USDC"
                        className="w-full bg-slate-700/50 border border-slate-600 rounded-xl px-4 py-3 text-white placeholder-slate-500 focus:outline-none focus:border-sky-500 text-sm"
                      />
                    </div>
                    <button
                      onClick={handleLock}
                      disabled={!potAmount || lockLoading || isCleared}
                      className="w-full bg-sky-600 hover:bg-sky-500 text-white py-3.5 rounded-xl font-bold text-sm transition-all disabled:opacity-50"
                    >
                      {lockLoading ? "Locking..." : "Lock into Pot"}
                    </button>
                    <p className="text-xs text-slate-600 text-center">
                      Pot auto-releases to {lenderName} after the {SCHEDULE_LABELS[lenderSched].toLowerCase()} cycle.
                      Release early anytime.
                    </p>
                  </>
                ) : (
                  <button
                    onClick={handleRelease}
                    disabled={releaseLoading}
                    className="w-full bg-teal-600 hover:bg-teal-500 text-white py-3.5 rounded-xl font-bold text-sm transition-all disabled:opacity-50"
                  >
                    {releaseLoading ? "Releasing..." : `Release to ${lenderName} Now`}
                  </button>
                )}
              </div>
            )}

            {/* ── STATS ── */}
            {activeTab === "stats" && (
              <div className="max-w-md mx-auto space-y-4">
                <h3 className="text-lg font-bold">Statistics</h3>
                <div className="grid grid-cols-2 gap-3">
                  {[
                    { label: "Contract Balance", val: fmt(contractBalance), usd: true },
                    { label: "Total Savings Held", val: fmt(totalSavingsHeld), usd: true },
                    { label: "Total Loan Credits", val: fmt(totalLoanCredits), usd: true },
                    { label: "Your Total Deposited", val: fmt(totalDeposited), usd: true },
                    { label: "Your Total Withdrawn", val: fmt(totalWithdrawn), usd: true },
                    { label: "Your Split Ratio", val: SPLIT_LABELS[splitRatioIdx], usd: false },
                  ].map(s => (
                    <div key={s.label} className="bg-slate-700/30 border border-slate-700/60 rounded-xl p-4">
                      <p className="text-xs text-slate-500 mb-1">{s.label}</p>
                      <p className="text-xl font-bold text-slate-200">{s.val}</p>
                      {s.usd && <p className="text-xs text-slate-600">USDC</p>}
                    </div>
                  ))}
                </div>

                <div className="bg-slate-700/20 border border-slate-700/40 rounded-xl p-4">
                  <h4 className="text-sm font-semibold text-slate-300 mb-2">Your Profile</h4>
                  <div className="space-y-1 text-sm text-slate-400">
                    <div className="flex justify-between">
                      <span>Name</span>
                      <span className="text-white">{riderName}</span>
                    </div>
                    <div className="flex justify-between">
                      <span>Lender</span>
                      <span className="text-sky-400">{lenderName}</span>
                    </div>
                    <div className="flex justify-between">
                      <span>Schedule</span>
                      <span>{SCHEDULE_LABELS[lenderSched]}</span>
                    </div>
                    <div className="flex justify-between">
                      <span>Split</span>
                      <span>{SPLIT_LABELS[splitRatioIdx]} (savings/loan)</span>
                    </div>
                    <div className="flex justify-between">
                      <span>Loan Target</span>
                      <span>{fmt(loanTarget)} USDC</span>
                    </div>
                  </div>
                </div>
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

// ── Lender <option> that fetches its own name ──────────────────────
function LenderOption({ lenderAddr }: { lenderAddr: string }) {
  const { data } = useReadContract({
    address: SAVINGS_ADDRESS,
    abi: SAVINGS_ABI,
    functionName: "getLender",
    args: [lenderAddr as `0x${string}`],
  });
  const d = data as readonly unknown[] | undefined;
  const name = (d?.[0] as string) ?? shortAddr(lenderAddr);
  return <option value={lenderAddr}>{name}</option>;
}

// ── Live schedule/cycle preview under the lender dropdown ──────────
function LenderSchedulePreview({ lenderAddr }: { lenderAddr: string }) {
  const { data } = useReadContract({
    address: SAVINGS_ADDRESS,
    abi: SAVINGS_ABI,
    functionName: "getLender",
    args: [lenderAddr as `0x${string}`],
  });
  const d = data as readonly unknown[] | undefined;
  if (!d) return null;
  const cycleSecs = Number(d[1] ?? 0);
  const schedule = Number(d[2] ?? 0);
  const days = Math.round(cycleSecs / 86400);
  return (
    <div className="mt-2 bg-sky-950/30 border border-sky-800/30 rounded-lg px-3 py-2 text-xs text-sky-300">
      Repayment schedule: <span className="font-semibold">{SCHEDULE_LABELS[schedule]}</span>
      {" · "}collection cycle:{" "}
      <span className="font-semibold">
        {days} day{days !== 1 ? "s" : ""}
      </span>
    </div>
  );
}
