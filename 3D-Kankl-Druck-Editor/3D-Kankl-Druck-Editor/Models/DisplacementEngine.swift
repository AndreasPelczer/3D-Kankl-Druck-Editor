//
//  DisplacementEngine.swift
//  3D-Kankl-Druck-Editor
//
//  Displaces mesh vertices along their normals based on surface patterns.
//  Includes mesh subdivision (needed for low-poly shapes like cubes) and
//  a full 3D Perlin Noise implementation.
//

import Foundation
import simd

// MARK: - Public API

enum DisplacementEngine {

    /// Target triangle count after subdivision. Balances detail vs. performance.
    /// ~3000 triangles renders smoothly on any iOS device.
    static let targetTriangleCount = 3000

    /// Compute how many subdivision levels are needed to reach the target triangle count.
    /// Each level multiplies triangles by 4.
    static func adaptiveSubdivisionLevel(baseTriangleCount: Int, target: Int = targetTriangleCount) -> Int {
        guard baseTriangleCount > 0 else { return 0 }
        var count = baseTriangleCount
        var level = 0
        while count * 4 <= target {
            count *= 4
            level += 1
        }
        return level
    }

    /// Apply a surface pattern to a mesh. Returns an unmodified copy for .smooth.
    static func apply(
        pattern: SurfacePattern,
        to mesh: MeshData,
        intensity: Float,
        scale: Float,
        parameters: [String: Float],
        subdivisions: Int? = nil
    ) -> MeshData {
        guard pattern != .smooth else { return mesh }

        // Use adaptive subdivision unless explicitly overridden
        let levels = subdivisions ?? adaptiveSubdivisionLevel(baseTriangleCount: mesh.triangles.count)

        // Subdivide so there are enough vertices for visible displacement
        var subdividedMesh = mesh
        for _ in 0..<levels {
            subdividedMesh = subdivide(subdividedMesh)
        }

        // Compute smooth vertex normals for displacement direction
        let vertexNormals = computeVertexNormals(subdividedMesh)

        var newTriangles: [Triangle] = []
        for (triIndex, tri) in subdividedMesh.triangles.enumerated() {
            let normals = vertexNormals[triIndex]

            let d0 = displacementValue(pattern: pattern, position: tri.v0, scale: scale, parameters: parameters)
            let d1 = displacementValue(pattern: pattern, position: tri.v1, scale: scale, parameters: parameters)
            let d2 = displacementValue(pattern: pattern, position: tri.v2, scale: scale, parameters: parameters)

            let nv0 = tri.v0 + normals.0 * d0 * intensity
            let nv1 = tri.v1 + normals.1 * d1 * intensity
            let nv2 = tri.v2 + normals.2 * d2 * intensity

            // Recalculate face normal after displacement
            let newNormal = MeshGenerator.faceNormal(nv0, nv1, nv2)
            newTriangles.append(Triangle(v0: nv0, v1: nv1, v2: nv2, normal: newNormal))
        }

        return MeshData(triangles: newTriangles)
    }

    // MARK: - Displacement per pattern

    /// Returns a displacement value in range ~[-1, 1] for a given world position.
    private static func displacementValue(
        pattern: SurfacePattern,
        position: SIMD3<Float>,
        scale: Float,
        parameters: [String: Float]
    ) -> Float {
        switch pattern {
        case .smooth:
            return 0

        case .scales:
            return scalesDisplacement(position: position, scale: scale, parameters: parameters)

        case .snakeSkin:
            return snakeSkinDisplacement(position: position, scale: scale, parameters: parameters)

        case .crumpled:
            return crumpledDisplacement(position: position, scale: scale, parameters: parameters)

        case .ribbed:
            return ribbedDisplacement(position: position, scale: scale, parameters: parameters)
        }
    }

    // MARK: - Schuppen (Scales)

