//
//  OBJImporter.swift
//  3D-Kankl-Druck-Editor
//
//  Imports Wavefront OBJ files. Parses vertices (v), normals (vn), and faces (f).
//  Supports triangular and quad faces (quads are split into 2 triangles).
//  Face indices can be: f v, f v/vt, f v/vt/vn, f v//vn
//

import Foundation
import simd

enum OBJImporter {

    static func load(from url: URL) throws -> MeshData {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            throw FileImportError.fileNotReadable
        }
        guard !data.isEmpty else {
            throw FileImportError.emptyFile
        }

        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii) else {
            throw FileImportError.fileNotReadable
        }

        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var triangles: [Triangle] = []

        let lines = text.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
            guard let keyword = parts.first else { continue }

            switch keyword {
            case "v":
                // Vertex: v x y z
                if parts.count >= 4,
                   let x = Float(parts[1]),
                   let y = Float(parts[2]),
                   let z = Float(parts[3]) {
                    vertices.append(SIMD3(x, y, z))
                }

            case "vn":
                // Normal: vn x y z
                if parts.count >= 4,
                   let x = Float(parts[1]),
                   let y = Float(parts[2]),
                   let z = Float(parts[3]) {
                    normals.append(SIMD3(x, y, z))
                }

            case "f":
                // Face: f v1 v2 v3 [v4 ...]
                // Each vertex ref can be: v, v/vt, v/vt/vn, v//vn
                let faceVerts = parts.dropFirst().compactMap { parseFaceVertex(String($0), vertices: vertices, normals: normals) }
                guard faceVerts.count >= 3 else { continue }

                // Fan triangulation for polygons with 3+ vertices
                let anchor = faceVerts[0]
                for i in 1..<(faceVerts.count - 1) {
                    let b = faceVerts[i]
                    let c = faceVerts[i + 1]

                    // Use provided normals or compute from vertices
                    let normal: SIMD3<Float>
                    if let na = anchor.normal {
                        normal = na
                    } else {
                        normal = MeshGenerator.faceNormal(anchor.position, b.position, c.position)
                    }

                    triangles.append(Triangle(
                        v0: anchor.position,
                        v1: b.position,
                        v2: c.position,
                        normal: normal
                    ))
                }

            default:
                break // Skip mtllib, usemtl, s, g, o, vt, etc.
            }
        }

        guard !triangles.isEmpty else {
            throw FileImportError.noTrianglesFound
        }

        return MeshData(triangles: triangles)
    }

    // MARK: - Face vertex parsing

    private struct FaceVertex {
        let position: SIMD3<Float>
        let normal: SIMD3<Float>?
    }

    /// Parses a face vertex reference like "1", "1/2", "1/2/3", or "1//3"
    private static func parseFaceVertex(_ str: String, vertices: [SIMD3<Float>], normals: [SIMD3<Float>]) -> FaceVertex? {
        let components = str.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = components.first, let vIdx = Int(first) else { return nil }

        // OBJ indices are 1-based, can be negative (relative)
        let resolvedV = resolveIndex(vIdx, count: vertices.count)
        guard resolvedV >= 0, resolvedV < vertices.count else { return nil }

        var normal: SIMD3<Float>? = nil
        // Check for normal index (3rd component: v/vt/vn or v//vn)
        if components.count >= 3, let nIdx = Int(components[2]) {
            let resolvedN = resolveIndex(nIdx, count: normals.count)
            if resolvedN >= 0, resolvedN < normals.count {
                normal = normals[resolvedN]
            }
        }

        return FaceVertex(position: vertices[resolvedV], normal: normal)
    }

    /// OBJ uses 1-based indices. Negative means relative to end.
    private static func resolveIndex(_ idx: Int, count: Int) -> Int {
        if idx > 0 { return idx - 1 }
        if idx < 0 { return count + idx }
        return -1 // 0 is invalid in OBJ
    }
}
