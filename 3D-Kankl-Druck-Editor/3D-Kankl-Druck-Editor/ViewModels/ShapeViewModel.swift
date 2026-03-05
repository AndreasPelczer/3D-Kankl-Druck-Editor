//
//  ShapeViewModel.swift
//  3D-Kankl-Druck-Editor
//
//  Central ViewModel: holds shape parameters, generates mesh, triggers export.
//

import Foundation
import SwiftUI
import SceneKit

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

    // MARK: - Export state

    var exportFileURL: URL?
    var showShareSheet = false

    // MARK: - Mesh generation

    var currentMesh: MeshData {
        switch selectedShape {
        case .cube:
            MeshGenerator.cube(width: cubeWidth, height: cubeHeight, depth: cubeDepth)
        case .cylinder:
            MeshGenerator.cylinder(radius: cylinderRadius, height: cylinderHeight, segments: cylinderSegments)
        case .sphere:
            MeshGenerator.sphere(radius: sphereRadius, segments: sphereSegments)
        }
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
        let filename = "\(selectedShape.rawValue)_\(dateString).stl"

        exportFileURL = STLExporter.writeToTempFile(data: data, filename: filename)
        showShareSheet = true
    }
}