    private static func scalesDisplacement(
        position: SIMD3<Float>,
        scale: Float,
        parameters: [String: Float]
    ) -> Float {
        let overlap = parameters["overlap"] ?? 0.5
        let rows = parameters["rows"] ?? 12

        // Project onto a 2D surface coordinate using dominant-axis planar projection
        let uv = surfaceUV(position)
        let freq = rows / scale

        // Offset every other row by half (brick pattern)
        var u = uv.x * freq
        let v = uv.y * freq
        let row = floor(v)
        if Int(row) & 1 == 1 {
            u += 0.5
        }

        // Distance to nearest grid center
        let cu = floor(u) + 0.5
        let cv = floor(v) + 0.5
        let dist = sqrt((u - cu) * (u - cu) + (v - cv) * (v - cv))

        // Scale radius with overlap: higher overlap = larger radius = more overlap
        let radius = 0.3 + overlap * 0.5

        if dist < radius {
            // Smooth bump (cosine falloff)
            return cos(dist / radius * .pi / 2)
        }
        return -0.2 // slight indentation between scales
    }

    // MARK: - Schlangenhaut (Snake Skin)

    private static func snakeSkinDisplacement(
        position: SIMD3<Float>,
        scale: Float,
        parameters: [String: Float]
    ) -> Float {
        let jitter = parameters["jitter"] ?? 0.3
        let cellSize = parameters["cellSize"] ?? 6

        let freq = cellSize / scale
        let uv = surfaceUV(position)

        // Diamond grid (45° rotated square grid)
        let ru = (uv.x + uv.y) * freq * 0.7071 // 1/sqrt(2)
        let rv = (uv.x - uv.y) * freq * 0.7071

        // Find nearest cell center with pseudo-random jitter
        let ci = floor(ru) + 0.5
        let cj = floor(rv) + 0.5

        var minDist: Float = 10.0

        // Check 3x3 neighborhood for closest cell center
        for di in -1...1 {
            for dj in -1...1 {
                let ni = ci + Float(di)
                let nj = cj + Float(dj)

                // Deterministic pseudo-random offset per cell
                let jx = hash2D(ni, nj) * jitter
                let jy = hash2D(ni + 31.7, nj + 17.3) * jitter

                let dx = ru - (ni + jx)
                let dy = rv - (nj + jy)
                let dist = sqrt(dx * dx + dy * dy)
                minDist = min(minDist, dist)
            }
        }

        // Raised at cell centers, lowered at edges (ridge effect)
        let edge = smoothstep(0.1, 0.5, minDist)
        return (1.0 - edge) * 0.8 - 0.1
    }

    // MARK: - Zerknülltes Papier (Crumpled Paper)

    private static func crumpledDisplacement(
        position: SIMD3<Float>,
        scale: Float,
        parameters: [String: Float]
    ) -> Float {
        let octaves = Int(parameters["octaves"] ?? 5)
        let persistence = parameters["persistence"] ?? 0.5

        let p = position / scale
        let lacunarity: Float = 2.0
        var amplitude: Float = 1.0
        var frequency: Float = 1.0
        var total: Float = 0
        var maxAmplitude: Float = 0

        for _ in 0..<octaves {
            total += PerlinNoise.noise3D(p.x * frequency, p.y * frequency, p.z * frequency) * amplitude
            maxAmplitude += amplitude
            amplitude *= persistence
            frequency *= lacunarity
        }

        // Normalize to [-1, 1] and add crumple character (sharper creases)
        let normalized = total / maxAmplitude
        // Fold the noise to create crease-like features
        return abs(normalized) * 2.0 - 0.5
    }

    // MARK: - Riffel (Ribbed)

    private static func ribbedDisplacement(
        position: SIMD3<Float>,
        scale: Float,
        parameters: [String: Float]
    ) -> Float {
        let spacing = parameters["spacing"] ?? 3
        let sharpness = parameters["sharpness"] ?? 0.5

        let frequency = .pi / (spacing * scale * 0.1)
        let raw = sin(position.y * frequency)

        // Sharpness: pow compresses peaks and widens valleys
        let sign: Float = raw >= 0 ? 1 : -1
        let expo = 1.0 + (1.0 - sharpness) * 3.0 // range 1..4
        return sign * pow(abs(raw), expo)
    }

    // MARK: - Helpers

