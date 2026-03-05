//
//  ShapeViewModel.swift
//  3D-Kankl-Druck-Editor
//
//  Central ViewModel: holds shape parameters, surface pattern state,
//  generates mesh, and triggers export.
//

import Foundation
import SwiftUI
import SceneKit
import Combine

@Observable
final class ShapeViewModel {

    // MARK: - Shape selection

    var selectedShape: ShapeType = .cube

    // MARK: - Cube parameters

    var cubeWidth: Float = 20
    var cubeHeight: Float = 20
    var cubeDepth: Float = 20

    // MARK: - Cylinder parameters

    var cylinderRadius: Float = 10
    var cylinderHeight: Float = 30
    var cylinderSegments: Int = 32

    // MARK: - Sphere parameters

    var sphereRadius: Float = 15
    var sphereSegments: Int = 32

    // MARK: - Surface pattern

    var selectedPattern: SurfacePattern = .smooth
    var patternIntensity: Float = 0.5    // 0..1, mapped to mm in export
    var patternScale: Float = 1.0        // multiplier for pattern frequency

    /// Dynamic per-pattern parameters, keyed by PatternParameter.id
    var patternParams: [String: Float] = [:]

    // MARK: - Subdivision level for displacement

    /// Higher = more triangles = finer detail, but slower.
    /// Cube 12 tris → 3 subdivisions = 768 tris, 4 = 3072.
    var subdivisionLevel: Int = 3

    // MARK: - Export state

    var exportFileURL: URL?
    var showShareSheet = false

    // MARK: - Mesh generation

    /// Base mesh before displacement (from shape generators)
    var baseMesh: MeshData {
        switch selectedShape {
        case .cube:
            MeshGenerator.cube(width: cubeWidth, height: cubeHeight, depth: cubeDepth)
        case .cylinder:
            MeshGenerator.cylinder(radius: cylinderRadius, height: cylinderHeight, segments: cylinderSegments)
        case .sphere:
            MeshGenerator.sphere(radius: sphereRadius, segments: sphereSegments)
        }
    }

    /// Final mesh with displacement applied
    var currentMesh: MeshData {
        let base = baseMesh
        guard selectedPattern != .smooth else { return base }

        // Map intensity [0..1] to a reasonable mm displacement based on shape size
        let maxDimension = shapeMaxDimension
        let displacementMM = patternIntensity * maxDimension * 0.08 // max ~8% of size

        return DisplacementEngine.apply(
            pattern: selectedPattern,
            to: base,
            intensity: displacementMM,
            scale: patternScale,
            parameters: resolvedPatternParams,
            subdivisions: subdivisionLevel
        )
    }

    var sceneGeometry: SCNGeometry {
        let geo = currentMesh.toSCNGeometry()
        geo.firstMaterial?.diffuse.contents = UIColor.systemBlue
        geo.firstMaterial?.isDoubleSided = true
        return geo
    }

    // MARK: - Export

    func exportSTL() {
        let mesh = currentMesh
        let data = STLExporter.exportBinary(mesh: mesh)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let dateString = formatter.string(from: Date())
        let patternSuffix = selectedPattern == .smooth ? "" : "_\(selectedPattern.rawValue)"
        let filename = "\(selectedShape.rawValue)\(patternSuffix)_\(dateString).stl"

        exportFileURL = STLExporter.writeToTempFile(data: data, filename: filename)
        showShareSheet = true
    }

    // MARK: - Pattern parameter management

    /// Called when pattern selection changes — resets to defaults
    func resetPatternParams() {
        patternParams = [:]
        for param in selectedPattern.parameters {
            patternParams[param.id] = param.defaultValue
        }
    }

    /// Merges stored params with defaults for any missing keys
    var resolvedPatternParams: [String: Float] {
        var result: [String: Float] = [:]
        for param in selectedPattern.parameters {
            result[param.id] = patternParams[param.id] ?? param.defaultValue
        }
        return result
    }

    // MARK: - Helpers

    private var shapeMaxDimension: Float {
        switch selectedShape {
        case .cube:
            max(cubeWidth, cubeHeight, cubeDepth)
        case .cylinder:
            max(cylinderRadius * 2, cylinderHeight)
        case .sphere:
            sphereRadius * 2
        }
    }
}
