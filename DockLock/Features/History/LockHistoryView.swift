import SwiftUI

struct LockHistoryView: View {
    @ObservedObject private var history = LockHistoryStore.shared
    @State private var showingClearConfirm = false
    @State private var selectedPhoto: URL?

    var body: some View {
        Group {
            if history.events.isEmpty {
                emptyState
            } else {
                eventList
            }
        }
        .navigationTitle("History")
        .sheet(item: $selectedPhoto) { url in
            PhotoDetailSheet(photoURL: url)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No events yet")
                .font(.headline)
            Text("Lock events from Proximity Lock and Panic Mode will appear here.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Event list

    private var eventList: some View {
        List(history.events) { event in
            HStack(spacing: 12) {
                // Icon
                Image(systemName: iconName(for: event.trigger))
                    .font(.system(size: 14))
                    .foregroundColor(iconColor(for: event.trigger))
                    .frame(width: 24)

                // Label + relative time
                VStack(alignment: .leading, spacing: 2) {
                    Text(label(for: event.trigger))
                        .font(.body)
                    Text(event.date, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Intruder photo thumbnail
                if let url = history.photoURL(for: event) {
                    photoThumbnail(url: url)
                }

                // Formatted date
                Text(event.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 2)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Clear") { showingClearConfirm = true }
                    .foregroundColor(.red)
            }
        }
        .confirmationDialog("Clear all history?", isPresented: $showingClearConfirm) {
            Button("Clear All", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func photoThumbnail(url: URL) -> some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.4), lineWidth: 1))
                .onTapGesture { selectedPhoto = url }
                .help("Tap to view captured photo")
        }
    }

    // MARK: - Helpers

    private func iconName(for trigger: LockTriggerType) -> String {
        switch trigger {
        case .proximity:       return "antenna.radiowaves.left.and.right"
        case .panic:           return "eye.slash"
        case .intruderCapture: return "person.fill.questionmark"
        }
    }

    private func iconColor(for trigger: LockTriggerType) -> Color {
        switch trigger {
        case .proximity:       return .blue
        case .panic:           return .red
        case .intruderCapture: return .orange
        }
    }

    private func label(for trigger: LockTriggerType) -> String {
        switch trigger {
        case .proximity:       return "Proximity Lock"
        case .panic:           return "Panic Mode"
        case .intruderCapture: return "Failed Unlock Attempt"
        }
    }
}

// MARK: - Photo detail sheet

private struct PhotoDetailSheet: View {
    let photoURL: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Intruder Capture")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            if let image = NSImage(contentsOf: photoURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                Text("Photo unavailable")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 480, height: 400)
    }
}

// MARK: - URL: Identifiable for .sheet(item:)

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
