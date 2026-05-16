import Foundation
@preconcurrency import FirebaseFirestore

struct ReportService: Sendable {
    let db: Firestore

    init(db: Firestore = .firestore()) { self.db = db }

    func reportPin(
        groupId: String,
        pinId: String,
        pinOwnerUid: String,
        reporterUid: String,
        reason: String
    ) async throws {
        let data: [String: Any] = [
            "type": "pin",
            "groupId": groupId,
            "targetId": pinId,
            "targetOwnerUid": pinOwnerUid,
            "reporterUid": reporterUid,
            "reason": reason,
            "status": ReportStatus.pending.rawValue,
            "createdAt": Timestamp(date: Date())
        ]
        try await db.collection("groups").document(groupId)
            .collection("reports").document().setData(data)
    }

    func reportMapImage(groupId: String, reporterUid: String, reason: String) async throws {
        let data: [String: Any] = [
            "type": "mapImage",
            "groupId": groupId,
            "targetId": groupId,
            "targetOwnerUid": "",
            "reporterUid": reporterUid,
            "reason": reason,
            "status": ReportStatus.pending.rawValue,
            "createdAt": Timestamp(date: Date())
        ]
        try await db.collection("groups").document(groupId)
            .collection("reports").document().setData(data)
    }

    func pendingReports(for groupId: String) async throws -> [FirestoreReport] {
        let snap = try await db.collection("groups").document(groupId)
            .collection("reports")
            .whereField("status", isEqualTo: ReportStatus.pending.rawValue)
            .order(by: "createdAt", descending: true)
            .limit(to: 50)
            .getDocuments()
        return snap.documents.compactMap { try? $0.data(as: FirestoreReport.self) }
    }

    func markReviewed(groupId: String, reportId: String) async throws {
        try await db.collection("groups").document(groupId)
            .collection("reports").document(reportId)
            .updateData(["status": ReportStatus.reviewed.rawValue])
    }

    func markRemoved(groupId: String, reportId: String) async throws {
        try await db.collection("groups").document(groupId)
            .collection("reports").document(reportId)
            .updateData(["status": ReportStatus.removed.rawValue])
    }
}
