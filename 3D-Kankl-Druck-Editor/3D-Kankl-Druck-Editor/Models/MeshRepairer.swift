//
//  MeshRepairer.swift
//  3D-Kankl-Druck-Editor
//
//  Repairs common STL mesh problems: degenerate triangles, floating components,
//  flipped normals, open edges (holes). Each repair step is independent and logged.
//

import Foundation
import simd

enum MeshRepairer {

    /// Repairs all detected issues in sequence. Returns repaired mesh + log.
    static func repair(mesh: MeshData, analysis: MeshAnalysis) -> (mesh: MeshData, log: [String]) {
        var current = mesh
        var log: [String] = []
        let beforeCount = mesh.triangles.count

        // 1. Remove degenerate triangles
        if analysis.degenerateCount > 0 {
            let before = current.triangles.count
            current = removeDegenerateTriangles(mesh: current)
            let removed = before - current.triangles.count
            if removed > 0 {
                log.append("\(removed) degenerierte Dreiecke entfernt")
            }
        }

        // 2. Remove floating components (keep largest)
        if analysis.floatingComponentCount > 0 {
            let before = current.triangles.count
            current = removeFloatingComponents(mesh: current)
            let removed = before - current.triangles.count
            if removed > 0 {
                log.append("\(analysis.floatingComponentCount) schwebende Teile entfernt (\(removed) Dreiecke)")
            }
        }

        // 3. Fix normals
        if analysis.flippedNormalCount > 0 {
            let result = fixNormals(mesh: current)
            current = result.mesh
            if result.fixedCount > 0 {
                log.append("\(result.fixedCount) Dreiecke mit falscher Normale korrigiert")
            }
        }

        // 4. Close holes
        if analysis.openEdgeCount > 0 {
            let result = closeHoles(mesh: current)
            current = result.mesh
            if result.holesClosed > 0 {
                log.append("\(result.holesClosed) Löcher geschlossen (\(result.trianglesAdded) Dreiecke hinzugefügt)")
            }
        }

        // 5. Recalculate all normals
        current = recalculateNormals(mesh: current)

        let afterCount = current.triangles.count
        if beforeCount != afterCount {
            log.append("Vorher: \(beforeCount) Dreiecke — Nachher: \(afterCount) Dreiecke")
        }

        return (mesh: current, log: log)
    }

    // MARK: - 1. Remove Degenerate Triangles

    static func removeDegenerateTriangles(mesh: MeshData) -> MeshData {
        let epsilon: Float = 1e-10
        let filtered = mesh.triangles.filter { tri in
            let edge1 = tri.v1 - tri.v0
            let edge2 = tri.v2 - tri.v0
            let area = simd_length(simd_cross(edge1, edge2)) * 0.5
            return area >= epsilon
        }
        return MeshData(triangles: filtered)
    }

    // MARK: - 2. Remove Floating Components

    /// Keeps only the largest connected component.
    static func removeFloatingComponents(mesh: MeshData) -> MeshData {
        let components = MeshAnalyzer.findComponents(mesh: mesh)
        guard components.count > 1 else { return mesh }

        // Find largest component
        let largest = components.max(by: { $0.count < $1.count })!
        let keepSet = Set(largest)

        let filtered = mesh.triangles.enumerated()
            .filter { keepSet.contains($0.offset) }
            .map { $0.element }

        return MeshData(triangles: filtered)
    }

    // MARK: - 3. Fix Normals

