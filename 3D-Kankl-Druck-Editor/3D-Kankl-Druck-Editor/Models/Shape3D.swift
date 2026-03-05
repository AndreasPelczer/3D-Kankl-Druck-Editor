//
//  Shape3D.swift
//  3D-Kankl-Druck-Editor
//
//  Shape definitions and shared mesh generation for SceneKit preview + STL export.
//

import Foundation
import SceneKit

// MARK: - Shape Type

enum ShapeType: String, CaseIterable, Identifiable {
    case cube = "Würfel"
    case cylinder = "Zylinder"
    case sphere = "Kugel"

    var id: String { rawValue }
}

// MARK: - Triangle / MeshData

struct Triangle {
    var v0: SIMD3<Float>
    var v1: SIMD3<Float>
    var v2: SIMD3<Float>
    var normal: SIMD3<Float>
}

struct MeshData {
    var triangles: [Triangle]

    // Builds an SCNGeometry from the triangle array
    func toSCNGeometry() -> SCNGeometry {
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [Int32] = []

        for (i, tri) in triangles.enumerated() {
            vertices.append(SCNVector3(tri.v0.x, tri.v0.y, tri.v0.z))
            vertices.append(SCNVector3(tri.v1.x, tri.v1.y, tri.v1.z))
            vertices.append(SCNVector3(tri.v2.x, tri.v2.y, tri.v2.z))

            let n = SCNVector3(tri.normal.x, tri.normal.y, tri.normal.z)
            normals.append(n)
            normals.append(n)
            normals.append(n)

            let base = Int32(i * 3)
            indices.append(base)
            indices.append(base + 1)
            indices.append(base + 2)
        }

        let vertexSource = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)

        return SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
    }
}

// MARK: - Mesh Generators

enum MeshGenerator {

    // Compute face normal via cross product
    static func faceNormal(_ v0: SIMD3<Float>, _ v1: SIMD3<Float>, _ v2: SIMD3<Float>) -> SIMD3<Float> {
        let u = v1 - v0
        let w = v2 - v0
        let n = simd_cross(u, w)
        let len = simd_length(n)
        return len > 0 ? n / len : SIMD3<Float>(0, 1, 0)
    }

    // MARK: Cube / Quader

    static func cube(width: Float, height: Float, depth: Float) -> MeshData {
        let w = width / 2, h = height / 2, d = depth / 2

        // 8 corner vertices
        let v: [SIMD3<Float>] = [
            SIMD3(-w, -h,  d), // 0: front-bottom-left
            SIMD3( w, -h,  d), // 1: front-bottom-right
            SIMD3( w,  h,  d), // 2: front-top-right
            SIMD3(-w,  h,  d), // 3: front-top-left
            SIMD3(-w, -h, -d), // 4: back-bottom-left
            SIMD3( w, -h, -d), // 5: back-bottom-right
            SIMD3( w,  h, -d), // 6: back-top-right
            SIMD3(-w,  h, -d), // 7: back-top-left
        ]

        // Each face = 2 triangles (CCW winding for outward normals)
        let faceIndices: [(Int, Int, Int, Int)] = [
            (0, 1, 2, 3), // front  +Z
            (5, 4, 7, 6), // back   -Z
            (3, 2, 6, 7), // top    +Y
            (4, 5, 1, 0), // bottom -Y
            (1, 5, 6, 2), // right  +X
            (4, 0, 3, 7), // left   -X
        ]

        var triangles: [Triangle] = []
        for (a, b, c, d) in faceIndices {
            let n = faceNormal(v[a], v[b], v[c])
            triangles.append(Triangle(v0: v[a], v1: v[b], v2: v[c], normal: n))
            triangles.append(Triangle(v0: v[a], v1: v[c], v2: v[d], normal: n))
        }
        return MeshData(triangles: triangles)
    }

    // MARK: Cylinder

