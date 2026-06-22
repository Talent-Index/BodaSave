// packages/nextjs/app/api/intasend/webhook/route.ts
//
// Server-only Route Handler. Receives IntaSend's webhook POST when a Collection
// event (M-Pesa STK push completion/failure) fires, and — on a COMPLETE payment —
// credits the rider on-chain via BodaBodaSavings.creditDeposit().
//
// SECURITY MODEL (per IntaSend's "Manage Webhook" dashboard, not classic HMAC):
// IntaSend includes a `challenge` field in the JSON body of every webhook delivery,
// matching the static secret you configured when you registered this endpoint. This
// is NOT a signature over the payload — it's a shared-secret string comparison. Reject
// anything where it doesn't match BEFORE trusting any other field in the body.
//
// PROCESSING PIPELINE (only after challenge passes + state === COMPLETE):
//   1. Parse rider address from api_ref.
//   2. Convert KES `value` -> mUSDC amount at a placeholder test rate.
//   3. claimInvoice(invoice_id) — idempotency gate. If already claimed, stop.
//   4. creditDepositOnChain(rider, amount) — relayer sends the on-chain tx.
//   5. markCredited / releaseFailedInvoice depending on outcome.
//
// IMPORTANT: the contract does NOT dedupe (creditDeposit double-credits if called
// twice). The ledger claim in step 3 is what makes the whole rail idempotent against
// IntaSend's at-least-once webhook delivery.

import { NextRequest, NextResponse } from "next/server";
import { getAddress, type Address } from "viem";
import { claimInvoice, markCredited, releaseFailedInvoice } from "../_lib/ledger";
import { creditDepositOnChain } from "../_lib/chain";

// Mirrors the api_ref format minted in app/api/intasend/stk-push/route.ts:
//   bodasave:{riderAddressLowercase}:{timestampMs}
const API_REF_RE = /^bodasave:(0x[a-f0-9]{40}):(\d+)$/;

// Placeholder FX rate for TESTNET ONLY. Real pricing needs a rate-lock at quote time
// (the rate shown to the rider when they initiated the STK push), not a constant here.
// Flagged so this constant is impossible to mistake for production logic.
const TEST_KES_PER_USDC = Number(process.env.TEST_KES_PER_USDC ?? "130");
const USDC_DECIMALS = 6;

/** KES (string, may be decimal) -> mUSDC base units (bigint, 6-decimal). */
function kesToUsdcUnits(kesValue: string): bigint {
  const kes = Number(kesValue);
  if (!Number.isFinite(kes) || kes <= 0) {
    throw new Error(`Unparseable KES value from webhook: ${JSON.stringify(kesValue)}`);
  }
  const usdc = kes / TEST_KES_PER_USDC;
  // Convert to 6-decimal base units. Round to nearest unit; floor would systematically
  // under-credit. For a prototype, nearest is fine; production should define rounding
  // policy explicitly alongside the rate-lock.
  return BigInt(Math.round(usdc * 10 ** USDC_DECIMALS));
}

