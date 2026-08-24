// functions/src/index.ts
import { onRequest, Request } from "firebase-functions/v2/https";
import type { Response } from "express";
import { defineSecret } from "firebase-functions/params";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import * as crypto from "crypto";
import fetch from "node-fetch";

// 🔧 Admin SDK v12+ (modular)
import { initializeApp } from "firebase-admin/app";
import {
  getFirestore,
  FieldValue,
  Timestamp,
} from "firebase-admin/firestore";
import {
  getMessaging,
  MulticastMessage,
} from "firebase-admin/messaging";

// Initialize Admin (modular)
initializeApp();
const db = getFirestore();

// ───────────────────────────────────────────────────────────
// Secrets / Config
// ───────────────────────────────────────────────────────────
const PAYSTACK_SECRET_KEY = defineSecret("PAYSTACK_SECRET_KEY"); // sk_live_xxx or sk_test_xxx
const ORIGIN = process.env.ALLOWED_ORIGIN ?? "*"; // lock this down later

// CORS/JSON helpers
function ok(res: Response, data: unknown, status = 200): void {
  res.set("Access-Control-Allow-Origin", ORIGIN);
  res.set("Access-Control-Allow-Headers", "Content-Type,Authorization");
  res.set("Access-Control-Allow-Methods", "POST,OPTIONS");
  if (res.req.method === "OPTIONS") {
    res.status(204).send("");
    return;
  }
  res.status(status).json(data);
}
function fail(res: Response, message: string, status = 400): void {
  ok(res, { ok: false, error: message }, status);
}

// ───────────────────────────────────────────────────────────
// Types
// ───────────────────────────────────────────────────────────
type InitPayload = {
  email: string;
  amount: number; // GHS amount (e.g., 120.50)
  currency?: "GHS" | "NGN" | "USD";
  metadata?: Record<string, unknown>;
  reference?: string; // optional client-generated
};

type VerifyPayload = {
  reference: string;
  deliveryDraft?: Record<string, unknown>; // create on success
  deliveryId?: string; // or update existing
};

type PaystackVerifyData = {
  status?: string; // "success"
  amount?: number; // minor units (pesewas/kobo)
  currency?: string; // "GHS"
  reference?: string;
  metadata?: Record<string, unknown>;
  [k: string]: unknown;
};

type PaystackVerifyResponse = {
  status?: boolean;
  message?: string;
  data?: PaystackVerifyData;
};

// Local/prod secret getter
function getPaystackSecret(): string {
  try {
    const v = PAYSTACK_SECRET_KEY.value();
    if (v) return v;
  } catch (_) {
    // ignore
  }
  const env = process.env.PAYSTACK_SECRET_KEY;
  if (!env) throw new Error("PAYSTACK_SECRET_KEY not set");
  return env;
}

// ───────────────────────────────────────────────────────────
// Paystack HTTP helpers
// ───────────────────────────────────────────────────────────
async function psInit(secret: string, p: InitPayload) {
  const amountInMinor = Math.round(p.amount * 100); // pesewas/kobo
  const resp = await fetch("https://api.paystack.co/transaction/initialize", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${secret}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      email: p.email,
      amount: amountInMinor,
      currency: p.currency ?? "GHS",
      reference: p.reference,
      metadata: p.metadata ?? {},
    }),
  });
  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`Paystack init failed: ${resp.status} ${text}`);
  }
  return await resp.json();
}

async function psVerify(
  secret: string,
  reference: string,
): Promise<PaystackVerifyResponse> {
  const resp = await fetch(
    `https://api.paystack.co/transaction/verify/${reference}`,
    {
      method: "GET",
      headers: {
        Authorization: `Bearer ${secret}`,
        "Content-Type": "application/json",
      },
    },
  );
  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`Paystack verify failed: ${resp.status} ${text}`);
  }
  return (await resp.json()) as PaystackVerifyResponse;
}

// ───────────────────────────────────────────────────────────
// Firestore helpers (modular)
// ───────────────────────────────────────────────────────────
async function createDelivery(draft: Record<string, unknown>) {
  const insert = {
    ...draft,
    paid: true,
    status: draft["status"] ?? "pending",
    created_at: FieldValue.serverTimestamp(),
    paystack: {
      verified_at: Timestamp.now(),
    },
  };
  const ref = await db.collection("deliveries").add(insert);
  return { id: ref.id, ...insert };
}

async function markDeliveryPaid(id: string, psData: unknown) {
  await db
    .collection("deliveries")
    .doc(id)
    .set(
      {
        paid: true,
        status: "pending",
        paystack: {
          verified_at: FieldValue.serverTimestamp(),
          data: psData,
        },
      },
      { merge: true },
    );
}

// ───────────────────────────────────────────────────────────
// 1) Initialize transaction
// ───────────────────────────────────────────────────────────
export const initPaystack = onRequest(
  { region: "us-central1", cors: true, secrets: [PAYSTACK_SECRET_KEY] },
  async (req: Request, res: Response): Promise<void> => {
    if (req.method === "OPTIONS") {
      ok(res, {});
      return;
    }
    if (req.method !== "POST") {
      fail(res, "Use POST", 405);
      return;
    }

    try {
      const secret = getPaystackSecret();
      const payload: InitPayload = (req.body ?? {}) as InitPayload;
      if (!payload.email || typeof payload.amount !== "number") {
        fail(res, "email and amount are required");
        return;
      }
      if (payload.amount <= 0) {
        fail(res, "amount must be > 0");
        return;
      }

      const data = await psInit(secret, payload);
      ok(res, { ok: true, data });
    } catch (e: any) {
      console.error("[initPaystack] ERROR", e);
      fail(res, e?.message ?? "init failed", 500);
    }
  },
);

