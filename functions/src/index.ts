// functions/src/index.ts
import { onDocumentCreated } from "firebase-functions/v2/firestore";

// Admin SDK v12+ (modular)
import { initializeApp } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { getMessaging, MulticastMessage } from "firebase-admin/messaging";

// Initialize Admin (modular)
initializeApp();
const db = getFirestore();

// ───────────────────────────────────────────────────────────
// Firestore Trigger: Push Notifications via FCM
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
