//
//  MeshAnalyzer.swift
//  3D-Kankl-Druck-Editor
//
//  Analyzes a MeshData for common STL problems: non-manifold edges,
//  open edges (holes), flipped normals, floating components, degenerate triangles.
//

import Foundation
import simd

// MARK: - Analysis types

struct MeshIssue: Identifiable {
    let id = UUID()

    enum IssueType {
        case nonManifoldEdge
        case openEdge
        case flippedNormal
        case floatingComponent
        case degenerateTriangle
    }

    let type: IssueType
    let affectedTriangles: [Int]
    let description: String
}

struct MeshAnalysis {
    let issues: [MeshIssue]
    let isWatertight: Bool
    let componentCount: Int
    let isPrintable: Bool
    let openEdgeCount: Int
    let nonManifoldEdgeCount: Int
    let flippedNormalCount: Int
    let degenerateCount: Int
    let floatingComponentCount: Int

    var summary: String {
        isPrintable ? "Druckbereit" : "\(issues.count) Probleme gefunden"
    }
}

// MARK: - Edge key (sorted vertex pair for undirected edge lookup)

struct EdgeKey: Hashable {
    let a: SIMD3<Int32>
    let b: SIMD3<Int32>

    init(_ v0: SIMD3<Float>, _ v1: SIMD3<Float>) {
        let q0 = EdgeKey.quantize(v0)
        let q1 = EdgeKey.quantize(v1)
        // Sort so (A,B) == (B,A)
        if q0.x < q1.x || (q0.x == q1.x && q0.y < q1.y) || (q0.x == q1.x && q0.y == q1.y && q0.z < q1.z) {
            a = q0; b = q1
        } else {
            a = q1; b = q0
        }
    }

    static func quantize(_ v: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3(Int32(v.x * 10000), Int32(v.y * 10000), Int32(v.z * 10000))
    }
}

// MARK: - Directed edge (for winding order checks)

struct DirectedEdge: Hashable {
    let from: SIMD3<Int32>
    let to: SIMD3<Int32>

    init(_ v0: SIMD3<Float>, _ v1: SIMD3<Float>) {
        from = EdgeKey.quantize(v0)
        to = EdgeKey.quantize(v1)
    }
}

// MARK: - Analyzer

enum MeshAnalyzer {

    static func analyze(mesh: MeshData) -> MeshAnalysis {
        var issues: [MeshIssue] = []

        // 1. Find degenerate triangles
        let degenerates = findDegenerateTriangles(mesh: mesh)
        if !degenerates.isEmpty {
            issues.append(MeshIssue(
                type: .degenerateTriangle,
                affectedTriangles: degenerates,
                description: "\(degenerates.count) degenerierte Dreiecke (Fläche ≈ 0)"
            ))
        }

        // 2. Build edge manifest
        let edgeMap = buildEdgeManifest(mesh: mesh)

        // 3. Find open edges (boundary = hole)
        var openEdges: [EdgeKey] = []
        var openTriangles: Set<Int> = []
        var nonManifoldEdges: [EdgeKey] = []
        var nonManifoldTriangles: Set<Int> = []

        for (edge, triIndices) in edgeMap {
            if triIndices.count == 1 {
                openEdges.append(edge)
                openTriangles.formUnion(triIndices)
            } else if triIndices.count > 2 {
                nonManifoldEdges.append(edge)
                nonManifoldTriangles.formUnion(triIndices)
            }
        }

        if !openEdges.isEmpty {
            issues.append(MeshIssue(
                type: .openEdge,
                affectedTriangles: Array(openTriangles),
                description: "\(openEdges.count) offene Kanten — Löcher in der Oberfläche"
            ))
        }

        if !nonManifoldEdges.isEmpty {
            issues.append(MeshIssue(
                type: .nonManifoldEdge,
                affectedTriangles: Array(nonManifoldTriangles),
                description: "\(nonManifoldEdges.count) nicht-manifolde Kanten"
            ))
        }

        // 4. Check normals (consistent winding via directed edge pairing)
        let flipped = checkNormals(mesh: mesh, edgeMap: edgeMap)
        if !flipped.isEmpty {
            issues.append(MeshIssue(
                type: .flippedNormal,
                affectedTriangles: flipped,
                description: "\(flipped.count) Dreiecke zeigen nach innen statt nach außen"
            ))
        }

        // 5. Find connected components
        let components = findComponents(mesh: mesh)
        if components.count > 1 {
            // All components except the largest are "floating"
            let sorted = components.sorted { $0.count > $1.count }
            let floatingTris = sorted.dropFirst().flatMap { $0 }
            let floatingCount = sorted.count - 1
            issues.append(MeshIssue(
                type: .floatingComponent,
                affectedTriangles: floatingTris,
                description: "\(floatingCount) schwebende Teile ohne Verbindung zum Hauptkörper"
            ))
        }

        let isWatertight = openEdges.isEmpty && nonManifoldEdges.isEmpty
        let isPrintable = isWatertight && components.count <= 1 && flipped.isEmpty && degenerates.isEmpty

        return MeshAnalysis(
            issues: issues,
            isWatertight: isWatertight,
            componentCount: components.count,
            isPrintable: isPrintable,
            openEdgeCount: openEdges.count,
            nonManifoldEdgeCount: nonManifoldEdges.count,
            flippedNormalCount: flipped.count,
            degenerateCount: degenerates.count,
            floatingComponentCount: max(0, components.count - 1)
        )
    }

