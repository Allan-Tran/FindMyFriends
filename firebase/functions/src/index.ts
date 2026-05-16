import {initializeApp} from "firebase-admin/app";
import {getFirestore, FieldValue} from "firebase-admin/firestore";
import {getMessaging} from "firebase-admin/messaging";
import {onDocumentCreated} from "firebase-functions/v2/firestore";
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
              alert: {title: senderUsername, body: "New message"},
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

    const [membersSnap, groupDoc, senderDoc] = await Promise.all([
      db.collection(`groups/${groupId}/members`).get(),
      db.doc(`groups/${groupId}`).get(),
      db.doc(`users/${senderUid}`).get(),
    ]);

    const groupName: string = groupDoc.data()?.name ?? "Group";
    const senderUsername: string = senderDoc.data()?.username ?? "Someone";

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
