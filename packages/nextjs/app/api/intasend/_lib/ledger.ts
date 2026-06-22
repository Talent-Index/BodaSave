// packages/nextjs/app/api/intasend/_lib/ledger.ts
//
// Idempotency ledger for IntaSend → on-chain credit.
//
// WHY THIS EXISTS
// ───────────────
// BodaBodaSavings.creditDeposit() intentionally enforces NO on-chain idempotency
// (see the contract's [V4.1-1] notes and the testCreditDepositCalledTwiceDoubleCredits
// test). Calling it twice for the same M-Pesa payment WILL double-credit the rider.
// IntaSend, like most webhook providers, may deliver the same event more than once
// (retries, at-least-once delivery). Therefore the backend MUST be the thing that
// guarantees "one completed invoice → at most one creditDeposit". This module is that
// guarantee.
//
// PROTOTYPE STORAGE — READ THIS BEFORE SHIPPING
// ─────────────────────────────────────────────
// This implementation is a flat JSON file on local disk. That is fine for in-house
// testnet testing on a single long-lived dev server. It is NOT safe for:
//   • Serverless / multi-instance deploys (each instance has its own disk; two
//     instances handling two retries of the same webhook could both see "not yet
//     processed" and both credit — the file is not a shared lock).
//   • Concurrent requests within one instance (we mitigate with a tiny in-process
//     mutex below, but that does not cross instances).
// Before this leaves testnet, replace the storage backend with something atomic and
// shared: a Postgres row with a UNIQUE constraint on invoice_id, a Redis SETNX, etc.
// The PUBLIC API of this module (claim / complete / fail / get) is designed so that
// swap touches only this file.

import { promises as fs } from "fs";
import path from "path";

export type LedgerStatus = "processing" | "credited" | "failed";

export interface LedgerEntry {
  invoiceId: string;
  status: LedgerStatus;
  riderAddress?: string;
  kesValue?: string;
  usdcAmount?: string; // stringified bigint (6-decimal units)
  txHash?: string;
  error?: string;
  createdAt: string;
  updatedAt: string;
}

type LedgerFile = Record<string, LedgerEntry>;

// Resolve to packages/nextjs/.intasend-ledger.json regardless of where Next runs from.
const LEDGER_PATH = path.join(process.cwd(), ".intasend-ledger.json");

// In-process serialization. Ensures that within a SINGLE Node instance, two webhook
// deliveries for the same invoice can't interleave their read-modify-write of the file.
// Does NOT protect across instances — see the storage note above.
let writeChain: Promise<void> = Promise.resolve();

async function readLedger(): Promise<LedgerFile> {
  try {
    const raw = await fs.readFile(LEDGER_PATH, "utf8");
    return JSON.parse(raw) as LedgerFile;
  } catch (err: any) {
    if (err?.code === "ENOENT") return {}; // first run, no file yet
    throw err;
  }
}

async function writeLedger(data: LedgerFile): Promise<void> {
  const tmp = `${LEDGER_PATH}.tmp`;
  await fs.writeFile(tmp, JSON.stringify(data, null, 2), "utf8");
  await fs.rename(tmp, LEDGER_PATH); // atomic-ish replace on POSIX
}

/** Serialize a read-modify-write against the ledger file within this process. */
async function withLock<T>(fn: (data: LedgerFile) => Promise<T> | T): Promise<T> {
  const run = async () => {
    const data = await readLedger();
    const result = await fn(data);
    return result;
  };
  const next = writeChain.then(run, run);
  // keep the chain alive but swallow errors so one failure doesn't wedge the chain
  writeChain = next.then(
    () => undefined,
    () => undefined,
  );
  return next;
}

export async function getEntry(invoiceId: string): Promise<LedgerEntry | undefined> {
  const data = await readLedger();
  return data[invoiceId];
}

/**
 * Attempt to claim an invoice for processing.
 * Returns { claimed: true } if THIS call is the one that should proceed to credit.
 * Returns { claimed: false, existing } if the invoice was already claimed/credited/failed,
 * in which case the caller must NOT credit again.
 *
 * This is the idempotency gate. The claim + write happen under the in-process lock so
 * two concurrent deliveries can't both claim.
 */
export async function claimInvoice(
  invoiceId: string,
  meta: { riderAddress: string; kesValue?: string },
): Promise<{ claimed: true } | { claimed: false; existing: LedgerEntry }> {
  return withLock(async (data) => {
    const existing = data[invoiceId];
    if (existing) {
      return { claimed: false as const, existing };
    }
    const now = new Date().toISOString();
    data[invoiceId] = {
      invoiceId,
      status: "processing",
      riderAddress: meta.riderAddress,
      kesValue: meta.kesValue,
      createdAt: now,
      updatedAt: now,
    };
    await writeLedger(data);
    return { claimed: true as const };
  });
}

export async function markCredited(
  invoiceId: string,
  fields: { usdcAmount: string; txHash: string },
): Promise<void> {
  await withLock(async (data) => {
    const entry = data[invoiceId];
    if (!entry) return;
    entry.status = "credited";
    entry.usdcAmount = fields.usdcAmount;
    entry.txHash = fields.txHash;
    entry.updatedAt = new Date().toISOString();
    await writeLedger(data);
  });
}

/**
 * Mark a claimed invoice as failed, so a later retry CAN attempt it again.
 * We delete the entry rather than leaving it "failed" so that IntaSend's next retry
 * re-claims cleanly. (If you'd rather require manual review of failures, change this
 * to set status="failed" and have claimInvoice treat "failed" as already-claimed.)
 */
export async function releaseFailedInvoice(invoiceId: string, error: string): Promise<void> {
  await withLock(async (data) => {
    const entry = data[invoiceId];
    if (!entry) return;
    // Log the failure reason before clearing, for debugging during testnet.
    console.warn(`Ledger: releasing failed invoice ${invoiceId} for retry. Reason: ${error}`);
    delete data[invoiceId];
    await writeLedger(data);
  });
}