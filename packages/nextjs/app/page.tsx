"use client";

import { useEffect, useState } from "react";
import { formatUnits, parseUnits } from "viem";
import {
  useAccount,
  usePublicClient,
  useReadContract,
  useSignTypedData,
  useWaitForTransactionReceipt,
  useWriteContract,
} from "wagmi";
import externalContracts from "~~/contracts/externalContracts";

// ─────────────────────────────────────────────────────────────────────────────
// BodaSave — rider-facing surface (M-Pesa first, PWA-ready)
// ─────────────────────────────────────────────────────────────────────────────

const CHAIN_ID = 84532;
const MOCKUSDC_ADDRESS = externalContracts[CHAIN_ID].MockUSDC.address as `0x${string}`;
const SAVINGS_ADDRESS = externalContracts[CHAIN_ID].BodaBodaSavings.address as `0x${string}`;
const MOCKUSDC_ABI = externalContracts[CHAIN_ID].MockUSDC.abi;
const SAVINGS_ABI = externalContracts[CHAIN_ID].BodaBodaSavings.abi;

const KES_PER_USDC = 130;

const usdcUnitsToKes = (units: bigint): number => {
  const usdc = Number(formatUnits(units, 6));
  return usdc * KES_PER_USDC;
};

const kesFmt = (kes: number): string =>
  "KES " + kes.toLocaleString("en-KE", { maximumFractionDigits: 0 });

const KE_PHONE_RE = /^254[17]\d{8}$/;

type Rider = {
  name: string;
  gender: `0x${string}`;
  lenderAddress: `0x${string}`;
  splitRatio: number;
  loanTarget: bigint;
  loanBalance: bigint;
  loanRepaid: bigint;
  savingsBalance: bigint;
  totalDeposited: bigint;
  totalWithdrawn: bigint;
  withdrawalCount: bigint;
  lastDepositAt: bigint;
  firstDepositAt: bigint;
  lastSettledAt: bigint;
  savingsRemainder: bigint;
  age: number;
  registered: boolean;
};

type RiderAnalytics = {
  savingsBalance: bigint;
  loanBalance: bigint;
  totalDeposited: bigint;
  totalWithdrawn: bigint;
  withdrawalCount: bigint;
  lastDepositAt: bigint;
  firstDepositAt: bigint;
  loanRepaid: bigint;
  lastSettledAt: bigint;
  nextSettlementDue: bigint;
};

type LoanStatus = readonly [bigint, bigint, bigint, bigint, boolean, bigint];

type TopUpState = "idle" | "pending" | "credited";

