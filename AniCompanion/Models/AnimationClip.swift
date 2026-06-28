import Foundation

/// Represents a single keyframe in a skeletal animation.
struct AnimationKeyframe: Codable {
    /// Time in seconds from the start of the animation.
    let time: Float
    /// Bone rotations as quaternions [x, y, z, w], keyed by VRM humanoid bone name.
    let bones: [String: [Float]]
}

/// A pre-baked skeletal animation clip loaded from JSON.
///
/// Animation data is exported from Blender using `Tools/export_animation.py` with
/// bone names matching the standard VRM humanoid bone names (e.g. "rightUpperArm").
/// Rotations are stored as quaternion arrays `[x, y, z, w]`.
struct AnimationClip: Codable {
    let name: String
    let fps: Float
    let duration: Float
    let loop: Bool
    let frames: [AnimationKeyframe]

    /// All unique bone names referenced across all frames in this clip.
    var boneNames: Set<String> {
        var names = Set<String>()
        for frame in frames {
            names.formUnion(frame.bones.keys)
        }
        return names
    }

    /// Load a single animation clip from the app bundle's `Animations/` folder.
    static func load(named name: String) -> AnimationClip? {
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Animations"
        ) else {
            Log.animation("[Animation] File not found: Animations/\(name).json")
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let clip = try JSONDecoder().decode(AnimationClip.self, from: data)
            Log.animation("[Animation] Loaded clip '\(clip.name)': \(clip.frames.count) frames, \(clip.duration)s, loop=\(clip.loop)")
            return clip
        } catch {
            Log.animation("[Animation] Failed to decode \(name).json: \(error)")
            return nil
        }
    }

    /// Load all animation clips from the bundle's `Animations/` folder.
    static func loadAll() -> [String: AnimationClip] {
        guard let animationsURL = Bundle.main.url(
            forResource: "Animations",
            withExtension: nil
        ) else {
            Log.animation("[Animation] Animations folder not found in bundle")
            return [:]
        }

        var clips: [String: AnimationClip] = [:]

        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: animationsURL,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }

            for fileURL in fileURLs {
                let data = try Data(contentsOf: fileURL)
                let clip = try JSONDecoder().decode(AnimationClip.self, from: data)
                clips[clip.name] = clip
            }
        } catch {
            Log.animation("[Animation] Failed to load animations: \(error)")
        }

        Log.animation("[Animation] Loaded \(clips.count) animation clip(s)")
        return clips
    }
}
