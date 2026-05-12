import SwiftUI
import SwiftData

@main
struct MeshMessengerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var session: AuthSession
    @StateObject private var meshEngine: MeshEngine
    @StateObject private var proximityEngine: ProximityEngine
    @StateObject private var syncEngine: SyncEngine
    @StateObject private var router: MessageRouter
    @StateObject private var groupStore: GroupStore
    @StateObject private var pushCenter: PushNotificationCenter

    init() {
        let session = AuthSession()
        _session = StateObject(wrappedValue: session)

        let mesh = MeshEngine()
        _meshEngine = StateObject(wrappedValue: mesh)
        let proximity = ProximityEngine()
        _proximityEngine = StateObject(wrappedValue: proximity)

        let relay = RelayAPI(client: session.apiClient)
        let sync = SyncEngine(relayAPI: relay)
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
        let store = GroupStore(client: session.apiClient, repository: groupRepo)
        store.router = router
        _groupStore = StateObject(wrappedValue: store)

        let push = PushNotificationCenter(client: session.apiClient)
        push.attach(router: router)
        _pushCenter = StateObject(wrappedValue: push)
        AppDelegate.pushCenter = push
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
                .environmentObject(pushCenter)
                .modelContainer(PersistenceController.shared.container)
                .task(id: session.isSignedIn) {
                    if session.isSignedIn {
                        await pushCenter.requestAuthorizationAndRegister()
                    } else {
                        await pushCenter.unregister()
                        router.stop()
                    }
                }
        }
    }
}
