import ISurfSelectCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FirmwareUpdateScreen: View {
    @ObservedObject var central: BoatCentral
    @Environment(\.dismiss) private var dismiss
    @AppStorage("firmwareManifestURL") private var manifestURL = ""

    @State private var importing = false
    @State private var confirm = false
    @State private var checking = false
    @State private var installing = false
    @State private var finished = false
    @State private var pending: FirmwareImage?
    @State private var progress = FirmwarePushProgress(phase: .preparing, sent: 0, total: 1)
    @State private var statusMessage = ""
    @State private var installTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        deviceCard
                        if installing {
                            progressCard
                        } else {
                            actionCard
                            serverCard
                        }
                        if !statusMessage.isEmpty {
                            Text(statusMessage)
                                .font(.body)
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Firmware")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .disabled(installing)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.nautique)
        .interactiveDismissDisabled(installing)
        .onAppear { central.refreshFirmware() }
        .onDisappear {
            installTask?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: central.firmwareAvailability) { _, availability in
            guard finished, case .available(let info) = availability else { return }
            statusMessage = "Bridge is back on firmware \(info.version)."
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: firmwareTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    loadFile(url)
                }
            case .failure(let error):
                statusMessage = error.localizedDescription
            }
        }
        .confirmationDialog("Install firmware?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Install and restart") { startInstall() }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(confirmMessage)
        }
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bridge")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.55))
                .tracking(0.8)
            Text(deviceText)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.55))
                .tracking(0.8)
            Text("Firmware 1.0.1 is included in this app. The phone sends it to the bridge over Bluetooth. Stay near the boat until the bridge reconnects.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            Button("Install 1.0.1") { loadBundled() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canInstall)
            Button("Choose a .bin") { importing = true }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!canInstall)
            Button(checking ? "Checking…" : "Check for update") {
                Task { await checkForUpdate() }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!canInstall || checking || manifestURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if pending != nil {
                Button("Install \(pending?.version ?? "firmware")") { confirm = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canInstall)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(phaseText)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            ProgressView(value: progress.fraction)
                .tint(.nautique)
            Text(progressDetail)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
            Button("Cancel") {
                central.cancelFirmwareInstall()
                installTask?.cancel()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Update server")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.55))
                .tracking(0.8)
            TextField("https://example.com/isurfselect.json", text: $manifestURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .font(.body)
                .padding(12)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Leave this empty until firmware is hosted. The manifest points at the .bin. The bridge never joins Wi-Fi.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var canInstall: Bool {
        if case .ready = central.status, case .available = central.firmwareAvailability {
            return true
        }
        return false
    }

    private var deviceText: String {
        switch central.firmwareAvailability {
        case .unknown:
            central.status == .ready ? "Looking for the updater…" : "Not connected."
        case .unsupported:
            "No updater on this bridge yet. Flash the current sketch over USB once, using Default 4MB with spiffs."
        case .available(let info):
            "Running \(info.version) · slot \(info.slot) · \(info.slotSize / 1024) KB"
        }
    }

    private var phaseText: String {
        switch progress.phase {
        case .preparing: "Preparing the bridge"
        case .sending: "Sending firmware"
        case .verifying: "Checking the image"
        case .restarting: "Restarting the bridge"
        }
    }

    private var progressDetail: String {
        let percent = Int((progress.fraction * 100).rounded())
        return "\(percent)% · \(progress.sent) / \(progress.total) bytes"
    }

    private var confirmMessage: String {
        let version = pending?.version ?? "this firmware"
        return "Install \(version)? The bridge restarts and Bluetooth drops for a few seconds. Stay near the boat until it reconnects."
    }

    private var firmwareTypes: [UTType] {
        var types: [UTType] = [.data]
        if let bin = UTType(filenameExtension: "bin") {
            types.insert(bin, at: 0)
        }
        return types
    }

    private func loadBundled() {
        do {
            guard let url = Bundle.main.url(forResource: "isurfselect-1.0.1", withExtension: "bin") else {
                statusMessage = "This app build does not include firmware 1.0.1."
                return
            }
            let data = try Data(contentsOf: url)
            pending = try FirmwareImage(
                version: "1.0.1",
                hardware: .esp32s3,
                bytes: data,
                notes: "Queues commands so fast taps reach the boat."
            )
            statusMessage = "1.0.1 · \(data.count) bytes"
            confirm = true
        } catch {
            pending = nil
            statusMessage = error.localizedDescription
        }
    }

    private func loadFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let scanned = FirmwareVersion(scanning: url.lastPathComponent)?.description
            let version = scanned ?? url.deletingPathExtension().lastPathComponent
            pending = try FirmwareImage(version: version, hardware: .esp32s3, bytes: data)
            statusMessage = "\(version) · \(data.count) bytes"
            confirm = true
        } catch {
            pending = nil
            statusMessage = error.localizedDescription
        }
    }

    private func checkForUpdate() async {
        let trimmed = manifestURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            statusMessage = "Enter the https address of the firmware manifest."
            return
        }
        checking = true
        defer { checking = false }
        do {
            let image = try await FirmwareCatalog.fetch(manifestURL: url)
            if case .available(let device) = central.firmwareAvailability,
               let current = FirmwareVersion(device.version),
               let offer = FirmwareVersion(image.version),
               offer <= current {
                pending = nil
                statusMessage = "The bridge is already running \(device.version)."
                return
            }
            pending = image
            var lines = ["\(image.version) is ready to install."]
            if let notes = image.notes, !notes.isEmpty {
                lines.append(notes)
            }
            statusMessage = lines.joined(separator: "\n")
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func startInstall() {
        guard let pending else { return }
        installing = true
        finished = false
        UIApplication.shared.isIdleTimerDisabled = true
        progress = FirmwarePushProgress(phase: .preparing, sent: 0, total: pending.bytes.count)
        statusMessage = "Keep the phone near the bridge. This takes a minute or two."
        installTask = Task {
            defer {
                installing = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
            do {
                for try await update in central.installFirmware(pending) {
                    progress = update
                }
                finished = true
                statusMessage = "Installed. The bridge is restarting and will reconnect."
            } catch is CancellationError {
                statusMessage = "Update cancelled."
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }
}