// ───────────────────────────────────────────────────────────
// 2) Verify reference and write Firestore
// ───────────────────────────────────────────────────────────
export const verifyPaystack = onRequest(
  { region: "us-central1", cors: true, secrets: [PAYSTACK_SECRET_KEY] },
  async (req: Request, res: Response): Promise<void> => {
    if (req.method === "OPTIONS") {
      ok(res, {});
      return;
    }
    if (req.method !== "POST") {
      fail(res, "Use POST", 405);
      return;
    }

    try {
      const secret = getPaystackSecret();
      const { reference, deliveryDraft, deliveryId } =
        (req.body ?? {}) as VerifyPayload;

      if (!reference) {
        fail(res, "reference is required");
        return;
      }

      const verifyResp = await psVerify(secret, reference);
      const status: string | undefined = verifyResp?.data?.status;
      const amountMinor: number | undefined = verifyResp?.data?.amount;
      const currency: string | undefined = verifyResp?.data?.currency;

      if (status !== "success") {
        fail(res, `verification not successful (status=${status})`, 400);
        return;
      }

      console.log("[verifyPaystack] OK", {
        reference,
        amountMinor,
        currency,
      });

      let doc: any = null;
      if (deliveryId) {
        await markDeliveryPaid(deliveryId, verifyResp);
        const snap = await db.collection("deliveries").doc(deliveryId).get();
        doc = { id: snap.id, ...snap.data() };
      } else if (deliveryDraft) {
        doc = await createDelivery({
          ...deliveryDraft,
          price:
            (deliveryDraft["price"] as number | undefined) ??
            Math.round((amountMinor ?? 0) / 100),
          paid: true,
          paystack_ref: reference,
        });
      }

      ok(res, { ok: true, reference, delivery: doc, verify: verifyResp });
    } catch (e: any) {
      console.error("[verifyPaystack] ERROR", e);
      fail(res, e?.message ?? "verify failed", 500);
    }
  },
);

// ───────────────────────────────────────────────────────────
// 3) Webhook (signature must use req.rawBody)
// ───────────────────────────────────────────────────────────
export const paystackWebhook = onRequest(
  { region: "us-central1", cors: true, secrets: [PAYSTACK_SECRET_KEY] },
  async (req: Request, res: Response): Promise<void> => {
    if (req.method === "OPTIONS") {
      ok(res, {});
      return;
    }
    if (req.method !== "POST") {
      fail(res, "Use POST", 405);
      return;
    }

    const secret = getPaystackSecret();

    const signature = req.header("x-paystack-signature");
    const expected = crypto
      .createHmac("sha512", secret)
      .update(req.rawBody) // raw buffer is required
      .digest("hex");

    if (!signature || signature !== expected) {
      console.warn("[paystackWebhook] bad signature");
      fail(res, "invalid signature", 401);
      return;
    }

    const event = (req.body as any)?.event;
    const data = (req.body as any)?.data;
    console.log("[paystackWebhook] event", event);

    try {
      if (event === "charge.success") {
        const reference: string | undefined = data?.reference;
        const deliveryId: string | undefined = data?.metadata?.deliveryId;
        const draft: Record<string, unknown> | undefined =
          data?.metadata?.deliveryDraft;

        if (deliveryId) {
          await markDeliveryPaid(deliveryId, data);
        } else if (draft) {
          await createDelivery({
            ...draft,
            price:
              (draft["price"] as number | undefined) ??
              Math.round((data?.amount ?? 0) / 100),
            paid: true,
            paystack_ref: reference,
          });
        }
      }

      ok(res, { ok: true });
    } catch (e: any) {
      console.error("[paystackWebhook] ERROR", e);
      fail(res, e?.message ?? "webhook error", 500);
    }
  },
);

// ───────────────────────────────────────────────────────────
// Firestore trigger (modular messaging)
// ───────────────────────────────────────────────────────────
export const sendUserNotification = onDocumentCreated(
  "notifications/{notificationId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;

    const notification = snap.data() as any;
    if (!notification || !notification.userId) return;

    const userId: string = notification.userId;
    const userRef = db.collection("users").doc(userId);
    const userDoc = await userRef.get();
    if (!userDoc.exists) return;

    const fcmTokens: string[] = (userDoc.get("fcmTokens") as string[]) || [];
    if (fcmTokens.length === 0) return;

    const message: MulticastMessage = {
      tokens: fcmTokens,
      notification: {
        title: notification.title || "New Alert",
        body: notification.body || "",
      },
      data: {
        type: notification.type || "general",
      },
    };

    const response = await getMessaging().sendEachForMulticast(message);
    const invalidTokens: string[] = [];
    response.responses.forEach((r, idx) => {
      if (
        !r.success &&
        r.error &&
        (r.error.code === "messaging/invalid-argument" ||
          r.error.code === "messaging/registration-token-not-registered")
      ) {
        invalidTokens.push(fcmTokens[idx]);
      }
    });

    if (invalidTokens.length > 0) {
      await userRef.update({
        fcmTokens: FieldValue.arrayRemove(...invalidTokens),
      });
    }
  },
);