export default function BodaSaveRider() {
  const { address, isConnected } = useAccount();
  const publicClient = usePublicClient();

  const [phone, setPhone] = useState("");
  const [topUpKes, setTopUpKes] = useState("");
  const [topUpState, setTopUpState] = useState<TopUpState>("idle");
  const [topUpError, setTopUpError] = useState<string | null>(null);
  const [lastCreditedKes, setLastCreditedKes] = useState<number | null>(null);
  const [devOpen, setDevOpen] = useState(false);

  const { data: riderRaw, refetch: refetchRider } = useReadContract({
    address: SAVINGS_ADDRESS,
    abi: SAVINGS_ABI,
    functionName: "getRider",
    args: address ? [address] : undefined,
  });

  const { data: analyticsRaw, refetch: refetchAnalytics } = useReadContract({
    address: SAVINGS_ADDRESS,
    abi: SAVINGS_ABI,
    functionName: "getRiderAnalytics",
    args: address ? [address] : undefined,
  });

  const { data: loanRaw, refetch: refetchLoan } = useReadContract({
    address: SAVINGS_ADDRESS,
    abi: SAVINGS_ABI,
    functionName: "getLoanStatus",
    args: address ? [address] : undefined,
  });

  const { data: usdcBalance, refetch: refetchUsdc } = useReadContract({
    address: MOCKUSDC_ADDRESS,
    abi: MOCKUSDC_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
  });

  const rider = riderRaw as Rider | undefined;
  const analytics = analyticsRaw as RiderAnalytics | undefined;
  const loan = loanRaw as LoanStatus | undefined;

  const isRegistered = rider?.registered ?? false;
  const riderName = rider?.name && rider.name.length > 0 ? rider.name : "John Doe";

  const savingsUnits = analytics?.savingsBalance ?? 0n;
  const savingsKes = usdcUnitsToKes(savingsUnits);
  const totalDepositedKes = usdcUnitsToKes(analytics?.totalDeposited ?? 0n);

  const loanProgressBps = loan ? Number(loan[5]) : 0;
  const loanPct = Math.round(loanProgressBps / 100);
  const loanCleared = loan ? loan[4] : false;
  const loanTargetKes = loan ? usdcUnitsToKes(loan[0]) : 0;
  const loanRepaidKes = loan ? usdcUnitsToKes(loan[2]) : 0;

  const nextSettlementDue = Number(analytics?.nextSettlementDue ?? 0n);
  const nextSettlementLabel =
    nextSettlementDue > 0
      ? new Date(nextSettlementDue * 1000).toLocaleDateString("en-KE", {
          weekday: "short",
          day: "numeric",
          month: "short",
        })
      : "—";

  // ── Top-up via M-Pesa ────────────────────────────────────────────────────
  const handleTopUp = async () => {
    setTopUpError(null);
    if (!address) { setTopUpError("Connect your wallet first."); return; }
    if (!KE_PHONE_RE.test(phone)) { setTopUpError("Enter your phone as 2547XXXXXXXX."); return; }
    const kes = Number(topUpKes);
    if (!kes || kes <= 0) { setTopUpError("Enter an amount in KES."); return; }

    setTopUpState("pending");
    const savingsBefore = savingsUnits;

    try {
      const res = await fetch("/api/intasend/stk-push", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ amountKes: kes, phoneNumber: phone, riderAddress: address }),
      });
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        throw new Error(data?.error || "Could not start the M-Pesa payment.");
      }
      pollForCredit(savingsBefore, kes);
    } catch (e: any) {
      setTopUpState("idle");
      setTopUpError(e?.message || "Something went wrong. Try again.");
    }
  };

  const pollForCredit = (savingsBefore: bigint, kes: number) => {
    let elapsed = 0;
    const intervalMs = 4000;
    const timeoutMs = 120000;
    const timer = setInterval(async () => {
      elapsed += intervalMs;
      const { data } = await refetchAnalytics();
      const updated = data as RiderAnalytics | undefined;
      if (updated && updated.savingsBalance > savingsBefore) {
        clearInterval(timer);
        refetchRider(); refetchLoan(); refetchUsdc();
        setLastCreditedKes(kes);
        setTopUpState("credited");
        return;
      }
      if (elapsed >= timeoutMs) {
        clearInterval(timer);
        setTopUpState("idle");
        setTopUpError("We didn\u2019t see the payment land. If you paid, your balance will update shortly.");
      }
    }, intervalMs);
  };

  const resetTopUp = () => {
    setTopUpState("idle"); setTopUpKes(""); setTopUpError(null); setLastCreditedKes(null);
  };

  // ── Not connected ────────────────────────────────────────────────────────
  if (!isConnected) {
    return (
      <div className="min-h-screen bg-gradient-to-b from-[#061119] via-[#0a1929] to-[#061119] flex items-center justify-center p-6">
        <div className="text-center max-w-xs space-y-5">
          <div className="mx-auto w-20 h-20 rounded-2xl bg-gradient-to-br from-emerald-500 to-teal-600 flex items-center justify-center shadow-lg shadow-emerald-500/20">
            <span className="text-4xl">🏍️</span>
          </div>
          <div>
            <h1 className="text-3xl font-extrabold text-white tracking-tight">BodaSave</h1>
            <p className="text-emerald-400/80 text-sm font-medium mt-1">Save smart. Ride free.</p>
          </div>
          <p className="text-slate-500 text-sm leading-relaxed">
            Connect to start saving and pay off your loan with M-Pesa.
          </p>
        </div>
      </div>
    );
  }

  // ── Main rider screen ────────────────────────────────────────────────────
  return (
    <div className="min-h-screen bg-gradient-to-b from-[#061119] via-[#0a1929] to-[#0d1f33]">
      <div className="max-w-lg mx-auto">
        {/* ── Top bar ──────────────────────────────────────────────────────── */}
        <div className="px-5 pt-5 pb-3 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="w-11 h-11 rounded-xl bg-gradient-to-br from-emerald-500 to-teal-600 flex items-center justify-center shadow-md shadow-emerald-500/20">
              <span className="text-xl">🏍️</span>
            </div>
            <div>
              <p className="font-bold text-white leading-tight tracking-tight">{riderName}</p>
              <p className="text-[11px] text-slate-500 leading-tight">
                {phone ? phone.replace(/(\d{4})(\d{3})(\d{3})(\d{2})/, "$1 $2 $3 $4") : "Add phone below"}
              </p>
            </div>
          </div>
          <div className="w-9 h-9 rounded-full bg-slate-800/60 flex items-center justify-center">
            <span className="text-slate-400 text-sm">🔔</span>
          </div>
        </div>

        {!isRegistered && (
          <div className="mx-5 mb-3 bg-amber-500/10 border border-amber-500/20 rounded-xl px-4 py-3 text-sm text-amber-300/90">
            This wallet isn&apos;t registered as a rider yet. Top-ups won&apos;t be credited until registration.
          </div>
        )}

        {/* ── Savings hero ─────────────────────────────────────────────────── */}
        <div className="mx-5 mt-2 rounded-2xl bg-gradient-to-br from-emerald-600/20 via-emerald-500/10 to-teal-600/5 border border-emerald-500/15 p-6">
          <p className="text-xs font-medium text-emerald-400/70 uppercase tracking-widest mb-2">My savings</p>
          <p className="text-4xl font-extrabold text-white tracking-tight">{kesFmt(savingsKes)}</p>
          <div className="flex items-center gap-2 mt-3">
            <span className="inline-block w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse" />
            <p className="text-xs text-slate-400">
              Total deposited: {kesFmt(totalDepositedKes)}
            </p>
          </div>
        </div>

        {/* ── Loan & schedule strip ────────────────────────────────────────── */}
        <div className="px-5 mt-4 grid grid-cols-2 gap-3">
          <div className="rounded-2xl bg-slate-800/30 border border-slate-700/40 p-4 space-y-3">
            <p className="text-[11px] font-medium text-slate-500 uppercase tracking-wider">Loan</p>
            <div className="flex items-end gap-2">
              <p className="text-2xl font-bold text-white leading-none">
                {loanCleared ? "✓" : `${loanPct}%`}
              </p>
              {!loanCleared && (
                <p className="text-[10px] text-slate-500 pb-0.5">
                  {kesFmt(loanRepaidKes)} / {kesFmt(loanTargetKes)}
                </p>
              )}
            </div>
            <div className="h-2 bg-slate-700/50 rounded-full overflow-hidden">
              <div
                className="h-full rounded-full transition-all duration-700"
                style={{
                  width: `${Math.min(loanPct, 100)}%`,
                  background: loanCleared
                    ? "#10b981"
                    : "linear-gradient(90deg, #0ea5e9, #06b6d4)",
                }}
              />
            </div>
          </div>

          <div className="rounded-2xl bg-slate-800/30 border border-slate-700/40 p-4 flex flex-col justify-between">
            <p className="text-[11px] font-medium text-slate-500 uppercase tracking-wider">Next SACCO pay</p>
            <div>
              <p className="text-xl font-bold text-white mt-1">{nextSettlementLabel}</p>
              <p className="text-[10px] text-teal-400/60 mt-1">Automatic</p>
            </div>
          </div>
        </div>

        {/* ── M-Pesa top-up card ───────────────────────────────────────────── */}
        <div className="mx-5 mt-4 rounded-2xl bg-slate-800/20 border border-slate-700/30 overflow-hidden">
          {topUpState === "idle" && (
            <div className="p-5 space-y-4">
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 rounded-lg bg-green-600/20 flex items-center justify-center">
                  <span className="text-sm">📱</span>
                </div>
                <h2 className="text-base font-bold tracking-tight">Top up with M-Pesa</h2>
              </div>

              <div className="space-y-3">
                <div>
                  <label className="text-[11px] font-medium text-slate-500 block mb-1.5">Phone number</label>
                  <input
                    inputMode="numeric"
                    value={phone}
                    onChange={(e) => setPhone(e.target.value.trim())}
                    placeholder="2547XXXXXXXX"
                    className="w-full bg-slate-900/60 border border-slate-700/50 rounded-xl px-4 py-3.5 text-base text-white placeholder:text-slate-600 focus:outline-none focus:border-emerald-500/50 focus:ring-1 focus:ring-emerald-500/20 transition-colors"
                  />
                </div>
                <div>
                  <label className="text-[11px] font-medium text-slate-500 block mb-1.5">Amount (KES)</label>
                  <input
                    inputMode="numeric"
                    value={topUpKes}
                    onChange={(e) => setTopUpKes(e.target.value.trim())}
                    placeholder="500"
                    className="w-full bg-slate-900/60 border border-slate-700/50 rounded-xl px-4 py-3.5 text-base text-white placeholder:text-slate-600 focus:outline-none focus:border-emerald-500/50 focus:ring-1 focus:ring-emerald-500/20 transition-colors"
                  />
                </div>
              </div>

              {topUpError && (
                <p className="text-sm text-red-400 bg-red-500/10 rounded-lg px-3 py-2">{topUpError}</p>
              )}

              <button
                onClick={handleTopUp}
                disabled={!phone || !topUpKes}
                className="w-full bg-gradient-to-r from-emerald-600 to-teal-600 hover:from-emerald-500 hover:to-teal-500 disabled:from-slate-700 disabled:to-slate-700 disabled:text-slate-500 py-4 rounded-xl font-bold text-base flex items-center justify-center gap-2 shadow-lg shadow-emerald-600/20 disabled:shadow-none transition-all active:scale-[0.98]"
              >
                Top up with M-Pesa
              </button>
            </div>
          )}

          {topUpState === "pending" && (
            <div className="p-8 text-center space-y-4">
              <div className="mx-auto w-16 h-16 rounded-2xl bg-amber-500/10 flex items-center justify-center">
                <span className="text-3xl">📲</span>
              </div>
              <div>
                <h2 className="text-lg font-bold text-white">Check your phone</h2>
                <p className="text-sm text-slate-400 mt-2 leading-relaxed">
                  Enter your M-Pesa PIN to confirm<br />
                  <span className="text-white font-semibold">{kesFmt(Number(topUpKes))}</span>
                </p>
              </div>
              <div className="flex justify-center pt-1">
                <div className="w-7 h-7 border-[2.5px] border-emerald-500 border-t-transparent rounded-full animate-spin" />
              </div>
            </div>
          )}

          {topUpState === "credited" && (
            <div className="p-8 text-center space-y-4">
              <div className="mx-auto w-16 h-16 rounded-2xl bg-emerald-500/10 flex items-center justify-center">
                <span className="text-3xl">✅</span>
              </div>
              <div>
                <h2 className="text-lg font-bold text-emerald-400">
                  {lastCreditedKes ? kesFmt(lastCreditedKes) : "Payment"} added
                </h2>
                <p className="text-sm text-slate-400 mt-1">
                  Split between your savings and loan repayment.
                </p>
              </div>
              <button
                onClick={resetTopUp}
                className="w-full bg-slate-800 hover:bg-slate-700 py-3.5 rounded-xl font-semibold transition-colors active:scale-[0.98]"
              >
                Done
              </button>
            </div>
          )}
        </div>

        {/* ── Dev panel ────────────────────────────────────────────────────── */}
        <div className="px-5 mt-6 mb-8">
          <DevPanel
            open={devOpen}
            onToggle={() => setDevOpen((o) => !o)}
            address={address as `0x${string}` | undefined}
            usdcBalance={usdcBalance as bigint | undefined}
            analytics={analytics}
            loanBalance={analytics?.loanBalance ?? 0n}
            nextSettlementDue={nextSettlementDue}
            publicClient={publicClient}
            onChainChange={() => { refetchRider(); refetchAnalytics(); refetchLoan(); refetchUsdc(); }}
          />
        </div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// DEV PANEL
// ─────────────────────────────────────────────────────────────────────────────
function DevPanel({
  open, onToggle, address, usdcBalance, analytics, loanBalance,
  nextSettlementDue, publicClient, onChainChange,
}: {
  open: boolean;
  onToggle: () => void;
  address?: `0x${string}`;
  usdcBalance?: bigint;
  analytics?: RiderAnalytics;
  loanBalance: bigint;
  nextSettlementDue: number;
  publicClient: ReturnType<typeof usePublicClient>;
  onChainChange: () => void;
}) {
  const [depositAmount, setDepositAmount] = useState("");
  const [permitBusy, setPermitBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);

  const { signTypedDataAsync } = useSignTypedData();
  const { writeContract: writeFaucet, data: faucetHash } = useWriteContract();
  const { writeContract: writeDeposit, data: depositHash } = useWriteContract();
  const { writeContract: writeSettle, data: settleHash } = useWriteContract();

  const { isSuccess: faucetOk } = useWaitForTransactionReceipt({ hash: faucetHash });
  const { isSuccess: depositOk } = useWaitForTransactionReceipt({ hash: depositHash });
  const { isSuccess: settleOk } = useWaitForTransactionReceipt({ hash: settleHash });

  useEffect(() => {
    if (faucetOk || depositOk || settleOk) onChainChange();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [faucetOk, depositOk, settleOk]);

  const nowSec = Math.floor(Date.now() / 1000);
  const isSettlementDue = nextSettlementDue > 0 && nowSec >= nextSettlementDue;
  const usdcFmt = (v?: bigint) => v != null ? parseFloat(formatUnits(v, 6)).toFixed(2) : "0.00";

  const handleFaucet = () =>
    writeFaucet({ address: MOCKUSDC_ADDRESS, abi: MOCKUSDC_ABI, functionName: "faucet", args: [parseUnits("100", 6)] });

  const handleSettle = () => {
    if (!address) return;
    writeSettle({ address: SAVINGS_ADDRESS, abi: SAVINGS_ABI, functionName: "settleLoanRepayment", args: [address] });
  };

  const handlePermitDeposit = async () => {
    if (!address || !publicClient || !depositAmount) return;
    try {
      setPermitBusy(true); setNote(null);
      const value = parseUnits(depositAmount, 6);
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 1800);

      const nonce = (await publicClient.readContract({
        address: MOCKUSDC_ADDRESS, abi: MOCKUSDC_ABI, functionName: "nonces", args: [address],
      })) as bigint;

      const name = (await publicClient.readContract({
        address: MOCKUSDC_ADDRESS, abi: MOCKUSDC_ABI, functionName: "name",
      })) as string;

      const signature = await signTypedDataAsync({
        domain: { name, version: "1", chainId: CHAIN_ID, verifyingContract: MOCKUSDC_ADDRESS },
        types: { Permit: [
          { name: "owner", type: "address" }, { name: "spender", type: "address" },
          { name: "value", type: "uint256" }, { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ]},
        primaryType: "Permit",
        message: { owner: address, spender: SAVINGS_ADDRESS, value, nonce, deadline },
      });

      const sig = signature.slice(2);
      const r = `0x${sig.slice(0, 64)}` as `0x${string}`;
      const s = `0x${sig.slice(64, 128)}` as `0x${string}`;
      const v = parseInt(sig.slice(128, 130), 16);

      writeDeposit({
        address: SAVINGS_ADDRESS, abi: SAVINGS_ABI, functionName: "depositWithPermit",
        args: [value, deadline, v, r, s],
      });
      setDepositAmount("");
    } catch { setNote("Signature rejected."); }
    finally { setPermitBusy(false); }
  };

  return (
    <div className="rounded-xl border border-slate-800/60 overflow-hidden">
      <button
        onClick={onToggle}
        className="w-full flex items-center justify-between px-4 py-2.5 text-[10px] font-mono text-slate-600 hover:text-slate-400 bg-slate-900/30 transition-colors"
      >
        <span>DEV PANEL</span>
        <span>{open ? "▲" : "▼"}</span>
      </button>
      {open && (
        <div className="p-4 space-y-3 bg-slate-900/20">
          <div className="grid grid-cols-3 gap-2 text-center">
            {[
              ["Wallet", usdcFmt(usdcBalance)],
              ["Savings", usdcFmt(analytics?.savingsBalance)],
              ["Loan", usdcFmt(loanBalance)],
            ].map(([label, val]) => (
              <div key={label} className="bg-slate-800/30 rounded-lg p-2">
                <p className="text-[9px] text-slate-600 uppercase">{label}</p>
                <p className="text-xs font-bold text-slate-300">{val}</p>
              </div>
            ))}
          </div>
          <p className="text-[9px] font-mono text-slate-700 break-all">rider: {address}</p>
          <div className="flex gap-2">
            <button onClick={handleFaucet} className="flex-1 bg-slate-800 hover:bg-slate-700 py-2 rounded-lg text-xs font-medium transition-colors">
              +100 USDC
            </button>
            <button onClick={handleSettle} disabled={!isSettlementDue || loanBalance === 0n}
              className="flex-1 bg-sky-900/50 hover:bg-sky-800/50 disabled:bg-slate-900 disabled:text-slate-700 py-2 rounded-lg text-xs font-medium transition-colors">
              {!isSettlementDue ? "Not due" : loanBalance === 0n ? "Nothing" : "Settle"}
            </button>
          </div>
          <div className="flex gap-2">
            <input inputMode="decimal" value={depositAmount} onChange={(e) => setDepositAmount(e.target.value.trim())}
              placeholder="USDC" className="flex-1 bg-slate-900/60 border border-slate-800 rounded-lg px-3 py-2 text-xs focus:outline-none focus:border-slate-600" />
            <button onClick={handlePermitDeposit} disabled={!depositAmount || permitBusy}
              className="bg-emerald-800/50 hover:bg-emerald-700/50 disabled:opacity-40 px-3 py-2 rounded-lg text-xs font-medium transition-colors">
              {permitBusy ? "…" : "Permit"}
            </button>
          </div>
          {note && <p className="text-[10px] text-red-400">{note}</p>}
        </div>
      )}
    </div>
  );
}