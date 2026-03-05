//
//  ShapeViewModel.swift
//  3D-Kankl-Druck-Editor
//
//  Central ViewModel: holds shape parameters, surface pattern state,
//  generates mesh with debounced async computation, and triggers export.
//

import Foundation
import SwiftUI
import SceneKit

@Observable
final class ShapeViewModel {

    // MARK: - Shape selection

    var selectedShape: ShapeType = .cube {
        didSet { schedulePreviewUpdate() }
    }

    // MARK: - Cube parameters

    var cubeWidth: Float = 20 { didSet { schedulePreviewUpdate() } }
    var cubeHeight: Float = 20 { didSet { schedulePreviewUpdate() } }
    var cubeDepth: Float = 20 { didSet { schedulePreviewUpdate() } }

    // MARK: - Cylinder parameters

    var cylinderRadius: Float = 10 { didSet { schedulePreviewUpdate() } }
    var cylinderHeight: Float = 30 { didSet { schedulePreviewUpdate() } }
    var cylinderSegments: Int = 32 { didSet { schedulePreviewUpdate() } }

    // MARK: - Sphere parameters

    var sphereRadius: Float = 15 { didSet { schedulePreviewUpdate() } }
    var sphereSegments: Int = 32 { didSet { schedulePreviewUpdate() } }

    // MARK: - Surface pattern

    var selectedPattern: SurfacePattern = .smooth { didSet { schedulePreviewUpdate() } }
    var patternIntensity: Float = 0.5 { didSet { schedulePreviewUpdate() } }
    var patternScale: Float = 1.0 { didSet { schedulePreviewUpdate() } }

    /// Dynamic per-pattern parameters, keyed by PatternParameter.id
    var patternParams: [String: Float] = [:] {
        didSet { schedulePreviewUpdate() }
    }

    // MARK: - Preview state

    /// The geometry currently displayed in the 3D preview (updated async)
    var previewGeometry: SCNGeometry = {
        // Start with a default cube
        let geo = MeshGenerator.cube(width: 20, height: 20, depth: 20).toSCNGeometry()
        geo.firstMaterial?.diffuse.contents = UIColor.systemBlue
        geo.firstMaterial?.isDoubleSided = true
        return geo
    }()

    /// True while a displacement computation is running
    var isComputing = false

    // MARK: - Export state

    var exportFileURL: URL?
    var showShareSheet = false

    // MARK: - Debounce timer

    private var debounceTask: Task<Void, Never>?

    /// Debounce interval: short for smooth (instant), longer for displacement
    private var debounceInterval: Duration {
        selectedPattern == .smooth ? .milliseconds(16) : .milliseconds(200)
    }

    // MARK: - Mesh generation

    /// Base mesh before displacement (from shape generators). Cheap to compute.
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

    /// Synchronous full mesh computation (used for export)
    var currentMesh: MeshData {
        let base = baseMesh
        guard selectedPattern != .smooth else { return base }
        let maxDimension = shapeMaxDimension
        let displacementMM = patternIntensity * maxDimension * 0.08

        return DisplacementEngine.apply(
            pattern: selectedPattern,
            to: base,
            intensity: displacementMM,
            scale: patternScale,
            parameters: resolvedPatternParams
        )
    }

    // MARK: - Debounced async preview

    private func schedulePreviewUpdate() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Wait for debounce interval
            try? await Task.sleep(for: self.debounceInterval)
            guard !Task.isCancelled else { return }

            // For smooth shapes, compute synchronously (fast path)
            if self.selectedPattern == .smooth {
                let geo = self.baseMesh.toSCNGeometry()
                geo.firstMaterial?.diffuse.contents = UIColor.systemBlue
                geo.firstMaterial?.isDoubleSided = true
                self.previewGeometry = geo
                return
            }

            // Capture values for background computation
            let pattern = self.selectedPattern
            let base = self.baseMesh
            let intensity = self.patternIntensity * self.shapeMaxDimension * 0.08
            let scale = self.patternScale
            let params = self.resolvedPatternParams

            self.isComputing = true

            // Run displacement on background thread
            let mesh = await Task.detached(priority: .userInitiated) {
                DisplacementEngine.apply(
                    pattern: pattern,
                    to: base,
                    intensity: intensity,
                    scale: scale,
                    parameters: params
                )
            }.value

            guard !Task.isCancelled else { return }

            let geo = mesh.toSCNGeometry()
            geo.firstMaterial?.diffuse.contents = UIColor.systemBlue
            geo.firstMaterial?.isDoubleSided = true
            self.previewGeometry = geo
            self.isComputing = false
        }
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
