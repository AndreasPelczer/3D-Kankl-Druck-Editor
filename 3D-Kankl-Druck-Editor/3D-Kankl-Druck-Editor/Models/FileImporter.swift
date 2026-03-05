//
//  FileImporter.swift
//  3D-Kankl-Druck-Editor
//
//  Unified file importer that routes to format-specific parsers based on file extension.
//  Supported formats: STL (binary + ASCII), OBJ (Wavefront), DXF (AutoCAD exchange).
//

import Foundation

// MARK: - Unified import error

enum FileImportError: LocalizedError {
    case fileNotReadable
    case emptyFile
    case noTrianglesFound
    case unsupportedFormat(String)
    case stlError(STLImportError)

    var errorDescription: String? {
        switch self {
        case .fileNotReadable:
            return "Die Datei konnte nicht geöffnet werden."
        case .emptyFile:
            return "Die Datei ist leer."
        case .noTrianglesFound:
            return "Keine 3D-Geometrie gefunden."
        case .unsupportedFormat(let ext):
            return "Das Format „.\(ext)" wird nicht unterstützt. Unterstützt: STL, OBJ, DXF."
        case .stlError(let error):
            return error.errorDescription
        }
    }
}

// MARK: - Supported formats

enum MeshFileFormat: String {
    case stl, obj, dxf

    init?(url: URL) {
        let ext = url.pathExtension.lowercased()
        self.init(rawValue: ext)
    }

    var displayName: String {
        switch self {
        case .stl: return "STL"
        case .obj: return "OBJ (Wavefront)"
        case .dxf: return "DXF (AutoCAD)"
        }
    }
}

// MARK: - Unified importer

enum FileImporter {

    /// Supported file extensions
    static let supportedExtensions: Set<String> = ["stl", "obj", "dxf"]

    /// Load a 3D mesh file from URL. Auto-detects format by extension.
    static func load(from url: URL) throws -> MeshData {
        guard let format = MeshFileFormat(url: url) else {
            throw FileImportError.unsupportedFormat(url.pathExtension)
        }

        switch format {
        case .stl:
            do {
                return try STLImporter.load(from: url)
            } catch let error as STLImportError {
                throw FileImportError.stlError(error)
            }
        case .obj:
            return try OBJImporter.load(from: url)
        case .dxf:
            return try DXFImporter.load(from: url)
        }
    }

    /// Check if a URL has a supported file extension
    static func isSupported(url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
