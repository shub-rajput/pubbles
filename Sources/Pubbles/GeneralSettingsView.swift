import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @State private var showResetConfirmation = false

    private var behavior: BehaviorConfig { configManager.config.behavior }

    var body: some View {
        Form {
            AccessibilityBannerSection()
            MicrophoneBannerSection()
            Section {
                Toggle("Multi-line Pubble", isOn: multiLineBinding)

                if !behavior.multiLine {
                    Picker("Per Line Character Limit", selection: charLimitPickerBinding) {
                        ForEach([15, 20, 25, 30, 40, 50], id: \.self) { c in
                            Text("\(c)").tag(c)
                        }
                    }
                }
            }

            Section {
                Picker("Idle Timeout", selection: idleTimeoutBinding) {
                    Text("Never").tag(0.0)
                    ForEach([3.0, 5.0, 10.0, 20.0], id: \.self) { s in
                        Text("\(Int(s))s").tag(s)
                    }
                }

                Toggle("Click to Dismiss", isOn: clickToDismissBinding)
            }

            Section {
                Picker("Fade In", selection: fadeInBinding) {
                    ForEach([0.0, 0.1, 0.2, 0.3, 0.5], id: \.self) { s in
                        Text(s == 0 ? "Instant" : "\(s, specifier: "%.1f")s").tag(s)
                    }
                }

                Picker("Fade Out", selection: fadeOutBinding) {
                    ForEach([0.0, 0.2, 0.5, 0.8, 1.0], id: \.self) { s in
                        Text(s == 0 ? "Instant" : "\(s, specifier: "%.1f")s").tag(s)
                    }
                }
            }

            Section {
                Toggle("Wiggle to Activate", isOn: wiggleEnabledBinding)

                if behavior.wiggleEnabled {
                    Picker("Mode", selection: wiggleModeBinding) {
                        Text("Pubble").tag("pubble")
                        Text("Babble").tag("babble")
                        Text("Doodle").tag("doodle")
                    }

                    Picker("Sensitivity", selection: wiggleSensitivityBinding) {
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                    }
                }
            }

            Section {
                Button("Reset Default Themes") {
                    showResetConfirmation = true
                }
                .foregroundStyle(.red)
            }
            .listRowBackground(Color.clear)
            .listSectionSeparator(.hidden)
        }
        .formStyle(.grouped)
        .alert("Reset to Factory Defaults?", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                configManager.resetToFactory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will restore all built-in themes to their original values and clear any unsaved changes. Your custom themes will not be affected.")
        }
        .navigationTitle("Settings")
    }

    // MARK: - Bindings

    private var charLimitPickerBinding: Binding<Int> {
        Binding(
            get: { behavior.charLimit },
            set: { configManager.setBehaviorValue("charLimit", $0) }
        )
    }

    private var idleTimeoutBinding: Binding<Double> {
        Binding(
            get: { behavior.idleTimeout },
            set: { configManager.setBehaviorValue("idleTimeout", $0) }
        )
    }

    private var fadeInBinding: Binding<Double> {
        Binding(
            get: { behavior.fadeInDuration },
            set: { configManager.setBehaviorValue("fadeInDuration", $0) }
        )
    }

    private var fadeOutBinding: Binding<Double> {
        Binding(
            get: { behavior.fadeOutDuration },
            set: { configManager.setBehaviorValue("fadeOutDuration", $0) }
        )
    }

    private var multiLineBinding: Binding<Bool> {
        Binding(
            get: { behavior.multiLine },
            set: { configManager.setBehaviorValue("multiLine", $0) }
        )
    }

    private var clickToDismissBinding: Binding<Bool> {
        Binding(
            get: { behavior.clickToDismiss },
            set: { configManager.setBehaviorValue("clickToDismiss", $0) }
        )
    }

    private var wiggleEnabledBinding: Binding<Bool> {
        Binding(
            get: { behavior.wiggleEnabled },
            set: { configManager.setBehaviorValue("wiggleEnabled", $0) }
        )
    }

    private var wiggleModeBinding: Binding<String> {
        Binding(
            get: { behavior.wiggleToActivate },
            set: { configManager.setBehaviorValue("wiggleToActivate", $0) }
        )
    }

    private var wiggleSensitivityBinding: Binding<String> {
        Binding(
            get: { behavior.wiggleSensitivity },
            set: { configManager.setBehaviorValue("wiggleSensitivity", $0) }
        )
    }

}