    static func cylinder(radius: Float, height: Float, segments: Int) -> MeshData {
        let seg = max(segments, 3)
        let halfH = height / 2
        var triangles: [Triangle] = []

        for i in 0..<seg {
            let angle0 = Float(i) / Float(seg) * 2 * .pi
            let angle1 = Float(i + 1) / Float(seg) * 2 * .pi

            let cos0 = cos(angle0), sin0 = sin(angle0)
            let cos1 = cos(angle1), sin1 = sin(angle1)

            // Bottom circle vertices (Y = -halfH), Top circle vertices (Y = +halfH)
            let b0 = SIMD3<Float>(radius * cos0, -halfH, radius * sin0)
            let b1 = SIMD3<Float>(radius * cos1, -halfH, radius * sin1)
            let t0 = SIMD3<Float>(radius * cos0,  halfH, radius * sin0)
            let t1 = SIMD3<Float>(radius * cos1,  halfH, radius * sin1)

            // Side wall (2 triangles per segment)
            let sn0 = SIMD3<Float>(cos0, 0, sin0)
            let sn1 = SIMD3<Float>(cos1, 0, sin1)
            // Average normal for the quad approximation
            let sideN = simd_normalize((sn0 + sn1) / 2)

            triangles.append(Triangle(v0: b0, v1: b1, v2: t1, normal: sideN))
            triangles.append(Triangle(v0: b0, v1: t1, v2: t0, normal: sideN))

            // Top cap (fan from center)
            let topCenter = SIMD3<Float>(0, halfH, 0)
            let topN = SIMD3<Float>(0, 1, 0)
            triangles.append(Triangle(v0: topCenter, v1: t0, v2: t1, normal: topN))

            // Bottom cap (fan from center, reversed winding)
            let botCenter = SIMD3<Float>(0, -halfH, 0)
            let botN = SIMD3<Float>(0, -1, 0)
            triangles.append(Triangle(v0: botCenter, v1: b1, v2: b0, normal: botN))
        }

        return MeshData(triangles: triangles)
    }

    // MARK: Sphere (UV sphere)

    static func sphere(radius: Float, segments: Int) -> MeshData {
        let seg = max(segments, 4)
        let rings = seg / 2 // latitude divisions
        var triangles: [Triangle] = []

        for ring in 0..<rings {
            let theta0 = Float(ring) / Float(rings) * .pi
            let theta1 = Float(ring + 1) / Float(rings) * .pi

            for s in 0..<seg {
                let phi0 = Float(s) / Float(seg) * 2 * .pi
                let phi1 = Float(s + 1) / Float(seg) * 2 * .pi

                // Spherical to cartesian
                func point(_ theta: Float, _ phi: Float) -> SIMD3<Float> {
                    SIMD3(
                        radius * sin(theta) * cos(phi),
                        radius * cos(theta),
                        radius * sin(theta) * sin(phi)
                    )
                }

                let p00 = point(theta0, phi0)
                let p01 = point(theta0, phi1)
                let p10 = point(theta1, phi0)
                let p11 = point(theta1, phi1)

                // Normals point outward (= normalized position for unit sphere)
                if ring == 0 {
                    // Top cap: single triangle
                    let n = faceNormal(p00, p10, p11)
                    triangles.append(Triangle(v0: p00, v1: p10, v2: p11, normal: n))
                } else if ring == rings - 1 {
                    // Bottom cap: single triangle
                    let n = faceNormal(p00, p01, p10)
                    triangles.append(Triangle(v0: p00, v1: p01, v2: p10, normal: n))
                } else {
                    let n1 = faceNormal(p00, p10, p11)
                    triangles.append(Triangle(v0: p00, v1: p10, v2: p11, normal: n1))
                    let n2 = faceNormal(p00, p11, p01)
                    triangles.append(Triangle(v0: p00, v1: p11, v2: p01, normal: n2))
                }
            }
        }

        return MeshData(triangles: triangles)
    }
}
