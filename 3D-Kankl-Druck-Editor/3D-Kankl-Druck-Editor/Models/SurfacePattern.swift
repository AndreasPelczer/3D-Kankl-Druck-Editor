//
//  SurfacePattern.swift
//  3D-Kankl-Druck-Editor
//
//  Surface displacement patterns that can be applied to any shape mesh.
//

import Foundation

struct PatternParameter: Identifiable {
    let id: String       // key for dictionary lookup
    let name: String     // display name
    let range: ClosedRange<Float>
    let defaultValue: Float
    let step: Float?     // nil = continuous
}

enum SurfacePattern: String, CaseIterable, Identifiable {
    case smooth    = "Glatt"
    case scales    = "Schuppen"
    case snakeSkin = "Schlangenhaut"
    case crumpled  = "Zerknülltes Papier"
    case ribbed    = "Riffel"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .smooth:    return "circle"
        case .scales:    return "fish"
        case .snakeSkin: return "diamond"
        case .crumpled:  return "newspaper"
        case .ribbed:    return "line.3.horizontal"
        }
    }

    /// Pattern-specific parameters (beyond the global intensity & scale)
    var parameters: [PatternParameter] {
        switch self {
        case .smooth:
            return []
        case .scales:
            return [
                PatternParameter(id: "overlap", name: "Überlappung", range: 0.1...0.9, defaultValue: 0.5, step: nil),
                PatternParameter(id: "rows", name: "Reihen", range: 4...30, defaultValue: 12, step: 1),
            ]
        case .snakeSkin:
            return [
                PatternParameter(id: "jitter", name: "Unregelmäßigkeit", range: 0...1, defaultValue: 0.3, step: nil),
                PatternParameter(id: "cellSize", name: "Zellgröße", range: 1...20, defaultValue: 6, step: nil),
            ]
        case .crumpled:
            return [
                PatternParameter(id: "octaves", name: "Detailstufen", range: 1...8, defaultValue: 5, step: 1),
                PatternParameter(id: "persistence", name: "Rauheit", range: 0.1...0.9, defaultValue: 0.5, step: nil),
            ]
        case .ribbed:
            return [
                PatternParameter(id: "spacing", name: "Rillenabstand", range: 0.5...10, defaultValue: 3, step: nil),
                PatternParameter(id: "sharpness", name: "Schärfe", range: 0.1...1, defaultValue: 0.5, step: nil),
            ]
        }
    }
}
