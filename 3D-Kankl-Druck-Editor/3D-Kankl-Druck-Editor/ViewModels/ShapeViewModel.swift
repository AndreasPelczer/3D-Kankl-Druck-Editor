//
//  ShapeViewModel.swift
//  3D-Kankl-Druck-Editor
//
//  Central ViewModel: holds shape parameters, imported mesh state,
//  surface pattern state, generates mesh with debounced async computation,
//  and triggers import/export.
//

import Foundation
import SwiftUI
import SceneKit

// MARK: - Imported shape data

struct ImportedShape {
    let originalURL: URL
    let originalMesh: MeshData         // raw parsed mesh (for reset)
    let normalizedMesh: MeshData       // centered + normalized to 50mm
    let displayName: String            // filename without extension
    let originalTriangleCount: Int
    let originalSizeInMM: SIMD3<Float> // bounding box of raw mesh
}

// MARK: - ViewModel

@Observable
final class ShapeViewModel {

    // MARK: - Mode: generated shape vs imported mesh

    /// When set, the imported mesh is shown instead of a generated shape.
    var importedShape: ImportedShape?

    /// True when an imported mesh is active
    var hasImportedMesh: Bool { importedShape != nil }

    // MARK: - Import scale

    /// Scale factor for imported mesh (1.0 = as-imported, after normalization)
    var importScaleFactor: Float = 1.0 { didSet { schedulePreviewUpdate() } }

    // MARK: - Import state

    var importError: FileImportError?
    var showImportError = false
    var showComplexityWarning = false
    var pendingComplexMesh: (mesh: MeshData, url: URL)?
    var isImporting = false

    // MARK: - Mesh analysis & repair

    var meshAnalysis: MeshAnalysis?
    var isAnalyzing = false
    var isRepairing = false
    var repairLog: [String] = []
    var showRepairLog = false
    var showRepairDetails = false
    var showExportWarning = false

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

    private var debounceInterval: Duration {
        selectedPattern == .smooth ? .milliseconds(16) : .milliseconds(200)
    }

    // MARK: - Mesh generation

    /// Base mesh (either from generated shape or imported mesh with scale applied)
    var baseMesh: MeshData {
        if let imported = importedShape {
            return imported.normalizedMesh.scaled(by: importScaleFactor)
        }
        switch selectedShape {
        case .cube:
            return MeshGenerator.cube(width: cubeWidth, height: cubeHeight, depth: cubeDepth)
        case .cylinder:
            return MeshGenerator.cylinder(radius: cylinderRadius, height: cylinderHeight, segments: cylinderSegments)
        case .sphere:
            return MeshGenerator.sphere(radius: sphereRadius, segments: sphereSegments)
        }
    }

    /// Synchronous full mesh computation (used for export)
    var currentMesh: MeshData {
        let base = baseMesh
        guard selectedPattern != .smooth else { return base }
        let maxDimension = meshMaxDimension
        let displacementMM = patternIntensity * maxDimension * 0.08

        return DisplacementEngine.apply(
            pattern: selectedPattern,
            to: base,
            intensity: displacementMM,
            scale: patternScale,
            parameters: resolvedPatternParams
        )
    }

    // MARK: - File Import (STL, OBJ, DXF)

