// FineTune/Views/Settings/Tabs/AudioTab.swift
import SwiftUI

@MainActor
struct AudioTab: View {
    @Bindable var settings: SettingsManager
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor

    /// Memoized sorted output devices for the system-sounds picker.
    @State private var sortedOutputDevices: [AudioDevice] = []

    private var unifiedLoudnessToggleBinding: Binding<Bool> {
        Binding(
            get: {
                settings.appSettings.loudnessCompensationEnabled
                    && settings.appSettings.loudnessEqualizationEnabled
            },
            set: { isEnabled in
                settings.appSettings.setUnifiedLoudnessEnabled(isEnabled)
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                volumeSection
                devicesSection
                tapeSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .onAppear { updateSortedDevices() }
        .onChange(of: audioEngine.outputDevices) { _, _ in updateSortedDevices() }
        .onChange(of: settings.appSettings.lockInputDevice) { oldValue, newValue in
            if !oldValue && newValue {
                audioEngine.handleInputLockEnabled()
            }
        }
        .onChange(of: settings.appSettings.loudnessCompensationEnabled) { _, newValue in
            audioEngine.setLoudnessCompensationEnabled(newValue)
        }
        .onChange(of: settings.appSettings.loudnessEqualizationEnabled) { _, newValue in
            audioEngine.setLoudnessEqualizationEnabled(newValue)
        }
    }

    // MARK: - Volume

    private var volumeSection: some View {
        SettingsSection("Volume") {
            SettingsRow(
                "Default Volume",
                description: "Initial volume for new apps"
            ) {
                VolumeSlider(
                    $settings.appSettings.defaultNewAppVolume,
                    range: 0.1...1.0,
                    width: 280
                )
            }
            SettingsRowDivider()
            SettingsRow(
                "Loudness Compensation",
                description: "Boost low frequencies at low volume"
            ) {
                Toggle("", isOn: unifiedLoudnessToggleBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

    // MARK: - Devices

    private var devicesSection: some View {
        SettingsSection("Devices") {
            SettingsRow(
                "Lock Input Device",
                description: "Prevent auto-switching when devices connect"
            ) {
                Toggle("", isOn: $settings.appSettings.lockInputDevice)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "System Sounds",
                description: "Where alerts and effects play"
            ) {
                SystemSoundsDevicePicker(
                    devices: sortedOutputDevices,
                    deviceIconOverrides: audioEngine.settingsManager.deviceIconOverrides,
                    selectedDeviceUID: deviceVolumeMonitor.systemDeviceUID,
                    defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
                    isFollowingDefault: deviceVolumeMonitor.isSystemFollowingDefault,
                    onDeviceSelected: { deviceUID in
                        if let device = sortedOutputDevices.first(where: { $0.uid == deviceUID }) {
                            deviceVolumeMonitor.setSystemDeviceExplicit(device.id)
                        }
                    },
                    onSelectFollowDefault: {
                        deviceVolumeMonitor.setSystemFollowDefault()
                    }
                )
            }
            SettingsRowDivider()
            SettingsRow(
                "Alert Volume",
                description: "Volume for alerts and notifications"
            ) {
                VolumeSlider(
                    Binding(
                        get: { deviceVolumeMonitor.alertVolume },
                        set: { deviceVolumeMonitor.setAlertVolume($0) }
                    ),
                    range: 0...1,
                    width: 280
                )
            }
            .task {
                // No CoreAudio listener for alert volume — must poll via AppleScript.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    deviceVolumeMonitor.refreshAlertVolume()
                }
            }
        }
    }

    // MARK: - Tape

    private var tapeSection: some View {
        SettingsSection("Tape") {
            SettingsRow(
                "Save Length",
                description: "How much of the tape a save captures. Clamps to what's currently recorded."
            ) {
                TapeSaveLengthPicker(selection: $settings.appSettings.tapeSaveLength)
            }
        }
    }

    private func updateSortedDevices() {
        sortedOutputDevices = audioEngine.prioritySortedOutputDevices
    }
}

/// Menu-with-chevron picker for `TapeSaveLength`, matching the Tape panel's
/// own tape-length control (`TapeTransportPanelView.lengthRow`) rather than
/// a new picker style — the user already associates that shape with "pick a
/// tape duration".
private struct TapeSaveLengthPicker: View {
    @Binding var selection: TapeSaveLength

    var body: some View {
        Menu {
            ForEach(TapeSaveLength.allCases) { length in
                Button(length.description) { selection = length }
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.xxs) {
                Text(selection.description)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
            .font(DesignTokens.Typography.pickerText)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                    .strokeBorder(DesignTokens.Colors.menuBorder, lineWidth: 1)
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }
}
