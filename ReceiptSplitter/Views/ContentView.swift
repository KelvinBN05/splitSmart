import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ContentView: View {
    @State private var receipts = DemoData.receipts

    var body: some View {
        TabView {
            NavigationStack {
                HomeView(receipts: receipts) { newReceipt in
                    receipts.insert(newReceipt, at: 0)
                }
            }
            .tabItem {
                Label("Home", systemImage: "house")
            }

            NavigationStack {
                HistoryView(receipts: receipts)
            }
            .tabItem {
                Label("History", systemImage: "clock")
            }

            NavigationStack {
                ProfileView(participant: DemoData.profile)
            }
            .tabItem {
                Label("Profile", systemImage: "person")
            }
        }
        .tint(Color(red: 0.04, green: 0.45, blue: 0.95))
    }
}

private struct HomeView: View {
    let receipts: [Receipt]
    let onReceiptCreated: (Receipt) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                scanCard
                quickActions
                recentActivity
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .background(AppColors.groupedBackground)
        .navigationTitle("SplitSmart")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("SplitSmart")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.06, green: 0.10, blue: 0.22))
                Text(Formatters.fullDate.string(from: Date()))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(DemoData.profile.initials)
                .font(.headline.weight(.bold))
                .frame(width: 56, height: 56)
                .background(Color.blue.opacity(0.15))
                .clipShape(Circle())
        }
    }

    private var scanCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "camera")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(.white.opacity(0.2))
                .clipShape(Circle())

            Text("Scan Receipt")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Start splitting")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.95))
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.48, blue: 0.95), Color(red: 0.08, green: 0.41, blue: 0.91)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: .blue.opacity(0.20), radius: 14, x: 0, y: 8)
    }

    private var quickActions: some View {
        HStack(spacing: 14) {
            SmallActionCard(title: "Upload Photo", systemImage: "photo")
            NavigationLink {
                ManualEntryView(onReceiptCreated: onReceiptCreated)
            } label: {
                SmallActionCard(title: "Manual Entry", systemImage: "plus")
            }
            .buttonStyle(.plain)
        }
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Activity")
                    .font(.title.weight(.bold))
                    .foregroundStyle(Color(red: 0.08, green: 0.11, blue: 0.22))
                Spacer()
                Text("See All")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
            }

            ForEach(receipts.prefix(2)) { receipt in
                ActivityRow(receipt: receipt)
            }
        }
    }
}

private struct SmallActionCard: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(width: 50, height: 50)
                .background(Color.blue.opacity(0.12))
                .clipShape(Circle())
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color(red: 0.08, green: 0.11, blue: 0.22))
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 146, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 4)
    }
}

private struct ActivityRow: View {
    let receipt: Receipt

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.text")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.gray)
                .frame(width: 52, height: 52)
                .background(AppColors.secondaryBackground)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(receipt.merchantName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(red: 0.08, green: 0.11, blue: 0.22))
                Text(Formatters.shortDate.string(from: receipt.createdAt))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(Formatters.currencyString(from: receipt.total))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color(red: 0.08, green: 0.11, blue: 0.22))
                Text("Split complete")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
            }
        }
        .padding(18)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
    }
}

private struct HistoryView: View {
    let receipts: [Receipt]

    var body: some View {
        List(receipts) { receipt in
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(receipt.merchantName)
                    Text(Formatters.numericDate.string(from: receipt.createdAt))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Formatters.currencyString(from: receipt.total))
                    .fontWeight(.semibold)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("History")
    }
}

private struct ProfileView: View {
    let participant: Participant

    var body: some View {
        VStack(spacing: 16) {
            Text(participant.initials)
                .font(.system(size: 40, weight: .bold))
                .frame(width: 88, height: 88)
                .background(Color.blue.opacity(0.16))
                .clipShape(Circle())
            Text(participant.name)
                .font(.title2.weight(.bold))
            Text("Split smarter with friends.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.groupedBackground)
        .navigationTitle("Profile")
    }
}

private enum Formatters {
    static let fullDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()

    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static let numericDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()

    static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale.current
        return formatter
    }()

    static func currencyString(from amount: Decimal) -> String {
        currency.string(from: NSDecimalNumber(decimal: amount)) ?? "$0.00"
    }
}

private enum AppColors {
    static var groupedBackground: Color {
#if os(iOS)
        return Color(UIColor.systemGroupedBackground)
#elseif os(macOS)
        return Color(NSColor.windowBackgroundColor)
#else
        return Color(.systemGray6)
#endif
    }

    static var secondaryBackground: Color {
#if os(iOS)
        return Color(UIColor.secondarySystemBackground)
#elseif os(macOS)
        return Color(NSColor.controlBackgroundColor)
#else
        return Color(.systemGray5)
#endif
    }
}

private enum DemoData {
    static let profile = Participant(name: "Jordan Davis")

    static let receipts: [Receipt] = {
        let joe = Participant(name: "Joe")
        let maya = Participant(name: "Maya")

        let first = Receipt(
            merchantName: "Joe's Pizza",
            createdAt: Calendar.current.date(byAdding: .day, value: -2, to: .now) ?? .now,
            participants: [joe, maya],
            items: [
                ReceiptItem(name: "Large Pizza", unitPrice: 24, assignedParticipantIDs: [joe.id, maya.id]),
                ReceiptItem(name: "Garlic Knots", unitPrice: 8, assignedParticipantIDs: [maya.id]),
                ReceiptItem(name: "Soda", quantity: 2, unitPrice: 4, assignedParticipantIDs: [joe.id, maya.id])
            ],
            tax: 3.25,
            tip: 6.25
        )

        let second = Receipt(
            merchantName: "Starbucks",
            createdAt: Calendar.current.date(byAdding: .day, value: -5, to: .now) ?? .now,
            participants: [profile],
            items: [
                ReceiptItem(name: "Latte", unitPrice: 6.40, assignedParticipantIDs: [profile.id]),
                ReceiptItem(name: "Sandwich", unitPrice: 5.00, assignedParticipantIDs: [profile.id])
            ],
            tax: 1.00
        )

        return [first, second]
    }()
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