    /// Projects a 3D position onto a 2D UV using the dominant normal direction.
    /// Works for any convex shape without explicit UV mapping.
    private static func surfaceUV(_ p: SIMD3<Float>) -> SIMD2<Float> {
        let ax = abs(p.x), ay = abs(p.y), az = abs(p.z)
        if ax >= ay && ax >= az {
            return SIMD2(p.y, p.z) // YZ plane
        } else if ay >= az {
            return SIMD2(p.x, p.z) // XZ plane
        } else {
            return SIMD2(p.x, p.y) // XY plane
        }
    }

    /// Simple deterministic hash returning value in [-1, 1]
    private static func hash2D(_ x: Float, _ y: Float) -> Float {
        let n = sin(x * 127.1 + y * 311.7) * 43758.5453
        return n - floor(n)  // fract → [0,1]
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    // MARK: - Mesh Subdivision

    /// Subdivide each triangle into 4 smaller triangles (midpoint subdivision).
    static func subdivide(_ mesh: MeshData) -> MeshData {
        var newTriangles: [Triangle] = []
        newTriangles.reserveCapacity(mesh.triangles.count * 4)

        for tri in mesh.triangles {
            let m01 = (tri.v0 + tri.v1) * 0.5
            let m12 = (tri.v1 + tri.v2) * 0.5
            let m02 = (tri.v0 + tri.v2) * 0.5

            let n0 = MeshGenerator.faceNormal(tri.v0, m01, m02)
            let n1 = MeshGenerator.faceNormal(m01, tri.v1, m12)
            let n2 = MeshGenerator.faceNormal(m02, m12, tri.v2)
            let n3 = MeshGenerator.faceNormal(m01, m12, m02)

            newTriangles.append(Triangle(v0: tri.v0, v1: m01, v2: m02, normal: n0))
            newTriangles.append(Triangle(v0: m01, v1: tri.v1, v2: m12, normal: n1))
            newTriangles.append(Triangle(v0: m02, v1: m12, v2: tri.v2, normal: n2))
            newTriangles.append(Triangle(v0: m01, v1: m12, v2: m02, normal: n3))
        }

        return MeshData(triangles: newTriangles)
    }

    // MARK: - Vertex Normal Computation

    /// Returns per-triangle vertex normals (smoothed by averaging adjacent face normals).
    /// Each entry is a tuple of 3 normals for (v0, v1, v2) of that triangle.
    private static func computeVertexNormals(_ mesh: MeshData) -> [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] {
        // Hash vertex positions to accumulate normals. We quantize to avoid float precision issues.
        var normalAccum: [SIMD3<Int32>: SIMD3<Float>] = [:]

        func quantize(_ v: SIMD3<Float>) -> SIMD3<Int32> {
            // Quantize to ~0.001 precision
            SIMD3(Int32(v.x * 1000), Int32(v.y * 1000), Int32(v.z * 1000))
        }

        // First pass: accumulate face normals per vertex position
        for tri in mesh.triangles {
            let fn = MeshGenerator.faceNormal(tri.v0, tri.v1, tri.v2)
            for v in [tri.v0, tri.v1, tri.v2] {
                let key = quantize(v)
                normalAccum[key, default: .zero] += fn
            }
        }

        // Second pass: look up averaged normal per vertex
        return mesh.triangles.map { tri in
            let n0 = simd_normalize(normalAccum[quantize(tri.v0)] ?? tri.normal)
            let n1 = simd_normalize(normalAccum[quantize(tri.v1)] ?? tri.normal)
            let n2 = simd_normalize(normalAccum[quantize(tri.v2)] ?? tri.normal)
            return (n0, n1, n2)
        }
    }
}

// MARK: - 3D Perlin Noise (Gradient Noise)

/// Classic Perlin noise with gradient vectors and fade/lerp interpolation.
/// Used for the "crumpled paper" pattern — produces natural, organic displacement.
enum PerlinNoise {

