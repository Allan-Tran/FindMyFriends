import SwiftUI
import SwiftData

@main
struct MeshMessengerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var session: AuthSession
    @StateObject private var meshEngine: MeshEngine
    @StateObject private var proximityEngine: ProximityEngine
    @StateObject private var syncEngine: SyncEngine
    @StateObject private var router: MessageRouter
    @StateObject private var groupStore: GroupStore
    @StateObject private var dmStore: DMStore
    @StateObject private var pushCenter: PushNotificationCenter
    @StateObject private var blockStore: BlockStore

    init() {
        FirebaseManager.configure()

        let session = AuthSession()
        _session = StateObject(wrappedValue: session)

        let mesh = MeshEngine()
        _meshEngine = StateObject(wrappedValue: mesh)

        let proximity = ProximityEngine()
        _proximityEngine = StateObject(wrappedValue: proximity)

        let sync = SyncEngine()
        _syncEngine = StateObject(wrappedValue: sync)

        let context = PersistenceController.shared.mainContext
        let messageRepo = MessageRepository(context: context)
        let peerRepo = KnownPeerRepository(context: context)
        let groupRepo = GroupRepository(context: context)

        let router = MessageRouter(
            session: session,
            meshEngine: mesh,
            proximityEngine: proximity,
            syncEngine: sync,
            messageRepository: messageRepo,
            peerRepository: peerRepo
        )
        _router = StateObject(wrappedValue: router)

        let store = GroupStore(session: session, repository: groupRepo)
        store.router = router
        _groupStore = StateObject(wrappedValue: store)

        let dmStore = DMStore(context: context, router: router, session: session)
        _dmStore = StateObject(wrappedValue: dmStore)

        let push = PushNotificationCenter()
        push.attach(session: session, router: router, dmStore: dmStore)
        _pushCenter = StateObject(wrappedValue: push)
        AppDelegate.pushCenter = push

        _blockStore = StateObject(wrappedValue: BlockStore())

        session.observeAuthState()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .environmentObject(meshEngine)
                .environmentObject(proximityEngine)
                .environmentObject(syncEngine)
                .environmentObject(router)
                .environmentObject(groupStore)
                .environmentObject(dmStore)
                .environmentObject(pushCenter)
                .environmentObject(blockStore)
                .modelContainer(PersistenceController.shared.container)
                .task(id: session.isSignedIn && session.isEmailVerified) {
                    if session.isSignedIn && session.isEmailVerified {
                        await pushCenter.requestAuthorizationAndRegister()
                    } else if !session.isSignedIn {
                        await pushCenter.unregister()
                        router.stop()
                        groupStore.stopObserving()
                        dmStore.stop()
                    }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            try? MessageRepository(context: PersistenceController.shared.mainContext)
                .pruneOldMessages()
        }
    }
}
