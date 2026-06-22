// packages/nextjs/app/api/intasend/stk-push/route.ts
//
// Server-only Route Handler. Code in this file NEVER reaches the browser bundle —
// Next.js executes app/api/**/route.ts exclusively on the server. This is the one
// place allowed to import the IntaSend SDK and read INTASEND_SECRET_KEY.
//
// Do NOT call IntaSend directly from BodaSavingsApp.tsx or any "use client" component.
// That component should instead `fetch("/api/intasend/stk-push", { method: "POST", ... })`.

import { NextRequest, NextResponse } from "next/server";
// eslint-disable-next-line @typescript-eslint/no-require-imports
const IntaSend = require("intasend-node");

const KE_PHONE_RE = /^254[17]\d{8}$/;

export async function POST(req: NextRequest) {
  let body: {
    amountKes?: number;
    phoneNumber?: string;
    riderAddress?: string;
    firstName?: string;
    lastName?: string;
    email?: string;
  };

  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
  }

  const { amountKes, phoneNumber, riderAddress, firstName, lastName, email } = body;

  if (!amountKes || typeof amountKes !== "number" || amountKes <= 0) {
    return NextResponse.json({ error: "amountKes must be a positive number" }, { status: 400 });
  }
  if (!phoneNumber || !KE_PHONE_RE.test(phoneNumber)) {
    return NextResponse.json(
      { error: "phoneNumber must be a Kenyan MSISDN in 2547XXXXXXXX format" },
      { status: 400 },
    );
  }
  if (!riderAddress || !/^0x[a-fA-F0-9]{40}$/.test(riderAddress)) {
    return NextResponse.json({ error: "riderAddress must be a valid 0x address" }, { status: 400 });
  }

  const publishableKey = process.env.INTASEND_PUBLISHABLE_KEY;
  const secretKey = process.env.INTASEND_SECRET_KEY;
  const testMode = process.env.INTASEND_TEST_MODE !== "false";

  if (!publishableKey || !secretKey) {
    console.error("IntaSend keys are not configured in packages/nextjs/.env.local");
    return NextResponse.json({ error: "Payment provider not configured" }, { status: 500 });
  }

  const intasend = new IntaSend(publishableKey, secretKey, testMode);
  const collection = intasend.collection();

  const apiRef = `bodasave:${riderAddress.toLowerCase()}:${Date.now()}`;

  try {
    const resp = await collection.mpesaStkPush({
      first_name: firstName || "Boda",
      last_name: lastName || "Rider",
      email: email || "rider@bodasave.app",
      host: process.env.NEXT_PUBLIC_APP_URL || "https://bodasave.app",
      amount: amountKes,
      phone_number: phoneNumber,
      api_ref: apiRef,
    });

    return NextResponse.json({
      invoiceId: resp?.invoice?.invoice_id ?? null,
      state: resp?.invoice?.state ?? "PENDING",
      apiRef,
    });
  } catch (err: any) {
    console.error("IntaSend STK push failed:", JSON.stringify(err, Object.getOwnPropertyNames(err)));
    console.error("err.response?.data:", err?.response?.data);
    console.error("err.message:", err?.message);
    return NextResponse.json({ error: "STK push request failed" }, { status: 502 });
  }
}