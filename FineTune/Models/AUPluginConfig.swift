import AudioToolbox
import Foundation

/// Persisted configuration for one Audio Unit plugin slot in an app's effect chain.
/// See `tasks/specs/2026-08-25-phase1-au-hosting.md` §4 for the schema this mirrors.
struct AUPluginConfig: Codable, Equatable {
    var id: UUID                      // stable slot identity (window autosave, badges)
    var componentType: UInt32         // AudioComponentDescription triple
    var componentSubType: UInt32
    var componentManufacturer: UInt32
    var displayName: String           // shown when the component is missing
    var isBypassed: Bool
    var fullState: Data?              // binary plist (PropertyListSerialization) of AUAudioUnit.fullState

    /// The `AudioComponentDescription` triple for looking up this plugin's component.
    var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: componentType,
            componentSubType: componentSubType,
            componentManufacturer: componentManufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }
}

struct AUChainConfig: Codable, Equatable {
    var plugins: [AUPluginConfig]
}
