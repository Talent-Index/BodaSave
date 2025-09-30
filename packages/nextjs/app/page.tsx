"use client";

import { useState, useEffect } from "react";
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { parseUnits, formatUnits } from "viem";
import externalContracts from "~~/contracts/externalContracts";

const MOCKUSDC_ADDRESS = externalContracts[84532].MockUSDC.address as `0x${string}`;
const SAVINGS_ADDRESS = externalContracts[84532].BodaBodaSavings.address as `0x${string}`;
const MOCKUSDC_ABI = externalContracts[84532].MockUSDC.abi;
const SAVINGS_ABI = externalContracts[84532].BodaBodaSavings.abi;

export default function BodaBodaSavings() {
  const { address, isConnected } = useAccount();
  const [depositAmount, setDepositAmount] = useState("");
  const [withdrawAmount, setWithdrawAmount] = useState("");
  const [activeTab, setActiveTab] = useState<"deposit" | "withdraw" | "stats">("deposit");
  const [showSuccessToast, setShowSuccessToast] = useState(false);
  const [toastMessage, setToastMessage] = useState("");

  const { data: usdcBalance, refetch: refetchBalance } = useReadContract({
    address: MOCKUSDC_ADDRESS,
    abi: MOCKUSDC_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
  });

  const { data: userBalances, refetch: refetchUserBalances } = useReadContract({
    address: SAVINGS_ADDRESS,
    abi: SAVINGS_ABI,
    functionName: "getBalances",
    args: address ? [address] : undefined,
  });

  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: MOCKUSDC_ADDRESS,
    abi: MOCKUSDC_ABI,
    functionName: "allowance",
    args: address ? [address, SAVINGS_ADDRESS] : undefined,
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

  const { writeContract: writeFaucet, data: faucetHash } = useWriteContract();
  const { writeContract: writeApprove, data: approveHash } = useWriteContract();
  const { writeContract: writeDeposit, data: depositHash } = useWriteContract();
  const { writeContract: writeWithdraw, data: withdrawHash } = useWriteContract();

  const { isLoading: isFaucetLoading, isSuccess: isFaucetSuccess } = useWaitForTransactionReceipt({ hash: faucetHash });
  const { isLoading: isApproveLoading, isSuccess: isApproveSuccess } = useWaitForTransactionReceipt({ hash: approveHash });
  const { isLoading: isDepositLoading, isSuccess: isDepositSuccess } = useWaitForTransactionReceipt({ hash: depositHash });
  const { isLoading: isWithdrawLoading, isSuccess: isWithdrawSuccess } = useWaitForTransactionReceipt({ hash: withdrawHash });

  useEffect(() => {
    if (isFaucetSuccess) {
      refetchBalance();
      showToast("100 USDC received!");
    }
  }, [isFaucetSuccess]);

  useEffect(() => {
    if (isApproveSuccess) {
      refetchAllowance();
      showToast("Approval successful! Ready to deposit.");
    }
  }, [isApproveSuccess]);

  useEffect(() => {
    if (isDepositSuccess) {
      refetchBalance();
      refetchUserBalances();
      setDepositAmount("");
      showToast("Deposit successful! Savings updated.");
    }
  }, [isDepositSuccess]);

  useEffect(() => {
    if (isWithdrawSuccess) {
      refetchBalance();
      refetchUserBalances();
      setWithdrawAmount("");
      showToast("Withdrawal complete! Funds sent to wallet.");
    }
  }, [isWithdrawSuccess]);

  const showToast = (message: string) => {
    setToastMessage(message);
    setShowSuccessToast(true);
    setTimeout(() => setShowSuccessToast(false), 5000);
  };

  const handleFaucet = () => writeFaucet({ address: MOCKUSDC_ADDRESS, abi: MOCKUSDC_ABI, functionName: "faucet", args: [parseUnits("100", 6)] });
  const handleApprove = () => {
    if (!depositAmount) return;
    writeApprove({ address: MOCKUSDC_ADDRESS, abi: MOCKUSDC_ABI, functionName: "approve", args: [SAVINGS_ADDRESS, parseUnits(depositAmount, 6)] });
  };
  const handleDeposit = () => {
    if (!depositAmount) return;
    writeDeposit({ address: SAVINGS_ADDRESS, abi: SAVINGS_ABI, functionName: "deposit", args: [parseUnits(depositAmount, 6)] });
  };
  const handleWithdraw = () => {
    if (!withdrawAmount) return;
    writeWithdraw({ address: SAVINGS_ADDRESS, abi: SAVINGS_ABI, functionName: "withdrawSavings", args: [parseUnits(withdrawAmount, 6)] });
  };

  const needsApproval = depositAmount && allowance ? BigInt(parseUnits(depositAmount, 6)) > allowance : true;
  const formatBalance = (val: any) => (val ? parseFloat(formatUnits(val as bigint, 6)).toFixed(2) : "0.00");

  if (!isConnected) {
    return (
      <div className="min-h-screen bg-gradient-to-br from-emerald-50 via-teal-50 to-cyan-50 flex items-center justify-center p-4">
        <div className="bg-white rounded-3xl shadow-2xl p-12 max-w-lg text-center">
          <div className="w-20 h-20 bg-emerald-100 rounded-full flex items-center justify-center mx-auto mb-6">
            <svg className="w-10 h-10 text-emerald-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M17 9V7a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2m2 4h10a2 2 0 002-2v-6a2 2 0 00-2-2H9a2 2 0 00-2 2v6a2 2 0 002 2zm7-5a2 2 0 11-4 0 2 2 0 014 0z" />
            </svg>
          </div>
          <h2 className="text-4xl font-bold bg-gradient-to-r from-emerald-600 to-teal-600 bg-clip-text text-transparent mb-4">BodaBoda Savings</h2>
          <p className="text-gray-600 text-lg mb-8">Save smart, build credit, secure your future on the blockchain.</p>
          <div className="bg-gradient-to-r from-emerald-500 to-teal-600 text-white px-8 py-4 rounded-2xl font-semibold inline-flex items-center gap-3 shadow-lg">
            Connect wallet to continue
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gradient-to-br from-emerald-50 via-teal-50 to-cyan-50 py-8 px-4">
      {showSuccessToast && (
        <div className="fixed top-8 right-8 z-50">
          <div className="bg-white rounded-2xl shadow-2xl p-4 pr-12 border-l-4 border-emerald-500 flex items-center gap-3 min-w-[300px]">
            <div className="w-10 h-10 bg-emerald-100 rounded-full flex items-center justify-center">
              <svg className="w-6 h-6 text-emerald-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 13l4 4L19 7" />
              </svg>
            </div>
            <p className="text-gray-800 font-medium">{toastMessage}</p>
            <button onClick={() => setShowSuccessToast(false)} className="absolute top-3 right-3 text-gray-400">
              ×
            </button>
          </div>
        </div>
      )}

      <div className="max-w-7xl mx-auto">
        <div className="text-center mb-12">
          <h1 className="text-5xl font-bold bg-gradient-to-r from-emerald-600 to-teal-600 bg-clip-text text-transparent mb-4">
            BodaBoda Savings
          </h1>
          <p className="text-gray-600 text-lg">The smart way to save, build credit, and secure your financial future</p>
        </div>

        <div className="grid md:grid-cols-3 gap-6 mb-8">
          <div className="bg-white rounded-3xl shadow-xl p-6">
            <div className="flex items-center justify-between mb-3">
              <span className="text-sm font-medium text-gray-600">Wallet Balance</span>
              <div className="w-10 h-10 bg-emerald-100 rounded-xl flex items-center justify-center">
                <svg className="w-5 h-5 text-emerald-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M3 10h18M7 15h1m4 0h1m-7 4h12a3 3 0 003-3V8a3 3 0 00-3-3H6a3 3 0 00-3 3v8a3 3 0 003 3z" />
                </svg>
              </div>
            </div>
            <div className="flex items-baseline gap-2 mb-4">
              <span className="text-4xl font-bold">{formatBalance(usdcBalance)}</span>
              <span className="text-lg text-gray-500">USDC</span>
            </div>
            <button onClick={handleFaucet} disabled={isFaucetLoading} className="w-full bg-gradient-to-r from-emerald-500 to-teal-600 text-white px-4 py-3 rounded-xl font-semibold hover:shadow-lg transition-all disabled:opacity-50">
              {isFaucetLoading ? "Claiming..." : "Get 100 Test USDC"}
            </button>
          </div>

          <div className="bg-white rounded-3xl shadow-xl p-6">
            <div className="flex items-center justify-between mb-3">
              <span className="text-sm font-medium text-gray-600">Your Savings</span>
              <div className="w-10 h-10 bg-teal-100 rounded-xl flex items-center justify-center">
                <svg className="w-5 h-5 text-teal-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M17 9V7a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2m2 4h10a2 2 0 002-2v-6a2 2 0 00-2-2H9a2 2 0 00-2 2v6a2 2 0 002 2zm7-5a2 2 0 11-4 0 2 2 0 014 0z" />
                </svg>
              </div>
            </div>
            <div className="flex items-baseline gap-2 mb-2">
              <span className="text-4xl font-bold">{formatBalance(userBalances?.[0])}</span>
              <span className="text-lg text-gray-500">USDC</span>
            </div>
            <p className="text-xs text-teal-600">50% of each deposit</p>
          </div>

          <div className="bg-white rounded-3xl shadow-xl p-6">
            <div className="flex items-center justify-between mb-3">
              <span className="text-sm font-medium text-gray-600">Loan Credit</span>
              <div className="w-10 h-10 bg-cyan-100 rounded-xl flex items-center justify-center">
                <svg className="w-5 h-5 text-cyan-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z" />
                </svg>
              </div>
            </div>
            <div className="flex items-baseline gap-2 mb-2">
              <span className="text-4xl font-bold">{formatBalance(userBalances?.[1])}</span>
              <span className="text-lg text-gray-500">USDC</span>
            </div>
            <p className="text-xs text-cyan-600">Builds trustworthiness</p>
          </div>
        </div>

        <div className="bg-white rounded-3xl shadow-2xl overflow-hidden">
          <div className="flex border-b">
            {[
              { id: "deposit", label: "Deposit" },
              { id: "withdraw", label: "Withdraw" },
              { id: "stats", label: "Statistics" }
            ].map((tab) => (
              <button
                key={tab.id}
                onClick={() => setActiveTab(tab.id as any)}
                className={`flex-1 py-5 px-6 font-semibold transition-all ${
                  activeTab === tab.id
                    ? "bg-gradient-to-r from-emerald-500 to-teal-600 text-white"
                    : "text-gray-600 hover:bg-gray-50"
                }`}
              >
                {tab.label}
              </button>
            ))}
          </div>

          <div className="p-8">
            {activeTab === "deposit" && (
              <div className="max-w-2xl mx-auto space-y-6">
                <h3 className="text-3xl font-bold mb-2">Make a Deposit</h3>
                <p className="text-gray-600 mb-6">Deposit funds to build your savings and loan credit simultaneously</p>
                
                <div>
                  <label className="block text-sm font-semibold text-gray-700 mb-3">Deposit Amount</label>
                  <input
                    type="number"
                    value={depositAmount}
                    onChange={(e) => setDepositAmount(e.target.value)}
                    placeholder="0.00"
                    className="w-full px-6 py-4 border-2 border-gray-200 rounded-2xl focus:border-emerald-500 focus:outline-none text-xl font-semibold"
                  />
                </div>

                <div className="bg-gradient-to-br from-emerald-50 to-teal-50 rounded-2xl p-6 space-y-3">
                  <h4 className="font-semibold mb-4">Split Breakdown</h4>
                  <div className="flex justify-between p-4 bg-white rounded-xl">
                    <span className="text-gray-700 font-medium">To Savings (50%)</span>
                    <span className="text-2xl font-bold">{depositAmount ? (Number(depositAmount) / 2).toFixed(2) : "0.00"} USDC</span>
                  </div>
                  <div className="flex justify-between p-4 bg-white rounded-xl">
                    <span className="text-gray-700 font-medium">To Loan Credit (50%)</span>
                    <span className="text-2xl font-bold">{depositAmount ? (Number(depositAmount) / 2).toFixed(2) : "0.00"} USDC</span>
                  </div>
                </div>

                {(isApproveLoading || isDepositLoading) && (
                  <div className="bg-amber-50 border border-amber-200 rounded-2xl p-4 flex items-center gap-3">
                    <div className="animate-spin rounded-full h-6 w-6 border-b-2 border-amber-600"></div>
                    <span className="text-amber-900 font-medium">
                      {isApproveLoading ? "Approving..." : "Processing deposit..."}
                    </span>
                  </div>
                )}

                {needsApproval ? (
                  <button onClick={handleApprove} disabled={!depositAmount || isApproveLoading} className="w-full bg-gradient-to-r from-emerald-500 to-teal-600 text-white py-5 rounded-2xl font-bold text-lg hover:shadow-2xl transition-all disabled:opacity-50">
                    {isApproveLoading ? "Approving..." : "Approve USDC"}
                  </button>
                ) : (
                  <button onClick={handleDeposit} disabled={!depositAmount || isDepositLoading} className="w-full bg-gradient-to-r from-emerald-500 to-teal-600 text-white py-5 rounded-2xl font-bold text-lg hover:shadow-2xl transition-all disabled:opacity-50">
                    {isDepositLoading ? "Processing..." : "Deposit Now"}
                  </button>
                )}
              </div>
            )}

            {activeTab === "withdraw" && (
              <div className="max-w-2xl mx-auto space-y-6">
                <h3 className="text-3xl font-bold mb-2">Withdraw Savings</h3>
                <p className="text-gray-600 mb-6">Withdraw your savings anytime</p>
                
                <div>
                  <label className="block text-sm font-semibold text-gray-700 mb-3">Withdrawal Amount</label>
                  <input
                    type="number"
                    value={withdrawAmount}
                    onChange={(e) => setWithdrawAmount(e.target.value)}
                    placeholder="0.00"
                    max={formatBalance(userBalances?.[0])}
                    className="w-full px-6 py-4 border-2 border-gray-200 rounded-2xl focus:border-emerald-500 focus:outline-none text-xl font-semibold"
                  />
                </div>

                <div className="bg-amber-50 rounded-2xl p-4">
                  <p className="text-amber-800">Available: {formatBalance(userBalances?.[0])} USDC</p>
                </div>

                {isWithdrawLoading && (
                  <div className="bg-amber-50 border border-amber-200 rounded-2xl p-4 flex items-center gap-3">
                    <div className="animate-spin rounded-full h-6 w-6 border-b-2 border-amber-600"></div>
                    <span className="text-amber-900 font-medium">Processing withdrawal...</span>
                  </div>
                )}

                <button onClick={handleWithdraw} disabled={!withdrawAmount || isWithdrawLoading} className="w-full bg-gradient-to-r from-orange-500 to-red-600 text-white py-5 rounded-2xl font-bold text-lg hover:shadow-2xl transition-all disabled:opacity-50">
                  {isWithdrawLoading ? "Processing..." : "Withdraw"}
                </button>
              </div>
            )}

            {activeTab === "stats" && (
              <div className="max-w-2xl mx-auto">
                <h3 className="text-3xl font-bold mb-6">Platform Statistics</h3>
                <div className="grid md:grid-cols-2 gap-6">
                  <div className="bg-gradient-to-br from-emerald-50 to-emerald-100 rounded-2xl p-6">
                    <p className="text-sm text-emerald-700 mb-2">Contract Balance</p>
                    <p className="text-3xl font-bold text-emerald-800">{formatBalance(contractBalance)}</p>
                    <p className="text-sm text-emerald-600 mt-1">USDC</p>
                  </div>
                  <div className="bg-gradient-to-br from-cyan-50 to-cyan-100 rounded-2xl p-6">
                    <p className="text-sm text-cyan-700 mb-2">Total Loan Credits</p>
                    <p className="text-3xl font-bold text-cyan-800">{formatBalance(totalLoanCredits)}</p>
                    <p className="text-sm text-cyan-600 mt-1">USDC</p>
                  </div>
                </div>

                <div className="mt-8 bg-blue-50 rounded-2xl p-6">
                  <h4 className="font-semibold mb-4">How It Works</h4>
                  <ol className="space-y-3 text-sm text-gray-700">
                    <li className="flex items-start">
                      <span className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center mr-3">1</span>
                      <span>Deposit USDC into your savings account</span>
                    </li>
                    <li className="flex items-start">
                      <span className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center mr-3">2</span>
                      <span>50% goes to your personal savings, 50% builds loan credit</span>
                    </li>
                    <li className="flex items-start">
                      <span className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center mr-3">3</span>
                      <span>Withdraw your savings anytime</span>
                    </li>
                    <li className="flex items-start">
                      <span className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center mr-3">4</span>
                      <span>Loan credits help leasing companies trust you</span>
                    </li>
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