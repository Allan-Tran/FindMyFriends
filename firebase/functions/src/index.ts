import {initializeApp} from "firebase-admin/app";
import {
  getFirestore,
  FieldValue,
  Timestamp,
  DocumentReference,
} from "firebase-admin/firestore";
import {getMessaging} from "firebase-admin/messaging";
import {onDocumentCreated, onDocumentWritten} from "firebase-functions/v2/firestore";
import {onSchedule} from "firebase-functions/v2/scheduler";
import {logger} from "firebase-functions/v2";

initializeApp();

const db = getFirestore();
const messaging = getMessaging();

/**
 * When a DM relay message is written to dms/{dmId}/relay/{messageId},
 * send a silent background push to the other participant.
 */
export const onDMRelayCreated = onDocumentCreated(
  "dms/{dmId}/relay/{messageId}",
  async (event) => {
    const {dmId, messageId} = event.params;
    const data = event.data?.data();
    if (!data) return;

    const senderUid: string = data.senderUid;

    const dmDoc = await db.doc(`dms/${dmId}`).get();
    const dmData = dmDoc.data();
    if (!dmData) return;

    const recipientUid: string =
      dmData.senderUid === senderUid ? dmData.recipientUid : dmData.senderUid;

    const senderUsername: string =
      dmData.senderUid === senderUid
        ? dmData.senderUsername
        : dmData.recipientUsername;

    const userDoc = await db.doc(`users/${recipientUid}`).get();
    const fcmToken = userDoc.data()?.fcmToken as string | undefined;
    if (!fcmToken) return;

    try {
      await messaging.send({
        token: fcmToken,
        data: {dmId, messageId, kind: "dm-relay"},
        notification: {
          title: senderUsername,
          body: "New message",
        },
        apns: {
          headers: {"apns-priority": "10", "apns-push-type": "alert"},
            payload: {
                        aps: {
                          "content-available": 1,
                          sound: "default",
                        },
          },
        },
        android: {priority: "high"},
      });
    } catch (e) {
      logger.warn("FCM DM relay send failed", {recipientUid, error: e});
    }
  }
);

/**
 * When a relay message is created in groups/{groupId}/relay/{messageId},
 * read fcmToken from each member document (already fetched) instead of
 * making a separate read per user — eliminates N extra document reads.
 */
export const onRelayMessageCreated = onDocumentCreated(
  "groups/{groupId}/relay/{messageId}",
  async (event) => {
    const {groupId, messageId} = event.params;
    const data = event.data?.data();
    if (!data) {
      logger.warn("Relay event with no data", {groupId, messageId});
      return;
    }

    const senderUid: string = data.senderUid;

    // Fetch members + group name in parallel. fcmToken is now stored on
    // each member document, so no additional user-doc reads are needed.
    const [membersSnap, groupDoc] = await Promise.all([
      db.collection(`groups/${groupId}/members`).get(),
      db.doc(`groups/${groupId}`).get(),
    ]);

    const groupName: string = groupDoc.data()?.name ?? "Group";

    // Extract sender username from their member doc (already in the snap).
    const senderMemberData = membersSnap.docs.find((d) => d.id === senderUid)?.data();
    const senderUsername: string = senderMemberData?.username ?? "Someone";

    const tokens: string[] = [];
    const tokenToDocRef = new Map<string, DocumentReference>();

    for (const doc of membersSnap.docs) {
      if (doc.id === senderUid) continue;
      const token = doc.data()?.fcmToken as string | undefined;
      if (typeof token === "string" && token.length > 0) {
        tokens.push(token);
        tokenToDocRef.set(token, doc.ref);
      }
    }

    if (tokens.length === 0) return;

    const response = await messaging.sendEachForMulticast({
      tokens,
      data: {groupId, messageId, kind: "relay"},
      notification: {
        title: groupName,
        body: `New message from ${senderUsername}`,
      },
      apns: {
        headers: {
          "apns-priority": "10",
          "apns-push-type": "alert",
        },
        payload: {
          aps: {
            "content-available": 1,
            alert: {
              title: groupName,
              body: `New message from ${senderUsername}`,
            },
            sound: "default",
          },
        },
      },
      android: {priority: "high"},
    });

    // Remove stale tokens from member docs directly.
    const staleDeletes: Promise<unknown>[] = [];
    response.responses.forEach((r, i) => {
      if (r.success) return;
      const code = r.error?.code ?? "";
      if (
        code === "messaging/registration-token-not-registered" ||
        code === "messaging/invalid-registration-token"
      ) {
        const ref = tokenToDocRef.get(tokens[i]);
        if (ref) {
          staleDeletes.push(
            ref.update({fcmToken: FieldValue.delete()}).catch(() => undefined)
          );
        }
      } else {
        logger.warn("FCM send failed", {token: tokens[i], code});
      }
    });
    if (staleDeletes.length > 0) await Promise.all(staleDeletes);
  }
);

