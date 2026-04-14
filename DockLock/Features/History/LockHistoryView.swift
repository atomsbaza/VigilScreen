import SwiftUI

struct LockHistoryView: View {
    @ObservedObject private var history = LockHistoryStore.shared
    @State private var showingClearConfirm = false

    var body: some View {
        Group {
            if history.events.isEmpty {
                emptyState
            } else {
                eventList
            }
        }
        .navigationTitle("History")
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
                Image(systemName: event.trigger == .proximity ? "antenna.radiowaves.left.and.right" : "eye.slash")
                    .font(.system(size: 14))
                    .foregroundColor(event.trigger == .proximity ? .blue : .red)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.trigger == .proximity ? "Proximity Lock" : "Panic Mode")
                        .font(.body)
                    Text(event.date, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(event.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 2)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Clear") {
                    showingClearConfirm = true
                }
                .foregroundColor(.red)
            }
        }
        .confirmationDialog("Clear all history?", isPresented: $showingClearConfirm) {
            Button("Clear All", role: .destructive) {
                history.clear()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
