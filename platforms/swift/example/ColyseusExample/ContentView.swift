
import SwiftUI
import Colyseus

@MainActor
final class GameViewModel: ObservableObject {
    @Published var status: String = "Disconnected"
    @Published var stateLog: [String] = []
    @Published var messages: [String] = []

    private var client: ColyseusClient?
    private var room: ColyseusRoom?

    func connect() {
        status = "Connecting..."
        let settings = ColyseusSettings.localhost(port: "2567")
        client = ColyseusClient(settings: settings)

        Task {
            do {
                let r = try await client!.joinOrCreate("my_room")
                r.enableDynamicSchema()

                r.onJoin = { [weak self] in
                    self?.status = "Joined room: \(r.roomId ?? "?")"
                }
                r.onLeave = { [weak self] code, reason in
                    self?.status = "Left (\(code)): \(reason)"
                }
                r.onError = { [weak self] code, msg in
                    self?.status = "Error \(code): \(msg)"
                }
                r.onStateChange = { [weak self] state in
                    let desc = state.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
                    self?.stateLog.insert(desc, at: 0)
                    if (self?.stateLog.count ?? 0) > 20 { self?.stateLog.removeLast() }
                }
                r.onMessage = { [weak self] type, value in
                    self?.messages.insert("[\(type)] \(value)", at: 0)
                    if (self?.messages.count ?? 0) > 20 { self?.messages.removeLast() }
                }
                room = r
            } catch let e as ColyseusError {
                status = "Failed (\(e.code)): \(e.message)"
            }
        }
    }

    func sendPing() {
        let msg = MessageBuilder.map().set("action", "ping")
        room?.send(type: "test", msg)
    }

    func disconnect() {
        room?.leave()
        room = nil
        client = nil
        status = "Disconnected"
    }
}

struct ContentView: View {
    @StateObject private var vm = GameViewModel()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(vm.status)
                    .font(.headline)
                    .padding(.horizontal)

                HStack {
                    Button("Connect",    action: vm.connect)
                    Button("Ping",       action: vm.sendPing)
                    Button("Disconnect", action: vm.disconnect)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)

                Divider()

                Text("State").font(.subheadline).bold().padding(.horizontal)
                List(vm.stateLog, id: \.self) { Text($0).font(.caption) }
                    .frame(maxHeight: 200)

                Text("Messages").font(.subheadline).bold().padding(.horizontal)
                List(vm.messages, id: \.self) { Text($0).font(.caption) }
            }
            .navigationTitle("Colyseus Example")
        }
    }
}

#Preview {
    ContentView()
}
