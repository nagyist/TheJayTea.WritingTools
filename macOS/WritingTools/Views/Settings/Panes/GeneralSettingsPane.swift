//
//  GeneralSettingsPane.swift
//  WritingTools
//
//  Created by Arya Mirsepasi on 04.11.25.
//

import SwiftUI
import KeyboardShortcuts
import AppKit

struct GeneralSettingsPane<SaveButton: View>: View {
    @Bindable var appState: AppState
    @Bindable var settings = AppSettings.shared
    @Binding var needsSaving: Bool
    @Binding var showingCommandsManager: Bool
    var showOnlyApiSetup: Bool
    let saveButton: SaveButton

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("General Settings")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            GroupBox("Keyboard Shortcuts") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Set a global shortcut to quickly activate Writing Tools.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .center, spacing: 12) {
                        Text("Activate Writing Tools:")
                            .frame(width: 180, alignment: .leading)
                            .foregroundStyle(.primary)
                        KeyboardShortcuts.Recorder(
                            for: .showPopup,
                            onChange: { _ in
                                needsSaving = true
                            }
                        )
                        .accessibilityLabel("Activate Writing Tools shortcut")
                        .accessibilityHint("Sets the global shortcut to open Writing Tools.")
                        .help("Choose a convenient key combination to bring up Writing Tools from anywhere.")
                    }
                    .padding(.vertical, 2)
                }
            }

            GroupBox("Commands") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Manage your writing tools and assign keyboard shortcuts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button(action: {
                        showingCommandsManager = true
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "list.bullet.rectangle")
                            Text("Manage Commands")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color(.controlBackgroundColor))
                        .clipShape(.rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Manage Commands")
                    .accessibilityHint("Open the Commands Manager to add, edit, or remove commands.")
                    .help("Open the Commands Manager to add, edit, or remove commands.")

                    Toggle(isOn: $settings.openCustomCommandsInResponseWindow) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open custom prompts in response window")
                            Text("When unchecked, custom prompts will replace selected text inline")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.top, 4)
                    .accessibilityLabel("Open custom prompts in response window")
                    .accessibilityHint("When off, custom prompts replace selected text inline.")
                    .onChange(of: settings.openCustomCommandsInResponseWindow) { _, _ in
                        needsSaving = true
                    }
                    .help("Choose whether custom prompts open in a separate response window or replace text inline.")
                }
            }
            
            GroupBox("Onboarding") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("You can rerun the onboarding flow to review permissions and quickly configure the app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button {
                            restartOnboarding()
                        } label: {
                            Label("Restart Onboarding", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Restart onboarding")
                        .accessibilityHint("Open the onboarding window to review permissions and setup.")
                        .help("Open the onboarding window to set up WritingTools again.")

                        Spacer()
                    }
                }
            }

            Spacer()

            if !showOnlyApiSetup {
                saveButton
            }
            
        }
        .sheet(isPresented: $showingCommandsManager) {
            CommandsView(commandManager: appState.commandManager)
        }
    }

    private func restartOnboarding() {
        // Mark onboarding as not completed
        settings.hasCompletedOnboarding = false
        WindowManager.shared.showOnboarding(appState: appState, title: "Onboarding")
        WindowManager.shared.closeSettingsWindow()
    }
}
