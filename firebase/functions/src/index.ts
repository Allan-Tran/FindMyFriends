import {initializeApp} from "firebase-admin/app";
import {getFirestore, FieldValue} from "firebase-admin/firestore";
import {getMessaging} from "firebase-admin/messaging";
import {onDocumentCreated} from "firebase-functions/v2/firestore";
import {logger} from "firebase-functions/v2";

initializeApp();

const db = getFirestore();
const messaging = getMessaging();

/**
 * When a relay message is created in groups/{groupId}/relay/{messageId},
 * send a silent FCM "background" push to every other group member who has
 * a registered fcmToken. The push carries groupId+messageId so the iOS
 * client can fetch the message from Firestore on wake.
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

    const membersSnap = await db
      .collection(`groups/${groupId}/members`)
      .get();

    const recipientUids = membersSnap.docs
      .map((m) => m.id)
      .filter((uid) => uid !== senderUid);

    if (recipientUids.length === 0) return;

    const userDocs = await db.getAll(
      ...recipientUids.map((uid) => db.doc(`users/${uid}`))
    );
    const tokens = userDocs
      .map((d) => d.data()?.fcmToken as string | undefined)
      .filter((t): t is string => typeof t === "string" && t.length > 0);

    if (tokens.length === 0) return;

    const response = await messaging.sendEachForMulticast({
      tokens,
      data: {
        groupId,
        messageId,
        kind: "relay",
      },
      apns: {
        headers: {
          "apns-priority": "5",
          "apns-push-type": "background",
        },
        payload: {
          aps: {
            "content-available": 1,
          },
        },
      },
      android: {
        priority: "high",
      },
    });

    // Clean up tokens that the FCM server told us are no longer valid.
    const stale: string[] = [];
    response.responses.forEach((r, i) => {
      if (r.success) return;
      const code = r.error?.code ?? "";
      if (
        code === "messaging/registration-token-not-registered" ||
        code === "messaging/invalid-registration-token"
      ) {
        stale.push(tokens[i]);
      } else {
        logger.warn("FCM send failed", {token: tokens[i], code});
      }
    });

    if (stale.length > 0) {
      await Promise.all(
        userDocs
          .filter((d) => stale.includes(d.data()?.fcmToken))
          .map((d) =>
            d.ref.update({fcmToken: FieldValue.delete()}).catch(() => undefined)
          )
      );
    }
  }
);
