//
//  STLImporter.swift
//  3D-Kankl-Druck-Editor
//
//  Imports STL files (binary and ASCII format).
//  Binary: 80-byte header + 4-byte count + N×50-byte triangles.
//  ASCII:  "solid ..." / "facet normal ..." / "vertex ..." / "endsolid".
//

import Foundation
import simd

// MARK: - Error types

enum STLImportError: LocalizedError {
    case fileNotReadable
    case emptyFile
    case invalidBinarySize
    case noTrianglesFound
    case triangleCountMismatch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .fileNotReadable:
            return "Die Datei konnte nicht geöffnet werden."
        case .emptyFile:
            return "Die Datei ist leer."
        case .invalidBinarySize:
            return "Die Datei scheint beschädigt zu sein."
        case .noTrianglesFound:
            return "Keine Dreiecke gefunden. Ist das wirklich eine STL-Datei?"
        case .triangleCountMismatch(let expected, let actual):
            return "Die Datei ist unvollständig (\(actual) von \(expected) Dreiecken gelesen — abgebrochener Download?)."
        }
    }
}

// MARK: - Importer

enum STLImporter {

    /// Load an STL file from disk. Detects binary vs ASCII automatically.
    static func load(from url: URL) throws -> MeshData {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            throw STLImportError.fileNotReadable
        }
        guard !data.isEmpty else {
            throw STLImportError.emptyFile
        }

        if isASCII(data: data) {
            return try loadASCII(data: data)
        } else {
            return try loadBinary(data: data)
        }
    }

    // MARK: - Format detection

    /// ASCII STL files start with "solid" followed by a space or newline.
    /// However, some binary files also have "solid" in the header, so we check
    /// if the file also contains "facet" to confirm ASCII.
    private static func isASCII(data: Data) -> Bool {
        guard data.count > 84 else {
            // Too small for binary (80 header + 4 count = 84 minimum), try ASCII
            return true
        }

        // Check if starts with "solid"
        let prefix = data.prefix(6)
        guard let str = String(data: prefix, encoding: .ascii),
              str.lowercased().hasPrefix("solid") else {
            return false
        }

        // Confirm by looking for "facet" keyword in first 1000 bytes
        let sample = data.prefix(1000)
        if let text = String(data: sample, encoding: .ascii) {
            return text.lowercased().contains("facet")
        }
        return false
    }

    // MARK: - Binary STL

    private static func loadBinary(data: Data) throws -> MeshData {
        // Minimum: 80 header + 4 count = 84 bytes
        guard data.count >= 84 else {
            throw STLImportError.invalidBinarySize
        }

        // Read triangle count from bytes 80-83
        let expectedCount: UInt32 = data.withUnsafeBytes { buf in
            buf.load(fromByteOffset: 80, as: UInt32.self)
        }

        guard expectedCount > 0 else {
            throw STLImportError.noTrianglesFound
        }

        // Validate file size: 84 + count * 50
        let expectedSize = 84 + Int(expectedCount) * 50
        guard data.count >= expectedSize else {
            // Try to read what we can
            let actualCount = (data.count - 84) / 50
            if actualCount == 0 {
                throw STLImportError.invalidBinarySize
            }
            // Parse partial but warn
            let mesh = try parseBinaryTriangles(data: data, count: actualCount)
            if mesh.triangles.isEmpty {
                throw STLImportError.noTrianglesFound
            }
            throw STLImportError.triangleCountMismatch(expected: Int(expectedCount), actual: actualCount)
        }

        return try parseBinaryTriangles(data: data, count: Int(expectedCount))
    }

    private static func parseBinaryTriangles(data: Data, count: Int) throws -> MeshData {
        var triangles: [Triangle] = []
        triangles.reserveCapacity(count)

        data.withUnsafeBytes { buf in
            for i in 0..<count {
                let offset = 84 + i * 50

                let nx = buf.load(fromByteOffset: offset + 0,  as: Float.self)
                let ny = buf.load(fromByteOffset: offset + 4,  as: Float.self)
                let nz = buf.load(fromByteOffset: offset + 8,  as: Float.self)

                let v0x = buf.load(fromByteOffset: offset + 12, as: Float.self)
                let v0y = buf.load(fromByteOffset: offset + 16, as: Float.self)
                let v0z = buf.load(fromByteOffset: offset + 20, as: Float.self)

                let v1x = buf.load(fromByteOffset: offset + 24, as: Float.self)
                let v1y = buf.load(fromByteOffset: offset + 28, as: Float.self)
                let v1z = buf.load(fromByteOffset: offset + 32, as: Float.self)

                let v2x = buf.load(fromByteOffset: offset + 36, as: Float.self)
                let v2y = buf.load(fromByteOffset: offset + 40, as: Float.self)
                let v2z = buf.load(fromByteOffset: offset + 44, as: Float.self)

                var normal = SIMD3<Float>(nx, ny, nz)
                let v0 = SIMD3<Float>(v0x, v0y, v0z)
                let v1 = SIMD3<Float>(v1x, v1y, v1z)
                let v2 = SIMD3<Float>(v2x, v2y, v2z)

                // Recompute normal if degenerate (some STL files have zero normals)
                if simd_length(normal) < 0.001 {
                    normal = MeshGenerator.faceNormal(v0, v1, v2)
                }

                triangles.append(Triangle(v0: v0, v1: v1, v2: v2, normal: normal))
            }
        }

        guard !triangles.isEmpty else {
            throw STLImportError.noTrianglesFound
        }

        return MeshData(triangles: triangles)
    }

    // MARK: - ASCII STL

    private static func loadASCII(data: Data) throws -> MeshData {
        guard let text = String(data: data, encoding: .ascii)
                ?? String(data: data, encoding: .utf8) else {
            throw STLImportError.fileNotReadable
        }

        var triangles: [Triangle] = []
        var currentNormal = SIMD3<Float>(0, 0, 0)
        var vertices: [SIMD3<Float>] = []

        let lines = text.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()

            if trimmed.hasPrefix("facet normal") {
                let parts = trimmed.split(separator: " ")
                if parts.count >= 5,
                   let nx = Float(parts[2]),
                   let ny = Float(parts[3]),
                   let nz = Float(parts[4]) {
                    currentNormal = SIMD3(nx, ny, nz)
                }
                vertices = []
            } else if trimmed.hasPrefix("vertex") {
                let parts = trimmed.split(separator: " ")
                if parts.count >= 4,
                   let x = Float(parts[1]),
                   let y = Float(parts[2]),
                   let z = Float(parts[3]) {
                    vertices.append(SIMD3(x, y, z))
                }

                if vertices.count == 3 {
                    var normal = currentNormal
                    if simd_length(normal) < 0.001 {
                        normal = MeshGenerator.faceNormal(vertices[0], vertices[1], vertices[2])
                    }
                    triangles.append(Triangle(
                        v0: vertices[0],
                        v1: vertices[1],
                        v2: vertices[2],
                        normal: normal
                    ))
                }
            }
        }

        guard !triangles.isEmpty else {
            throw STLImportError.noTrianglesFound
        }

        return MeshData(triangles: triangles)
    }
}
