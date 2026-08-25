// FineTune/Views/Rows/AppRowWithLevelPolling.swift
import SwiftUI

/// App row that polls audio levels at regular intervals
struct AppRowWithLevelPolling: View {
    let app: AudioApp
    let volume: Float
    let isMuted: Bool
    let devices: [AudioDevice]
    let deviceIconOverrides: [String: String]
    let selectedDeviceUID: String
    let selectedDeviceUIDs: Set<String>
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?
    let deviceSelectionMode: DeviceSelectionMode
    let boost: BoostLevel
    let onBoostChange: (BoostLevel) -> Void
    let getAudioLevel: () -> Float
    let isPopupVisible: Bool
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onDeviceSelected: (String) -> Void
    let onDevicesSelected: (Set<String>) -> Void
    let onDeviceModeChange: (DeviceSelectionMode) -> Void
    let onSelectFollowDefault: () -> Void
    let onAppActivate: () -> Void
    let eqSettings: EQSettings
    let userPresets: [UserEQPreset]
    let onEQChange: (EQSettings) -> Void
    let onUserPresetSelected: (UserEQPreset) -> Void
    let onSavePreset: (String, EQSettings) -> Void
    let onDeleteUserPreset: (UUID) -> Void
    let onRenameUserPreset: (UUID, String) -> Void
    let isEQExpanded: Bool
    let onEQToggle: () -> Void
    let isFocused: Bool
    let auChain: AUChainPanelModel
    /// Reads the app's live transport state (spec §9). Rebuilt on the level
    /// timer's tick rather than on a timer of its own: the strip's playhead and
    /// the VU meter want the same 30 Hz, and the RT-written fields it reads
    /// (position, live/behind, horizon) are not observable any other way.
    let makeTape: () -> TapeTransportPanelModel

    @State private var displayLevel: Float = 0
    @State private var tape = TapeTransportPanelModel()
    @State private var levelTimer: Timer?

    init(
        app: AudioApp,
        volume: Float,
        isMuted: Bool,
        devices: [AudioDevice],
        deviceIconOverrides: [String: String] = [:],
        selectedDeviceUID: String,
        selectedDeviceUIDs: Set<String> = [],
        isFollowingDefault: Bool = true,
        defaultDeviceUID: String? = nil,
        deviceSelectionMode: DeviceSelectionMode = .single,
        boost: BoostLevel = .x1,
        onBoostChange: @escaping (BoostLevel) -> Void = { _ in },
        getAudioLevel: @escaping () -> Float,
        isPopupVisible: Bool = true,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteChange: @escaping (Bool) -> Void,
        onDeviceSelected: @escaping (String) -> Void,
        onDevicesSelected: @escaping (Set<String>) -> Void = { _ in },
        onDeviceModeChange: @escaping (DeviceSelectionMode) -> Void = { _ in },
        onSelectFollowDefault: @escaping () -> Void = {},
        onAppActivate: @escaping () -> Void = {},
        eqSettings: EQSettings = EQSettings(),
        userPresets: [UserEQPreset] = [],
        onEQChange: @escaping (EQSettings) -> Void = { _ in },
        onUserPresetSelected: @escaping (UserEQPreset) -> Void = { _ in },
        onSavePreset: @escaping (String, EQSettings) -> Void = { _, _ in },
        onDeleteUserPreset: @escaping (UUID) -> Void = { _ in },
        onRenameUserPreset: @escaping (UUID, String) -> Void = { _, _ in },
        isEQExpanded: Bool = false,
        onEQToggle: @escaping () -> Void = {},
        isFocused: Bool = false,
        auChain: AUChainPanelModel = AUChainPanelModel(),
        makeTape: @escaping () -> TapeTransportPanelModel = { TapeTransportPanelModel() }
    ) {
        self.app = app
        self.volume = volume
        self.isMuted = isMuted
        self.devices = devices
        self.deviceIconOverrides = deviceIconOverrides
        self.selectedDeviceUID = selectedDeviceUID
        self.selectedDeviceUIDs = selectedDeviceUIDs
        self.isFollowingDefault = isFollowingDefault
        self.defaultDeviceUID = defaultDeviceUID
        self.deviceSelectionMode = deviceSelectionMode
        self.boost = boost
        self.onBoostChange = onBoostChange
        self.getAudioLevel = getAudioLevel
        self.isPopupVisible = isPopupVisible
        self.onVolumeChange = onVolumeChange
        self.onMuteChange = onMuteChange
        self.onDeviceSelected = onDeviceSelected
        self.onDevicesSelected = onDevicesSelected
        self.onDeviceModeChange = onDeviceModeChange
        self.onSelectFollowDefault = onSelectFollowDefault
        self.onAppActivate = onAppActivate
        self.eqSettings = eqSettings
        self.userPresets = userPresets
        self.onEQChange = onEQChange
        self.onUserPresetSelected = onUserPresetSelected
        self.onSavePreset = onSavePreset
        self.onDeleteUserPreset = onDeleteUserPreset
        self.onRenameUserPreset = onRenameUserPreset
        self.isEQExpanded = isEQExpanded
        self.onEQToggle = onEQToggle
        self.isFocused = isFocused
        self.auChain = auChain
        self.makeTape = makeTape
    }

    var body: some View {
        AppRow(
            app: app,
            volume: volume,
            audioLevel: displayLevel,
            devices: devices,
            deviceIconOverrides: deviceIconOverrides,
            selectedDeviceUID: selectedDeviceUID,
            selectedDeviceUIDs: selectedDeviceUIDs,
            isFollowingDefault: isFollowingDefault,
            defaultDeviceUID: defaultDeviceUID,
            deviceSelectionMode: deviceSelectionMode,
            isMuted: isMuted,
            boost: boost,
            onBoostChange: onBoostChange,
            onVolumeChange: onVolumeChange,
            onMuteChange: onMuteChange,
            onDeviceSelected: onDeviceSelected,
            onDevicesSelected: onDevicesSelected,
            onDeviceModeChange: onDeviceModeChange,
            onSelectFollowDefault: onSelectFollowDefault,
            onAppActivate: onAppActivate,
            eqSettings: eqSettings,
            userPresets: userPresets,
            onEQChange: onEQChange,
            onUserPresetSelected: onUserPresetSelected,
            onSavePreset: onSavePreset,
            onDeleteUserPreset: onDeleteUserPreset,
            onRenameUserPreset: onRenameUserPreset,
            isEQExpanded: isEQExpanded,
            onEQToggle: onEQToggle,
            isFocused: isFocused,
            auChain: auChain,
            tape: tape
        )
        .onAppear {
            // After the render, never during it.
            tape = makeTape()
            if isPopupVisible {
                startLevelPolling()
            }
        }
        .onDisappear {
            stopLevelPolling()
        }
        .onChange(of: isPopupVisible) { _, visible in
            if visible {
                startLevelPolling()
            } else {
                stopLevelPolling()
                displayLevel = 0  // Reset meter when hidden
            }
        }
    }

    private func startLevelPolling() {
        // Guard against duplicate timers
        guard levelTimer == nil else { return }

        levelTimer = Timer.scheduledTimer(
            withTimeInterval: DesignTokens.Timing.vuMeterUpdateInterval,
            repeats: true
        ) { _ in
            MainActor.assumeIsolated {
                displayLevel = getAudioLevel()
                tape = makeTape()
            }
        }
    }

    private func stopLevelPolling() {
        levelTimer?.invalidate()
        levelTimer = nil
    }
}