    /// Import a 3D file from a URL. Supports STL, OBJ, DXF.
    func importFile(from url: URL) {
        isImporting = true

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let rawMesh = try await Task.detached(priority: .userInitiated) {
                    try FileImporter.load(from: url)
                }.value

                // Check complexity
                if rawMesh.triangles.count > 50_000 {
                    self.pendingComplexMesh = (mesh: rawMesh, url: url)
                    self.showComplexityWarning = true
                    self.isImporting = false
                    return
                }

                self.finalizeImport(rawMesh: rawMesh, url: url)
            } catch let error as FileImportError {
                self.importError = error
                self.showImportError = true
                self.isImporting = false
            } catch {
                self.importError = .fileNotReadable
                self.showImportError = true
                self.isImporting = false
            }
        }
    }

    /// Accept a complex mesh as-is
    func acceptComplexMesh() {
        guard let pending = pendingComplexMesh else { return }
        isImporting = true
        finalizeImport(rawMesh: pending.mesh, url: pending.url)
        pendingComplexMesh = nil
    }

    /// Decimate a complex mesh to 20k triangles, then import
    func decimateAndImport() {
        guard let pending = pendingComplexMesh else { return }
        isImporting = true
        pendingComplexMesh = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            let mesh = pending.mesh
            let url = pending.url

            let decimated = await Task.detached(priority: .userInitiated) {
                mesh.decimated(targetCount: 20_000)
            }.value

            self.finalizeImport(rawMesh: decimated, url: url)
        }
    }

    private func finalizeImport(rawMesh: MeshData, url: URL) {
        let originalSize = rawMesh.sizeInMM
        let originalCount = rawMesh.triangles.count
        let normalized = rawMesh.centered().normalized(targetSize: 50.0)

        let name = url.deletingPathExtension().lastPathComponent
        importedShape = ImportedShape(
            originalURL: url,
            originalMesh: rawMesh,
            normalizedMesh: normalized,
            displayName: name,
            originalTriangleCount: originalCount,
            originalSizeInMM: originalSize
        )
        importScaleFactor = 1.0
        selectedPattern = .smooth
        patternIntensity = 0.5
        patternScale = 1.0
        patternParams = [:]
        isImporting = false
        meshAnalysis = nil
        repairLog = []
        schedulePreviewUpdate()

        // Auto-analyze imported mesh
        analyzeMesh()
    }

    // MARK: - Reset

    /// Returns to original imported mesh (undo all displacement + scale changes)
    func resetToOriginal() {
        guard importedShape != nil else { return }
        importScaleFactor = 1.0
        selectedPattern = .smooth
        patternIntensity = 0.5
        patternScale = 1.0
        patternParams = [:]
        schedulePreviewUpdate()
    }

    /// Close imported mesh and return to generated shapes
    func closeImportedMesh() {
        importedShape = nil
        importScaleFactor = 1.0
        selectedPattern = .smooth
        patternIntensity = 0.5
        patternScale = 1.0
        patternParams = [:]
        meshAnalysis = nil
        repairLog = []
        schedulePreviewUpdate()
    }

    // MARK: - Mesh Analysis & Repair

    /// Analyzes the current base mesh for problems (async, background thread)
    func analyzeMesh() {
        isAnalyzing = true
        meshAnalysis = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            let mesh = self.baseMesh

            let analysis = await Task.detached(priority: .userInitiated) {
                MeshAnalyzer.analyze(mesh: mesh)
            }.value

            guard !Task.isCancelled else { return }
            self.meshAnalysis = analysis
            self.isAnalyzing = false
        }
    }

    /// Repairs all issues found in analysis
    func repairMesh() {
        guard let analysis = meshAnalysis, !analysis.isPrintable else { return }
        guard let imported = importedShape else { return }

        isRepairing = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            let mesh = imported.normalizedMesh

            let result = await Task.detached(priority: .userInitiated) {
                MeshRepairer.repair(mesh: mesh, analysis: analysis)
            }.value

            guard !Task.isCancelled else { return }

            // Replace the imported shape with repaired mesh
            let repairedImport = ImportedShape(
                originalURL: imported.originalURL,
                originalMesh: imported.originalMesh,
                normalizedMesh: result.mesh,
                displayName: imported.displayName,
                originalTriangleCount: imported.originalTriangleCount,
                originalSizeInMM: imported.originalSizeInMM
            )
            self.importedShape = repairedImport
            self.repairLog = result.log
            self.isRepairing = false
            self.showRepairLog = true
            self.schedulePreviewUpdate()

            // Re-analyze after repair
            self.analyzeMesh()
        }
    }

    /// Try export, but warn if mesh has issues
    func tryExportSTL() {
        if let analysis = meshAnalysis, !analysis.isPrintable {
            showExportWarning = true
        } else {
            exportSTL()
        }
    }

    /// True if the imported mesh has been modified from its original state
    var hasModifications: Bool {
        guard importedShape != nil else { return false }
        return selectedPattern != .smooth
            || importScaleFactor != 1.0
            || patternIntensity != 0.5
            || patternScale != 1.0
    }

    // MARK: - Debounced async preview

    func schedulePreviewUpdate() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            guard let self else { return }

            try? await Task.sleep(for: self.debounceInterval)
            guard !Task.isCancelled else { return }

            if self.selectedPattern == .smooth {
                let geo = self.baseMesh.toSCNGeometry()
                geo.firstMaterial?.diffuse.contents = UIColor.systemBlue
                geo.firstMaterial?.isDoubleSided = true
                self.previewGeometry = geo
                return
            }

            let pattern = self.selectedPattern
            let base = self.baseMesh
            let intensity = self.patternIntensity * self.meshMaxDimension * 0.08
            let scale = self.patternScale
            let params = self.resolvedPatternParams

            self.isComputing = true

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

        let baseName: String
        if let imported = importedShape {
            baseName = imported.displayName
        } else {
            baseName = selectedShape.rawValue
        }
        let filename = "\(baseName)\(patternSuffix)_\(dateString).stl"

        exportFileURL = STLExporter.writeToTempFile(data: data, filename: filename)
        showShareSheet = true
    }

    // MARK: - File picker

    var showFilePicker = false

    // MARK: - Pattern parameter management

    func resetPatternParams() {
        patternParams = [:]
        for param in selectedPattern.parameters {
            patternParams[param.id] = param.defaultValue
        }
    }

    var resolvedPatternParams: [String: Float] {
        var result: [String: Float] = [:]
        for param in selectedPattern.parameters {
            result[param.id] = patternParams[param.id] ?? param.defaultValue
        }
        return result
    }

    // MARK: - Helpers

    /// Max dimension of the current mesh (for displacement scaling)
    private var meshMaxDimension: Float {
        if importedShape != nil {
            let size = baseMesh.sizeInMM
            return max(size.x, size.y, size.z)
        }
        return shapeMaxDimension
    }

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