    /// Uses winding consistency to fix flipped normals.
    /// Strategy: BFS/flood-fill from the triangle whose centroid is most "outside"
    /// (highest X coordinate), propagating consistent winding to neighbors.
    static func fixNormals(mesh: MeshData) -> (mesh: MeshData, fixedCount: Int) {
        let n = mesh.triangles.count
        guard n > 0 else { return (mesh: mesh, fixedCount: 0) }

        // Build adjacency: for each edge, which triangles share it
        let edgeMap = MeshAnalyzer.buildEdgeManifest(mesh: mesh)

        // Build triangle adjacency
        var adjacency: [[Int]] = Array(repeating: [], count: n)
        for (_, tris) in edgeMap where tris.count == 2 {
            adjacency[tris[0]].append(tris[1])
            adjacency[tris[1]].append(tris[0])
        }

        // Find seed triangle: the one with centroid having highest X value
        // (likely on the outside of the mesh)
        var seedIdx = 0
        var maxX: Float = -.infinity
        for (i, tri) in mesh.triangles.enumerated() {
            let centroid = (tri.v0 + tri.v1 + tri.v2) / 3.0
            if centroid.x > maxX {
                maxX = centroid.x
                seedIdx = i
            }
        }

        // Determine if seed's normal points outward (away from mesh center)
        let center = mesh.center
        let seedTri = mesh.triangles[seedIdx]
        let seedCentroid = (seedTri.v0 + seedTri.v1 + seedTri.v2) / 3.0
        let outwardDir = simd_normalize(seedCentroid - center)
        let seedNormal = MeshGenerator.faceNormal(seedTri.v0, seedTri.v1, seedTri.v2)

        // Seed winding: if normal points away from center, current winding is correct
        var shouldFlip = Array(repeating: false, count: n)
        if simd_dot(seedNormal, outwardDir) < 0 {
            shouldFlip[seedIdx] = true
        }

        // BFS propagation
        var visited = Array(repeating: false, count: n)
        visited[seedIdx] = true
        var queue = [seedIdx]
        var queueIdx = 0

        while queueIdx < queue.count {
            let current = queue[queueIdx]
            queueIdx += 1
            let currentTri = mesh.triangles[current]
            let currentFlipped = shouldFlip[current]

            // Get directed edges of current triangle (after potential flip)
            let currentEdges: [(SIMD3<Float>, SIMD3<Float>)]
            if currentFlipped {
                currentEdges = [(currentTri.v0, currentTri.v2), (currentTri.v2, currentTri.v1), (currentTri.v1, currentTri.v0)]
            } else {
                currentEdges = [(currentTri.v0, currentTri.v1), (currentTri.v1, currentTri.v2), (currentTri.v2, currentTri.v0)]
            }

            for neighbor in adjacency[current] {
                guard !visited[neighbor] else { continue }
                visited[neighbor] = true

                let neighborTri = mesh.triangles[neighbor]

                // Find the shared edge between current and neighbor
                let neighborEdges = [(neighborTri.v0, neighborTri.v1), (neighborTri.v1, neighborTri.v2), (neighborTri.v2, neighborTri.v0)]

                var needsFlip = false
                for (ca, cb) in currentEdges {
                    let cEdge = EdgeKey(ca, cb)
                    for (na, nb) in neighborEdges {
                        let nEdge = EdgeKey(na, nb)
                        if cEdge == nEdge {
                            // Consistent winding: neighbor should traverse edge in opposite direction
                            let cDir = DirectedEdge(ca, cb)
                            let nDir = DirectedEdge(na, nb)
                            // If same direction → neighbor needs flip
                            if cDir == nDir {
                                needsFlip = true
                            }
                            break
                        }
                    }
                    if needsFlip { break }
                }

                shouldFlip[neighbor] = needsFlip
                queue.append(neighbor)
            }
        }

        // Apply flips
        var fixedCount = 0
        var newTriangles = mesh.triangles

        for i in 0..<n {
            if shouldFlip[i] {
                let tri = newTriangles[i]
                // Swap v1 and v2 to flip winding (and thus normal direction)
                let newNormal = MeshGenerator.faceNormal(tri.v0, tri.v2, tri.v1)
                newTriangles[i] = Triangle(v0: tri.v0, v1: tri.v2, v2: tri.v1, normal: newNormal)
                fixedCount += 1
            }
        }

        return (mesh: MeshData(triangles: newTriangles), fixedCount: fixedCount)
    }

    // MARK: - 4. Close Holes