/**
 * When a user's FCM token changes, propagate it to every group member doc
 * so onRelayMessageCreated can read tokens without extra user-doc reads.
 */
export const onUserFcmTokenWritten = onDocumentWritten(
  "users/{uid}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (before?.fcmToken === after?.fcmToken) return;

    const uid = event.params.uid;
    const newToken: string | null = (after?.fcmToken as string | undefined) ?? null;

    // Find all member docs for this user via a collection-group query.
    // Member docs have a "uid" field added when the user joins.
    const memberSnaps = await db
      .collectionGroup("members")
      .where("uid", "==", uid)
      .get();

    if (memberSnaps.empty) return;

    const updates = memberSnaps.docs.map((doc) =>
      newToken
        ? doc.ref.update({fcmToken: newToken}).catch(() => undefined)
        : doc.ref.update({fcmToken: FieldValue.delete()}).catch(() => undefined)
    );
    await Promise.all(updates);
  }
);

/**
 * Daily cleanup of expired relay messages. Enforces the expiresAt TTL
 * that is written on every relay document at creation time.
 */
export const pruneExpiredRelayMessages = onSchedule(
  {schedule: "every 24 hours", timeoutSeconds: 540},
  async () => {
    const now = Timestamp.now();
    let deletedTotal = 0;

    // Group relay messages
    const groupsSnap = await db.collection("groups").select().get();
    for (const group of groupsSnap.docs) {
      const expired = await db
        .collection(`groups/${group.id}/relay`)
        .where("expiresAt", "<", now)
        .select()  // fetch only doc refs, no field data
        .get();
      if (expired.empty) continue;

      // Commit in batches of 500 (Firestore limit).
      const chunks = chunkArray(expired.docs, 500);
      for (const chunk of chunks) {
        const batch = db.batch();
        for (const doc of chunk) batch.delete(doc.ref);
        await batch.commit();
      }
      deletedTotal += expired.size;
    }

    // DM relay messages
    const dmsSnap = await db.collection("dms").select().get();
    for (const dm of dmsSnap.docs) {
      const expired = await db
        .collection(`dms/${dm.id}/relay`)
        .where("expiresAt", "<", now)
        .select()
        .get();
      if (expired.empty) continue;

      const chunks = chunkArray(expired.docs, 500);
      for (const chunk of chunks) {
        const batch = db.batch();
        for (const doc of chunk) batch.delete(doc.ref);
        await batch.commit();
      }
      deletedTotal += expired.size;
    }

    logger.info(`pruneExpiredRelayMessages: deleted ${deletedTotal} expired relay docs`);
  }
);

function chunkArray<T>(arr: T[], size: number): T[][] {
  const chunks: T[][] = [];
  for (let i = 0; i < arr.length; i += size) {
    chunks.push(arr.slice(i, i + size));
  }
  return chunks;
}
