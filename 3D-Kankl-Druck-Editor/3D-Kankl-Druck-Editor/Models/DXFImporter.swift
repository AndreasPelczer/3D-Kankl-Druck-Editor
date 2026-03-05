//
//  DXFImporter.swift
//  3D-Kankl-Druck-Editor
//
//  Imports DXF files (AutoCAD exchange format). Extracts 3D geometry from:
//  - 3DFACE entities (triangles/quads with explicit vertices)
//  - POLYLINE/VERTEX with POLYFACE mesh flag (indexed face sets)
//  - LINE entities (ignored for mesh — no surface)
//
//  DXF is a tagged text format: pairs of (group code, value) on alternating lines.
//  Group codes define what the value means (10=X coord, 20=Y coord, etc.)
//

import Foundation
import simd

enum DXFImporter {

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
                ?? String(data: data, encoding: .ascii)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw FileImportError.fileNotReadable
        }

        // Parse DXF into group code pairs
        let pairs = parsePairs(text: text)

        // Extract triangles from ENTITIES section
        let triangles = extractTriangles(pairs: pairs)

        guard !triangles.isEmpty else {
            throw FileImportError.noTrianglesFound
        }

        return MeshData(triangles: triangles)
    }

    // MARK: - DXF Pair parsing

    private struct DXFPair {
        let code: Int
        let value: String
    }

    private static func parsePairs(text: String) -> [DXFPair] {
        let lines = text.components(separatedBy: .newlines)
        var pairs: [DXFPair] = []
        pairs.reserveCapacity(lines.count / 2)

        var i = 0
        while i + 1 < lines.count {
            let codeLine = lines[i].trimmingCharacters(in: .whitespaces)
            let valueLine = lines[i + 1].trimmingCharacters(in: .whitespaces)

            if let code = Int(codeLine) {
                pairs.append(DXFPair(code: code, value: valueLine))
            }
            i += 2
        }

        return pairs
    }

    // MARK: - Triangle extraction

    private static func extractTriangles(pairs: [DXFPair]) -> [Triangle] {
        var triangles: [Triangle] = []
        var inEntities = false
        var i = 0

        while i < pairs.count {
            let pair = pairs[i]

            // Track section
            if pair.code == 0 && pair.value == "SECTION" {
                if i + 1 < pairs.count && pairs[i + 1].code == 2 && pairs[i + 1].value == "ENTITIES" {
                    inEntities = true
                    i += 2
                    continue
                }
            }
            if pair.code == 0 && pair.value == "ENDSEC" {
                if inEntities { inEntities = false }
                i += 1
                continue
            }

            guard inEntities else { i += 1; continue }

            // Parse 3DFACE entity
            if pair.code == 0 && pair.value == "3DFACE" {
                i += 1
                let (face, newI) = parse3DFace(pairs: pairs, startIndex: i)
                i = newI
                triangles.append(contentsOf: face)
                continue
            }

            // Parse POLYLINE (polyface mesh)
            if pair.code == 0 && pair.value == "POLYLINE" {
                i += 1
                let (polyTris, newI) = parsePolyface(pairs: pairs, startIndex: i)
                i = newI
                triangles.append(contentsOf: polyTris)
                continue
            }

            i += 1
        }

        return triangles
    }

    // MARK: - 3DFACE parser

    /// 3DFACE has 4 corner points (group codes 10-13, 20-23, 30-33).
    /// If point 3 == point 4, it's a triangle; otherwise a quad (split into 2 tris).
    private static func parse3DFace(pairs: [DXFPair], startIndex: Int) -> ([Triangle], Int) {
        var x: [Float] = [0, 0, 0, 0]
        var y: [Float] = [0, 0, 0, 0]
        var z: [Float] = [0, 0, 0, 0]
        var i = startIndex

        while i < pairs.count {
            let p = pairs[i]
            // Stop at next entity
            if p.code == 0 { break }

            if let val = Float(p.value) {
                switch p.code {
                case 10: x[0] = val
                case 20: y[0] = val
                case 30: z[0] = val
                case 11: x[1] = val
                case 21: y[1] = val
                case 31: z[1] = val
                case 12: x[2] = val
                case 22: y[2] = val
                case 32: z[2] = val
                case 13: x[3] = val
                case 23: y[3] = val
                case 33: z[3] = val
                default: break
                }
            }
            i += 1
        }

        let v0 = SIMD3<Float>(x[0], y[0], z[0])
        let v1 = SIMD3<Float>(x[1], y[1], z[1])
        let v2 = SIMD3<Float>(x[2], y[2], z[2])
        let v3 = SIMD3<Float>(x[3], y[3], z[3])

        var result: [Triangle] = []

        let n0 = MeshGenerator.faceNormal(v0, v1, v2)
        result.append(Triangle(v0: v0, v1: v1, v2: v2, normal: n0))

        // If v3 != v2, it's a quad — add second triangle
        if simd_distance(v2, v3) > 0.0001 {
            let n1 = MeshGenerator.faceNormal(v0, v2, v3)
            result.append(Triangle(v0: v0, v1: v2, v2: v3, normal: n1))
        }

        return (result, i)
    }

    // MARK: - POLYLINE/POLYFACE parser

    /// Polyface mesh: POLYLINE with flag 64, followed by VERTEX entries.
    /// Vertices with flag 192 define face indices (group codes 71-74).
    /// Vertices with flag 64 define positions.
    private static func parsePolyface(pairs: [DXFPair], startIndex: Int) -> ([Triangle], Int) {
        var i = startIndex

        // Check polyline flags for polyface mesh (flag 64)
        var isPolyface = false
        while i < pairs.count {
            let p = pairs[i]
            if p.code == 0 { break } // next entity before we found flags
            if p.code == 70, let flags = Int(p.value) {
                isPolyface = (flags & 64) != 0
            }
            i += 1
        }

        guard isPolyface else { return ([], i) }

        // Collect vertices and faces
        var positions: [SIMD3<Float>] = []
        var faceIndices: [[Int]] = []

        while i < pairs.count {
            let p = pairs[i]

            if p.code == 0 && p.value == "SEQEND" {
                i += 1
                break
            }

            if p.code == 0 && p.value == "VERTEX" {
                i += 1
                var vx: Float = 0, vy: Float = 0, vz: Float = 0
                var flags: Int = 0
                var fi: [Int] = [0, 0, 0, 0]

                while i < pairs.count && pairs[i].code != 0 {
                    let vp = pairs[i]
                    if let val = Float(vp.value) {
                        switch vp.code {
                        case 10: vx = val
                        case 20: vy = val
                        case 30: vz = val
                        case 70: flags = Int(val)
                        case 71: fi[0] = Int(val)
                        case 72: fi[1] = Int(val)
                        case 73: fi[2] = Int(val)
                        case 74: fi[3] = Int(val)
                        default: break
                        }
                    }
                    i += 1
                }

                if (flags & 128) != 0 || (flags & 64) != 0 {
                    // Face vertex (flags 192 or 128 or 64): has face indices
                    if fi[0] != 0 && fi[1] != 0 && fi[2] != 0 {
                        faceIndices.append(fi)
                    }
                } else {
                    // Position vertex
                    positions.append(SIMD3(vx, vy, vz))
                }
                continue
            }

            i += 1
        }

        // Build triangles from face indices
        var triangles: [Triangle] = []
        for fi in faceIndices {
            // Indices are 1-based, negative means invisible edge
            let i0 = abs(fi[0]) - 1
            let i1 = abs(fi[1]) - 1
            let i2 = abs(fi[2]) - 1
            let i3 = abs(fi[3]) - 1

            guard i0 >= 0, i0 < positions.count,
                  i1 >= 0, i1 < positions.count,
                  i2 >= 0, i2 < positions.count else { continue }

            let v0 = positions[i0]
            let v1 = positions[i1]
            let v2 = positions[i2]

            let n = MeshGenerator.faceNormal(v0, v1, v2)
            triangles.append(Triangle(v0: v0, v1: v1, v2: v2, normal: n))

            // 4th index = quad
            if fi[3] != 0, i3 >= 0, i3 < positions.count {
                let v3 = positions[i3]
                let n2 = MeshGenerator.faceNormal(v0, v2, v3)
                triangles.append(Triangle(v0: v0, v1: v2, v2: v3, normal: n2))
            }
        }

        return (triangles, i)
    }
}