    // Ken Perlin's improved permutation table (doubled to avoid index wrapping)
    private static let perm: [Int] = {
        let base: [Int] = [
            151,160,137,91,90,15,131,13,201,95,96,53,194,233,7,225,
            140,36,103,30,69,142,8,99,37,240,21,10,23,190,6,148,
            247,120,234,75,0,26,197,62,94,252,219,203,117,35,11,32,
            57,177,33,88,237,149,56,87,174,20,125,136,171,168,68,175,
            74,165,71,134,139,48,27,166,77,146,158,231,83,111,229,122,
            60,211,133,230,220,105,92,41,55,46,245,40,244,102,143,54,
            65,25,63,161,1,216,80,73,209,76,132,187,208,89,18,169,
            200,196,135,130,116,188,159,86,164,100,109,198,173,186,3,64,
            52,217,226,250,124,123,5,202,38,147,118,126,255,82,85,212,
            207,206,59,227,47,16,58,17,182,189,28,42,223,183,170,213,
            119,248,152,2,44,154,163,70,221,153,101,155,167,43,172,9,
            129,22,39,253,19,98,108,110,79,113,224,232,178,185,112,104,
            218,246,97,228,251,34,242,193,238,210,144,12,191,179,162,241,
            81,51,145,235,249,14,239,107,49,192,214,31,181,199,106,157,
            184,84,204,176,115,121,50,45,127,4,150,254,138,236,205,93,
            222,114,67,29,24,72,243,141,128,195,78,66,215,61,156,180
        ]
        return base + base // double to avoid modulo
    }()

    // 12 gradient vectors (edges of a cube)
    private static let grad3: [SIMD3<Float>] = [
        SIMD3( 1, 1, 0), SIMD3(-1, 1, 0), SIMD3( 1,-1, 0), SIMD3(-1,-1, 0),
        SIMD3( 1, 0, 1), SIMD3(-1, 0, 1), SIMD3( 1, 0,-1), SIMD3(-1, 0,-1),
        SIMD3( 0, 1, 1), SIMD3( 0,-1, 1), SIMD3( 0, 1,-1), SIMD3( 0,-1,-1),
    ]

    /// Perlin improved noise in 3D. Returns value in approximately [-1, 1].
    static func noise3D(_ x: Float, _ y: Float, _ z: Float) -> Float {
        // Unit cube containing the point
        let xi = Int(floor(x)) & 255
        let yi = Int(floor(y)) & 255
        let zi = Int(floor(z)) & 255

        // Relative position within the cube
        let xf = x - floor(x)
        let yf = y - floor(y)
        let zf = z - floor(z)

        // Fade curves (6t^5 - 15t^4 + 10t^3)
        let u = fade(xf)
        let v = fade(yf)
        let w = fade(zf)

        // Hash coordinates of the 8 cube corners
        let a  = perm[xi]     + yi
        let aa = perm[a]      + zi
        let ab = perm[a + 1]  + zi
        let b  = perm[xi + 1] + yi
        let ba = perm[b]      + zi
        let bb = perm[b + 1]  + zi

        // Gradient dot products at each corner, then trilinear interpolation
        let result = lerp(w,
            lerp(v,
                lerp(u, gradDot(perm[aa],     xf,     yf,     zf),
                        gradDot(perm[ba],     xf - 1, yf,     zf)),
                lerp(u, gradDot(perm[ab],     xf,     yf - 1, zf),
                        gradDot(perm[bb],     xf - 1, yf - 1, zf))),
            lerp(v,
                lerp(u, gradDot(perm[aa + 1], xf,     yf,     zf - 1),
                        gradDot(perm[ba + 1], xf - 1, yf,     zf - 1)),
                lerp(u, gradDot(perm[ab + 1], xf,     yf - 1, zf - 1),
                        gradDot(perm[bb + 1], xf - 1, yf - 1, zf - 1))))

        return result
    }

    private static func fade(_ t: Float) -> Float {
        t * t * t * (t * (t * 6 - 15) + 10)
    }

    private static func lerp(_ t: Float, _ a: Float, _ b: Float) -> Float {
        a + t * (b - a)
    }

    private static func gradDot(_ hash: Int, _ x: Float, _ y: Float, _ z: Float) -> Float {
        let g = grad3[hash % 12]
        return g.x * x + g.y * y + g.z * z
    }
}