export async function POST(req: NextRequest) {
  let body: Record<string, any>;
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
  }

  // -- Challenge check — the ONLY thing standing between this endpoint and a
  //    forged "payment completed" event. Do not move below any other logic. --
  const expectedChallenge = process.env.INTASEND_WEBHOOK_CHALLENGE;
  if (!expectedChallenge) {
    console.error("INTASEND_WEBHOOK_CHALLENGE is not set in packages/nextjs/.env.local");
    return NextResponse.json({ error: "Webhook not configured" }, { status: 500 });
  }
  if (body.challenge !== expectedChallenge) {
    console.warn("Webhook challenge mismatch — rejecting. Got:", body.challenge);
    return NextResponse.json({ error: "Invalid challenge" }, { status: 401 });
  }

  // -- From here on, body is trusted (challenge matched) --
  // IMPORTANT: IntaSend's payload is FLAT — fields are top-level, NOT nested under an
  // `invoice` key. (Confirmed by logging the raw body during live sandbox testing.)
  const state: string | undefined = body.state;
  const apiRef: string | undefined = body.api_ref;
  const value: string | undefined = body.value; // KES amount, as a string
  const invoiceId: string | undefined = body.invoice_id;

  console.log("IntaSend webhook received:", { state, apiRef, value, invoiceId });

  if (!apiRef) {
    console.warn("Webhook missing api_ref — cannot correlate to a rider. Ignoring.");
    return NextResponse.json({ received: true, note: "no api_ref, ignored" });
  }

  const match = API_REF_RE.exec(apiRef);
  if (!match) {
    console.warn("api_ref not in bodasave:<address>:<timestamp> format:", apiRef);
    return NextResponse.json({ received: true, note: "unrecognized api_ref, ignored" });
  }
  // Checksum the address; getAddress throws on a malformed value (defensive — api_ref
  // is attacker-shaped data even post-challenge, since challenge only proves it's from
  // IntaSend, not that the embedded address is well-formed).
  let rider: Address;
  try {
    rider = getAddress(match[1]);
  } catch {
    console.warn("api_ref contained a malformed address:", match[1]);
    return NextResponse.json({ received: true, note: "bad rider address, ignored" });
  }

  if (state !== "COMPLETE") {
    // PENDING / PROCESSING / FAILED — nothing to credit. Still 200 so IntaSend doesn't
    // retry forever; we act only on the terminal COMPLETE state.
    console.log(`Payment ${apiRef} in state ${state}, not crediting.`);
    return NextResponse.json({ received: true, state });
  }

  if (!invoiceId) {
    // Without an invoice_id we have no idempotency key — refuse rather than risk a
    // double-credit on retry.
    console.error("COMPLETE webhook missing invoice_id — cannot guarantee idempotency. Refusing.");
    return NextResponse.json({ error: "missing invoice_id" }, { status: 400 });
  }

  // -- Convert KES -> mUSDC (placeholder rate) --
  let usdcAmount: bigint;
  try {
    usdcAmount = kesToUsdcUnits(value ?? "");
  } catch (err: any) {
    console.error("FX conversion failed:", err?.message);
    return NextResponse.json({ error: "bad value" }, { status: 400 });
  }

  // -- Idempotency gate: claim the invoice. Only the first caller proceeds. --
  const claim = await claimInvoice(invoiceId, { riderAddress: rider, kesValue: value });
  if (!claim.claimed) {
    console.log(
      `Invoice ${invoiceId} already ${claim.existing.status} (tx ${claim.existing.txHash ?? "n/a"}). Skipping.`,
    );
    // Acknowledge so IntaSend stops retrying; this is the correct, idempotent response.
    return NextResponse.json({
      received: true,
      idempotent: true,
      status: claim.existing.status,
      txHash: claim.existing.txHash ?? null,
    });
  }

  // -- We own this invoice now. Credit on-chain. --
  try {
    const { txHash } = await creditDepositOnChain(rider, usdcAmount);
    await markCredited(invoiceId, { usdcAmount: usdcAmount.toString(), txHash });
    console.log(`Credited ${usdcAmount} mUSDC units to ${rider} — tx ${txHash}`);
    return NextResponse.json({
      received: true,
      credited: true,
      rider,
      usdcAmount: usdcAmount.toString(),
      txHash,
    });
  } catch (err: any) {
    // Release the claim so a later IntaSend retry can attempt again, rather than
    // leaving the rider permanently uncredited because the first attempt hit a
    // transient RPC/gas error.
    await releaseFailedInvoice(invoiceId, err?.message ?? String(err));
    console.error(`creditDeposit failed for invoice ${invoiceId}:`, err?.message ?? err);
    // 500 so IntaSend retries the delivery (it treats non-2xx as "retry later").
    return NextResponse.json({ error: "on-chain credit failed", detail: err?.message ?? null }, { status: 500 });
  }
}