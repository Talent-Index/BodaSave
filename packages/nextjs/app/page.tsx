"use client";

import { useEffect, useState } from "react";
import { formatUnits, parseUnits } from "viem";
import { useAccount, useReadContract, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import deployedContracts from "~~/contracts/deployedContracts";

// ── Contract refs ──────────────────────────────────────────────────
const CHAIN_ID = 84532;
const MOCKUSDC_ADDRESS = deployedContracts[CHAIN_ID].MockUSDC.address as `0x${string}`;
const SAVINGS_ADDRESS = deployedContracts[CHAIN_ID].BodaBodaSavings.address as `0x${string}`;
const MOCKUSDC_ABI = deployedContracts[CHAIN_ID].MockUSDC.abi;
const SAVINGS_ABI = deployedContracts[CHAIN_ID].BodaBodaSavings.abi;

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

function toBytes32(str: string): `0x${string}` {
  const hex = Buffer.from(str, "utf8").toString("hex");
  return `0x${hex.padEnd(64, "0")}` as `0x${string}`;
}

const fmt = (val: unknown) => (val != null ? parseFloat(formatUnits(val as bigint, 6)).toFixed(2) : "0.00");

const progressColor = (bps: number) => {
  if (bps < 3000) return "bg-gradient-to-r from-red-500 to-orange-500";
  if (bps < 7000) return "bg-gradient-to-r from-yellow-500 to-amber-500";
  return "bg-gradient-to-r from-emerald-500 to-teal-500";
};

type Tab = "deposit" | "withdraw" | "loan" | "stats";

export default function BodaSavingsApp() {
  const { address, isConnected } = useAccount();

  const [activeTab, setActiveTab] = useState<Tab>("deposit");
  const [depositAmount, setDepositAmount] = useState("");
  const [withdrawAmount, setWithdrawAmount] = useState("");
  const [withdrawCategory, setWithdrawCategory] = useState("MEDICAL");
  const [potAmount, setPotAmount] = useState("");
  const [toast, setToast] = useState<{ msg: string; ok: boolean } | null>(null);

  // ── Reads ────────────────────────────────────────────────────────
  const { data: usdcBalance, refetch: refetchUsdc } = useReadContract({
    address: MOCKUSDC_ADDRESS,
    abi: MOCKUSDC_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
  });

  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: MOCKUSDC_ADDRESS,
    abi: MOCKUSDC_ABI,
    functionName: "allowance",
    args: address ? [address, SAVINGS_ADDRESS] : undefined,
  });

  // getRiderAnalytics returns 11 values:
  // [0] savingsBalance  [1] loanBalance    [2] totalDeposited [3] totalWithdrawn
  // [4] withdrawalCount [5] lastDepositAt  [6] firstDepositAt [7] potActive
  // [8] potBalance      [9] potLockedAt    [10] potDeadline
  const { data: riderData, refetch: refetchRider } = useReadContract({
    address: SAVINGS_ADDRESS,
    abi: SAVINGS_ABI,
    functionName: "getRiderAnalytics",
    args: address ? [address] : undefined,
  });

  // getLoanStatus returns 6 values:
  // [0] loanTarget  [1] loanBalance  [2] loanRepaid
  // [3] loanRemaining  [4] isCleared  [5] progressBps
  const { data: loanData, refetch: refetchLoan } = useReadContract({
    address: SAVINGS_ADDRESS,
    abi: SAVINGS_ABI,
    functionName: "getLoanStatus",
    args: address ? [address] : undefined,
  });

  // getWithdrawalRequest returns 6 values:
  // [0] amount  [1] category  [2] requestedAt
  // [3] approvedAt  [4] claimableAt  [5] status (0=None,1=Pending,2=Approved)
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

  const { data: isVerified } = useReadContract({
    address: SAVINGS_ADDRESS,
    abi: SAVINGS_ABI,
    functionName: "isVerifiedRider",
    args: address ? [address] : undefined,
  });

  // ── Writes ───────────────────────────────────────────────────────
  const { writeContract: writeFaucet, data: faucetHash } = useWriteContract();
  const { writeContract: writeApprove, data: approveHash } = useWriteContract();
  const { writeContract: writeDeposit, data: depositHash } = useWriteContract();
  const { writeContract: writeLock, data: lockHash } = useWriteContract();
  const { writeContract: writeRelease, data: releaseHash } = useWriteContract();
  const { writeContract: writeRequest, data: requestHash } = useWriteContract();
  const { writeContract: writeClaim, data: claimHash } = useWriteContract();

  // ── Receipts ─────────────────────────────────────────────────────
  const { isLoading: faucetLoading, isSuccess: faucetOk } = useWaitForTransactionReceipt({ hash: faucetHash });
  const { isLoading: approveLoading, isSuccess: approveOk } = useWaitForTransactionReceipt({ hash: approveHash });
  const { isLoading: depositLoading, isSuccess: depositOk } = useWaitForTransactionReceipt({ hash: depositHash });
  const { isLoading: lockLoading, isSuccess: lockOk } = useWaitForTransactionReceipt({ hash: lockHash });
  const { isLoading: releaseLoading, isSuccess: releaseOk } = useWaitForTransactionReceipt({ hash: releaseHash });
  const { isLoading: requestLoading, isSuccess: requestOk } = useWaitForTransactionReceipt({ hash: requestHash });
  const { isLoading: claimLoading, isSuccess: claimOk } = useWaitForTransactionReceipt({ hash: claimHash });

  // ── Toast ────────────────────────────────────────────────────────
  const showToast = (msg: string, ok = true) => {
    setToast({ msg, ok });
    setTimeout(() => setToast(null), 5000);
  };

  const refetchAll = () => {
    refetchUsdc();
    refetchAllowance();
    refetchRider();
    refetchLoan();
    refetchWithdrawal();
  };

  // ── Effects ──────────────────────────────────────────────────────
  useEffect(() => {
    if (faucetOk) {
      refetchUsdc();
      showToast("100 USDC received!");
    }
  }, [faucetOk]);
  useEffect(() => {
    if (approveOk) {
      refetchAllowance();
      showToast("Approval granted — ready to deposit.");
    }
  }, [approveOk]);
  useEffect(() => {
    if (depositOk) {
      refetchAll();
      setDepositAmount("");
      showToast("Deposit split 50/50 ✓");
    }
  }, [depositOk]);
  useEffect(() => {
    if (lockOk) {
      refetchAll();
      setPotAmount("");
      showToast("Locked in pot — repayment scheduled ✓");
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
      showToast("Withdrawal request submitted — awaiting approval ✓");
    }
  }, [requestOk]);
  useEffect(() => {
    if (claimOk) {
      refetchAll();
      showToast("Funds claimed to your wallet ✓");
    }
  }, [claimOk]);

  // ── Derived ──────────────────────────────────────────────────────
  const r = riderData as readonly bigint[] | undefined;
  const l = loanData as readonly unknown[] | undefined;
  const w = withdrawalReq as readonly unknown[] | undefined;

  const savingsBalance = r?.[0] ?? 0n;
  const loanBalance = r?.[1] ?? 0n;
  const totalDeposited = r?.[2] ?? 0n;
  const totalWithdrawn = r?.[3] ?? 0n;
  const potActive = Boolean(r?.[7]);
  const potBalance = r?.[8] ?? 0n;
  const potDeadline = Number(r?.[10] ?? 0n);

  const loanTarget = (l?.[0] as bigint) ?? 0n;
  const loanRepaid = (l?.[2] as bigint) ?? 0n;
  const loanRemaining = (l?.[3] as bigint) ?? 0n;
  const isCleared = Boolean(l?.[4]);
  const progressBps = Number((l?.[5] as bigint) ?? 0n);
  const progressPct = (progressBps / 100).toFixed(1);

  const wStatus = Number(w?.[5] ?? 0);
  const wClaimableAt = Number((w?.[4] as bigint) ?? 0n);
  const wAmount = (w?.[0] as bigint) ?? 0n;

  const nowSec = Math.floor(Date.now() / 1000);
  const canClaim = wStatus === 2 && nowSec >= wClaimableAt;
  const needsApproval =
    depositAmount && allowance != null ? parseUnits(depositAmount || "0", 6) > (allowance as bigint) : true;

  // ── Handlers ─────────────────────────────────────────────────────
  const handleFaucet = () =>
    writeFaucet({ address: MOCKUSDC_ADDRESS, abi: MOCKUSDC_ABI, functionName: "faucet", args: [parseUnits("100", 6)] });
  const handleApprove = () =>
    writeApprove({
      address: MOCKUSDC_ADDRESS,
      abi: MOCKUSDC_ABI,
      functionName: "approve",
      args: [SAVINGS_ADDRESS, parseUnits(depositAmount || "0", 6)],
    });
  const handleDeposit = () =>
    writeDeposit({
      address: SAVINGS_ADDRESS,
      abi: SAVINGS_ABI,
      functionName: "deposit",
      args: [parseUnits(depositAmount || "0", 6)],
    });
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

  const tabs: { id: Tab; label: string }[] = [
    { id: "deposit", label: "Deposit" },
    { id: "withdraw", label: "Withdraw" },
    { id: "loan", label: "Loan & Pot" },
    { id: "stats", label: "Stats" },
  ];

  return (
    <div className="min-h-screen bg-[#050d1a] text-white py-8 px-4">
      {/* Toast */}
      {toast && (
        <div
          className={`fixed top-5 right-5 z-50 rounded-xl px-5 py-3 shadow-2xl border text-sm font-medium max-w-xs
          ${
            toast.ok
              ? "bg-emerald-900/95 border-emerald-500/40 text-emerald-100"
              : "bg-red-900/95 border-red-500/40 text-red-100"
          }`}
        >
          {toast.msg}
        </div>
      )}

      <div className="max-w-3xl mx-auto space-y-6">
        {/* Header */}
        <div className="flex items-start justify-between">
          <div>
            <h1 className="text-2xl font-bold text-white">BodaSave</h1>
            <p className="text-slate-500 text-xs mt-0.5">Base Sepolia Testnet</p>
          </div>
          {!isVerified && (
            <div className="bg-amber-950/60 border border-amber-600/30 text-amber-400 text-xs px-3 py-2 rounded-lg">
              ⚠ Not KYC verified — contact admin
            </div>
          )}
        </div>

        {/* Balance row */}
        <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
          {[
            { label: "Wallet", val: fmt(usdcBalance), color: "text-white" },
            { label: "Savings", val: fmt(savingsBalance), color: "text-emerald-400" },
            { label: "Loan Balance", val: fmt(loanBalance), color: "text-sky-400" },
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
        {(loanTarget as bigint) > 0n && (
          <div className="bg-slate-800/50 border border-slate-700/60 rounded-xl p-5">
            <div className="flex justify-between items-center mb-2">
              <span className="text-sm text-slate-300 font-medium">Loan Repayment</span>
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
              <span>{fmt(loanRemaining)} remaining</span>
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
                  ${
                    activeTab === t.id
                      ? "text-emerald-400 border-b-2 border-emerald-500 bg-emerald-500/5"
                      : "text-slate-500 hover:text-slate-300"
                  }`}
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
                  <p className="text-slate-400 text-sm mt-0.5">Splits 50/50 — savings + loan repayment credit.</p>
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
                      <p className="text-xs text-emerald-600 mb-0.5">→ Savings</p>
                      <p className="font-bold text-emerald-400">{(Number(depositAmount) / 2).toFixed(2)} USDC</p>
                    </div>
                    <div className="bg-sky-950/40 border border-sky-800/30 rounded-lg p-3">
                      <p className="text-xs text-sky-600 mb-0.5">→ Loan Credit</p>
                      <p className="font-bold text-sky-400">{(Number(depositAmount) / 2).toFixed(2)} USDC</p>
                    </div>
                  </div>
                )}

                {needsApproval ? (
                  <button
                    onClick={handleApprove}
                    disabled={!depositAmount || approveLoading}
                    className="w-full bg-amber-600 hover:bg-amber-500 text-white py-3.5 rounded-xl font-bold text-sm transition-all disabled:opacity-50"
                  >
                    {approveLoading ? "Approving..." : "Approve USDC"}
                  </button>
                ) : (
                  <button
                    onClick={handleDeposit}
                    disabled={!depositAmount || depositLoading}
                    className="w-full bg-emerald-600 hover:bg-emerald-500 text-white py-3.5 rounded-xl font-bold text-sm transition-all disabled:opacity-50"
                  >
                    {depositLoading ? "Depositing..." : "Deposit Now"}
                  </button>
                )}
              </div>
            )}

            {/* ── WITHDRAW ── */}
            {activeTab === "withdraw" && (
              <div className="max-w-md mx-auto space-y-4">
                <div>
                  <h3 className="text-lg font-bold">Withdraw Savings</h3>
                  <p className="text-slate-400 text-sm mt-0.5">Requires owner approval + 2.5 min cooling-off period.</p>
                </div>

                {/* Active request banner */}
                {wStatus > 0 && (
                  <div
                    className={`rounded-xl p-4 border text-sm space-y-1
                    ${
                      wStatus === 1
                        ? "bg-amber-950/40 border-amber-600/30 text-amber-300"
                        : "bg-emerald-950/40 border-emerald-600/30 text-emerald-300"
                    }`}
                  >
                    <p className="font-semibold">{wStatus === 1 ? "⏳ Pending approval" : "✅ Approved"}</p>
                    <p className="text-xs opacity-80">Amount: {fmt(wAmount)} USDC</p>
                    {wStatus === 2 && !canClaim && (
                      <p className="text-xs opacity-60">
                        Claimable at {new Date(wClaimableAt * 1000).toLocaleTimeString()}
                      </p>
                    )}
                    {canClaim && (
                      <button
                        onClick={handleClaim}
                        disabled={claimLoading}
                        className="mt-2 w-full bg-emerald-600 hover:bg-emerald-500 text-white py-2.5 rounded-lg font-bold text-sm transition-all disabled:opacity-50"
                      >
                        {claimLoading ? "Claiming..." : "Claim Funds"}
                      </button>
                    )}
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
                    Lock loan balance into pot to schedule repayment to your lender.
                  </p>
                </div>

                <div className="grid grid-cols-2 gap-3">
                  <div className="bg-slate-700/30 border border-slate-700/60 rounded-xl p-4">
                    <p className="text-xs text-slate-500 mb-1">Loan Balance</p>
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
                      Pot auto-releases to your lender after the collection cycle. Release early anytime.
                    </p>
                  </>
                ) : (
                  <button
                    onClick={handleRelease}
                    disabled={releaseLoading}
                    className="w-full bg-teal-600 hover:bg-teal-500 text-white py-3.5 rounded-xl font-bold text-sm transition-all disabled:opacity-50"
                  >
                    {releaseLoading ? "Releasing..." : "Release to Lender Now"}
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
                    { label: "Contract Balance", val: fmt(contractBalance), color: "text-white" },
                    { label: "Total Loan Credits", val: fmt(totalLoanCredits), color: "text-sky-400" },
                    { label: "Your Total Deposited", val: fmt(totalDeposited), color: "text-emerald-400" },
                    { label: "Your Total Withdrawn", val: fmt(totalWithdrawn), color: "text-orange-400" },
                  ].map(s => (
                    <div key={s.label} className="bg-slate-700/30 border border-slate-700/60 rounded-xl p-4">
                      <p className="text-xs text-slate-500 mb-1">{s.label}</p>
                      <p className={`text-xl font-bold ${s.color}`}>{s.val}</p>
                      <p className="text-xs text-slate-600">USDC</p>
                    </div>
                  ))}
                </div>

                <div className="bg-slate-700/20 border border-slate-700/40 rounded-xl p-5">
                  <h4 className="text-sm font-semibold text-slate-300 mb-3">How It Works</h4>
                  <ol className="space-y-2.5 text-sm text-slate-400">
                    {[
                      "Deposit daily earnings in USDC",
                      "50% goes to savings, 50% to loan repayment credit",
                      "Lock loan balance into pot to pay your lender",
                      "Pot auto-releases after your lender's collection cycle",
                      "Request savings withdrawals with a reason — approved by admin",
                    ].map((s, i) => (
                      <li key={i} className="flex gap-3 items-start">
                        <span className="bg-emerald-600/20 text-emerald-500 rounded-full w-5 h-5 flex items-center justify-center text-xs flex-shrink-0 mt-0.5 font-bold">
                          {i + 1}
                        </span>
                        <span>{s}</span>
                      </li>
                    ))}
                  </ol>
                </div>
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