    // MARK: - Edge Manifest

    /// Maps each undirected edge to the list of triangle indices that share it.
    /// Manifold mesh: every edge appears exactly 2 times.
    static func buildEdgeManifest(mesh: MeshData) -> [EdgeKey: [Int]] {
        var map: [EdgeKey: [Int]] = [:]
        map.reserveCapacity(mesh.triangles.count * 3)

        for (i, tri) in mesh.triangles.enumerated() {
            let e0 = EdgeKey(tri.v0, tri.v1)
            let e1 = EdgeKey(tri.v1, tri.v2)
            let e2 = EdgeKey(tri.v2, tri.v0)
            map[e0, default: []].append(i)
            map[e1, default: []].append(i)
            map[e2, default: []].append(i)
        }

        return map
    }

    // MARK: - Connected Components (Union-Find)

    static func findComponents(mesh: MeshData) -> [[Int]] {
        let n = mesh.triangles.count
        guard n > 0 else { return [] }

        // Build vertex→triangles map
        var vertexToTris: [SIMD3<Int32>: [Int]] = [:]
        for (i, tri) in mesh.triangles.enumerated() {
            for v in [tri.v0, tri.v1, tri.v2] {
                let key = EdgeKey.quantize(v)
                vertexToTris[key, default: []].append(i)
            }
        }

        // Union-Find
        var parent = Array(0..<n)
        var rank = Array(repeating: 0, count: n)

        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            if rank[ra] < rank[rb] { parent[ra] = rb }
            else if rank[ra] > rank[rb] { parent[rb] = ra }
            else { parent[rb] = ra; rank[ra] += 1 }
        }

        // Union triangles sharing a vertex
        for (_, tris) in vertexToTris {
            guard let first = tris.first else { continue }
            for t in tris.dropFirst() {
                union(first, t)
            }
        }

        // Group by root
        var groups: [Int: [Int]] = [:]
        for i in 0..<n {
            groups[find(i), default: []].append(i)
        }

        return Array(groups.values)
    }

    // MARK: - Normal Consistency Check

    /// Checks winding consistency: for each manifold edge shared by 2 triangles,
    /// the directed edge should appear once in each direction. If both triangles
    /// traverse the edge in the same direction, one has a flipped normal.
    static func checkNormals(mesh: MeshData, edgeMap: [EdgeKey: [Int]]) -> [Int] {
        var directedEdgeUser: [DirectedEdge: Int] = [:]
        var flippedSet: Set<Int> = []

        for (i, tri) in mesh.triangles.enumerated() {
            let edges = [
                DirectedEdge(tri.v0, tri.v1),
                DirectedEdge(tri.v1, tri.v2),
                DirectedEdge(tri.v2, tri.v0),
            ]
            for de in edges {
                if let other = directedEdgeUser[de] {
                    // Same directed edge used by two triangles = inconsistent winding
                    // Mark the one with fewer neighbors as flipped
                    flippedSet.insert(i)
                    _ = other // the other triangle has correct winding (first one wins)
                }
                directedEdgeUser[de] = i
            }
        }

        return Array(flippedSet)
    }

    // MARK: - Degenerate Triangles

    static func findDegenerateTriangles(mesh: MeshData) -> [Int] {
        var result: [Int] = []
        let epsilon: Float = 1e-10

        for (i, tri) in mesh.triangles.enumerated() {
            let edge1 = tri.v1 - tri.v0
            let edge2 = tri.v2 - tri.v0
            let cross = simd_cross(edge1, edge2)
            let area = simd_length(cross) * 0.5

            if area < epsilon {
                result.append(i)
            }
        }

        return result
    }
}
