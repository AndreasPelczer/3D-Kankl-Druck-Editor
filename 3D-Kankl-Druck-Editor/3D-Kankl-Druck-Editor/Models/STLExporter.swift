//
//  STLExporter.swift
//  3D-Kankl-Druck-Editor
//
//  Binary STL file generator.
//  Format: 80-byte header | 4-byte triangle count | N * 50-byte triangle records
//  All values little-endian (native on iOS).
//

import Foundation

enum STLExporter {

    static func exportBinary(mesh: MeshData, header: String = "STLBuilder Export") -> Data {
        var data = Data()

        // 80-byte header (padded with zeros)
        var headerBytes = [UInt8](header.utf8.prefix(80))
        headerBytes.append(contentsOf: [UInt8](repeating: 0, count: 80 - headerBytes.count))
        data.append(contentsOf: headerBytes)

        // Triangle count (UInt32, little-endian)
        var count = UInt32(mesh.triangles.count)
        data.append(Data(bytes: &count, count: 4))

        // Each triangle: normal (3×Float) + 3 vertices (9×Float) + attribute byte count (UInt16)
        for tri in mesh.triangles {
            appendFloat3(&data, tri.normal)
            appendFloat3(&data, tri.v0)
            appendFloat3(&data, tri.v1)
            appendFloat3(&data, tri.v2)
            var attr: UInt16 = 0
            data.append(Data(bytes: &attr, count: 2))
        }

        return data
    }

    /// Write STL data to a temporary file and return its URL
    static func writeToTempFile(data: Data, filename: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? data.write(to: url)
        return url
    }

    private static func appendFloat3(_ data: inout Data, _ v: SIMD3<Float>) {
        var x = v.x, y = v.y, z = v.z
        data.append(Data(bytes: &x, count: 4))
        data.append(Data(bytes: &y, count: 4))
        data.append(Data(bytes: &z, count: 4))
    }
}