    /// Finds open edge loops and fills them with fan triangulation.
    static func closeHoles(mesh: MeshData) -> (mesh: MeshData, holesClosed: Int, trianglesAdded: Int) {
        // Find open edges (edges with only 1 triangle)
        let edgeMap = MeshAnalyzer.buildEdgeManifest(mesh: mesh)

        // Collect open edges as directed edges (following the triangle's winding)
        var openDirectedEdges: [(SIMD3<Float>, SIMD3<Float>)] = []

        for (_, triIndices) in edgeMap where triIndices.count == 1 {
            let triIdx = triIndices[0]
            let tri = mesh.triangles[triIdx]
            let triEdges = [(tri.v0, tri.v1), (tri.v1, tri.v2), (tri.v2, tri.v0)]

            for (a, b) in triEdges {
                let ek = EdgeKey(a, b)
                if let tris = edgeMap[ek], tris.count == 1 {
                    // This is an open edge — store with reversed direction
                    // (hole fill triangles should have opposite winding to close the gap)
                    openDirectedEdges.append((b, a))
                }
            }
        }

        guard !openDirectedEdges.isEmpty else {
            return (mesh: mesh, holesClosed: 0, trianglesAdded: 0)
        }

        // Build adjacency map: from-vertex → (to-vertex, edge)
        var adjacency: [SIMD3<Int32>: [(SIMD3<Float>, SIMD3<Float>)]] = [:]
        for (a, b) in openDirectedEdges {
            let key = EdgeKey.quantize(a)
            adjacency[key, default: []].append((a, b))
        }

        // Trace edge loops
        var usedEdges: Set<DirectedEdge> = []
        var loops: [[SIMD3<Float>]] = []

        for (startA, startB) in openDirectedEdges {
            let de = DirectedEdge(startA, startB)
            guard !usedEdges.contains(de) else { continue }

            var loop: [SIMD3<Float>] = [startA]
            var current = startB
            var loopDE = de
            usedEdges.insert(loopDE)

            var safety = 0
            while safety < 10000 {
                safety += 1
                loop.append(current)

                // Check if we closed the loop
                let currentQ = EdgeKey.quantize(current)
                let startQ = EdgeKey.quantize(startA)
                if currentQ == startQ && loop.count > 2 {
                    loop.removeLast() // remove duplicate closing vertex
                    break
                }

                // Find next edge from current
                let key = EdgeKey.quantize(current)
                guard let candidates = adjacency[key] else { break }

                var foundNext = false
                for (ca, cb) in candidates {
                    let candidateDE = DirectedEdge(ca, cb)
                    if !usedEdges.contains(candidateDE) {
                        usedEdges.insert(candidateDE)
                        current = cb
                        loopDE = candidateDE
                        foundNext = true
                        break
                    }
                }

                if !foundNext { break }
            }

            if loop.count >= 3 {
                loops.append(loop)
            }
        }

        // Triangulate each loop using fan triangulation from centroid
        var newTriangles = mesh.triangles
        var totalAdded = 0

        for loop in loops {
            // Compute centroid
            var centroid = SIMD3<Float>.zero
            for v in loop { centroid += v }
            centroid /= Float(loop.count)

            // Create fan triangles
            for i in 0..<loop.count {
                let a = loop[i]
                let b = loop[(i + 1) % loop.count]
                let normal = MeshGenerator.faceNormal(centroid, a, b)
                newTriangles.append(Triangle(v0: centroid, v1: a, v2: b, normal: normal))
                totalAdded += 1
            }
        }

        return (mesh: MeshData(triangles: newTriangles), holesClosed: loops.count, trianglesAdded: totalAdded)
    }

    // MARK: - 5. Recalculate Normals

    /// Recomputes face normals from vertex winding order.
    static func recalculateNormals(mesh: MeshData) -> MeshData {
        MeshData(triangles: mesh.triangles.map { tri in
            let normal = MeshGenerator.faceNormal(tri.v0, tri.v1, tri.v2)
            return Triangle(v0: tri.v0, v1: tri.v1, v2: tri.v2, normal: normal)
        })
    }
}
