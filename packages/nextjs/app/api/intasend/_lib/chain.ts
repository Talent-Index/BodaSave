// packages/nextjs/app/api/intasend/_lib/chain.ts
//
// Server-only on-chain writer for the fiat rail's on-chain leg.
//
// Holds the relayer wallet and calls BodaBodaSavings.creditDeposit() on a rider's
// behalf after a completed M-Pesa payment. This file is the ONLY place the relayer
// private key is read, and it must never be imported into a client component.
//
// SELF-HEALING ALLOWANCE (the reason this is Option B, not a one-time cast approve)
// ────────────────────────────────────────────────────────────────────────────────
// creditDeposit() pulls stablecoin FROM the relayer via transferFrom, so the relayer
// must have approved the BodaBodaSavings contract to spend its mUSDC. Rather than rely
// on a human running a one-time `cast approve` (which silently breaks the moment the
// contract is redeployed to a new address — likely, since this is still testnet and
// under active restructuring), we check the allowance before each credit and top it up
// to max if it's insufficient. A fresh contract address => zero allowance => the
// backend approves itself on the next webhook, no human in the loop. That is exactly
// the "doesn't need me to intervene" property the prototype needs.

import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  maxUint256,
  type Hex,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";

// ── Env (all server-only; none NEXT_PUBLIC_) ─────────────────────────────────
const RELAYER_PRIVATE_KEY = process.env.RELAYER_PRIVATE_KEY as Hex | undefined;
const BODASAVINGS_ADDRESS = process.env.BODASAVINGS_ADDRESS as Address | undefined;
const MOCKUSDC_ADDRESS = process.env.MOCKUSDC_ADDRESS as Address | undefined;
// Optional explicit RPC; falls back to viem's default Base Sepolia endpoint.
const BASE_SEPOLIA_RPC_URL = process.env.BASE_SEPOLIA_RPC_URL;

// Minimal ABIs — only the functions this module actually calls.
const bodaSavingsAbi = parseAbi([
  "function creditDeposit(address rider, uint256 amount)",
  "function relayer() view returns (address)",
  "function stablecoin() view returns (address)",
]);
const erc20Abi = parseAbi([
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function balanceOf(address account) view returns (uint256)",
]);

function requireConfig() {
  const missing: string[] = [];
  if (!RELAYER_PRIVATE_KEY) missing.push("RELAYER_PRIVATE_KEY");
  if (!BODASAVINGS_ADDRESS) missing.push("BODASAVINGS_ADDRESS");
  if (!MOCKUSDC_ADDRESS) missing.push("MOCKUSDC_ADDRESS");
  if (missing.length) {
    throw new Error(
      `chain.ts missing required env in packages/nextjs/.env.local: ${missing.join(", ")}`,
    );
  }
}

// Lazily constructed so a missing env var fails on first use with a clear message,
// rather than at module load (which would crash unrelated routes during dev).
//
// The client types are INFERRED from these factory functions rather than annotated
// with viem's bare `PublicClient`/`WalletClient` generics. baseSepolia carries
// OP-stack-specific block/transaction formatters, so the concrete client type that
// createPublicClient returns is not assignable to the bare generic — annotating with
// the generic triggers a "two different types with this name" error. Inference keeps
// the specialized type intact end-to-end.
function makeAccount() {
  return privateKeyToAccount(RELAYER_PRIVATE_KEY!);
}
function makePublicClient() {
  return createPublicClient({ chain: baseSepolia, transport: http(BASE_SEPOLIA_RPC_URL) });
}
function makeWalletClient(account: ReturnType<typeof makeAccount>) {
  return createWalletClient({ account, chain: baseSepolia, transport: http(BASE_SEPOLIA_RPC_URL) });
}

interface Clients {
  account: ReturnType<typeof makeAccount>;
  publicClient: ReturnType<typeof makePublicClient>;
  walletClient: ReturnType<typeof makeWalletClient>;
}
let _clients: Clients | undefined;

function clients(): Clients {
  if (_clients) return _clients;
  requireConfig();
  const account = makeAccount();
  _clients = {
    account,
    publicClient: makePublicClient(),
    walletClient: makeWalletClient(account),
  };
  return _clients;
}

export interface CreditResult {
  txHash: Hex;
  relayer: Address;
}

/**
 * Ensure the relayer has approved BodaBodaSavings to spend at least `amount` of mUSDC.
 * If not, send a max approval and wait for it to confirm before returning. Idempotent:
 * a no-op when allowance already suffices.
 */
async function ensureAllowance(amount: bigint): Promise<void> {
  const { account, publicClient, walletClient } = clients();

  const current = (await publicClient.readContract({
    address: MOCKUSDC_ADDRESS!,
    abi: erc20Abi,
    functionName: "allowance",
    args: [account.address, BODASAVINGS_ADDRESS!],
  })) as bigint;

  if (current >= amount) return;

  console.log(
    `Relayer allowance ${current} < needed ${amount}; sending max approval to ${BODASAVINGS_ADDRESS}`,
  );
  const approveHash = await walletClient.writeContract({
    address: MOCKUSDC_ADDRESS!,
    abi: erc20Abi,
    functionName: "approve",
    args: [BODASAVINGS_ADDRESS!, maxUint256],
    chain: baseSepolia,
    account,
  });
  await publicClient.waitForTransactionReceipt({ hash: approveHash });
  console.log(`Approval confirmed: ${approveHash}`);
}

/**
 * Credit `amount` (6-decimal mUSDC units) to `rider` via BodaBodaSavings.creditDeposit,
 * paid out of the relayer's own token balance. Ensures allowance first, then sends the
 * credit and waits for the receipt. Throws if the tx reverts (caller should release the
 * ledger claim so a retry can try again).
 *
 * Pre-flight checks (balance, relayer-role) are read-only and cheap; they let us fail
 * with a clear message instead of an opaque revert during testnet bring-up.
 */
export async function creditDepositOnChain(rider: Address, amount: bigint): Promise<CreditResult> {
  const { account, publicClient, walletClient } = clients();

  // Pre-flight: relayer must actually be the configured relayer on this contract.
  const onchainRelayer = (await publicClient.readContract({
    address: BODASAVINGS_ADDRESS!,
    abi: bodaSavingsAbi,
    functionName: "relayer",
  })) as Address;
  if (onchainRelayer.toLowerCase() !== account.address.toLowerCase()) {
    throw new Error(
      `Relayer mismatch: contract relayer is ${onchainRelayer} but backend wallet is ${account.address}. ` +
        `Did you call setRelayer for the current deployment? (Contract may have been redeployed.)`,
    );
  }

  // Pre-flight: relayer must hold enough mUSDC (creditDeposit is not a mint).
  const balance = (await publicClient.readContract({
    address: MOCKUSDC_ADDRESS!,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [account.address],
  })) as bigint;
  if (balance < amount) {
    throw new Error(
      `Relayer mUSDC balance ${balance} < credit amount ${amount}. ` +
        `Mint more to ${account.address} via MockUSDC.ownerMint.`,
    );
  }

  await ensureAllowance(amount);

  const txHash = await walletClient.writeContract({
    address: BODASAVINGS_ADDRESS!,
    abi: bodaSavingsAbi,
    functionName: "creditDeposit",
    args: [rider, amount],
    chain: baseSepolia,
    account,
  });

  const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
  if (receipt.status !== "success") {
    throw new Error(`creditDeposit tx ${txHash} reverted on-chain`);
  }

  return { txHash, relayer: account.address };
}