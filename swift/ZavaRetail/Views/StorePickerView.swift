import Anvil
import SwiftUI

/// On-demand store picker (Dashboard header menu / "Switch store" on the
/// Ditto tab). First launch skips it: the app auto-selects the loader-flagged
/// smallest-order store (`demo_default`). The stores arrive over the
/// shared-catalog subscription — if the list is empty, sync is still warming
/// up (or the dataset isn't loaded yet).
struct StorePickerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dittoColors) private var colors

    var body: some View {
        NavigationStack {
            Group {
                if appState.stores.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Waiting for the store catalog to sync…")
                            .foregroundStyle(colors.foregroundSubtle)
                        Text("No data yet? Run scripts/load_data.py to seed Big Peer.")
                            .font(.callout)
                            .foregroundStyle(colors.foregroundSubtle)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } else {
                    List(appState.stores) { store in
                        Button {
                            appState.selectStore(store.store_id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(store.store_name)
                                        .font(.headline)
                                        .foregroundStyle(colors.foregroundNormal)
                                    Text("\(store.location.city), \(store.location.state)")
                                        .font(.subheadline)
                                        .foregroundStyle(colors.foregroundSubtle)
                                }
                                Spacer()
                                if store.is_online {
                                    AnvilBadge("online", status: .promo)
                                }
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(colors.foregroundSubtle)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Choose your store")
        }
    }
}

#Preview {
    let state = AppState()
    DittoTheme {
        StorePickerView().environment(state)
    }
}
