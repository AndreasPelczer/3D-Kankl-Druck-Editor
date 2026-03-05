//
//  ContentView.swift
//  3D-Kankl-Druck-Editor
//
//  Main view: 3D preview on top, parameter sliders below, export button.
//  Supports STL import via file picker, drag & drop, and onOpenURL.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var viewModel = ShapeViewModel()
    @State private var isDragOver = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // MARK: - 3D preview with overlays
                ZStack {
                    PreviewView(geometry: viewModel.previewGeometry)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Drag & drop overlay
                    if isDragOver {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                            .background(Color.accentColor.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .padding(8)
                            .allowsHitTesting(false)
                    }

                    // Import loading overlay
                    if viewModel.isImporting {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("STL wird geladen...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(24)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    // Computing indicator (top right)
                    if viewModel.isComputing && !viewModel.isImporting {
                        VStack {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .padding(8)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())
                                    .padding(12)
                            }
                            Spacer()
                        }
                    }

                    // Mesh info overlay (top left) for imported meshes
                    if let imported = viewModel.importedShape {
                        VStack {
                            HStack {
                                MeshInfoBadge(imported: imported, scaleFactor: viewModel.importScaleFactor)
                                    .padding(12)
                                Spacer()
                            }
                            Spacer()
                        }
                    }
                }
                .onDrop(of: [.stl, .data, .fileURL], isTargeted: $isDragOver) { providers in
                    handleDrop(providers: providers)
                }

                Divider()

                // MARK: - Parameter sliders
                ScrollView {
                    ParameterPanel(viewModel: viewModel)
                }
                .frame(maxHeight: 360)

                // MARK: - Bottom buttons
                HStack(spacing: 12) {
                    // Open file button
                    Button {
                        viewModel.showFilePicker = true
                    } label: {
                        Label("Öffnen", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.systemGray5))
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // Export button
                    Button {
                        viewModel.exportSTL()
                    } label: {
                        Label("STL exportieren", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding()
            }
            .navigationTitle("STL Builder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.hasImportedMesh {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Schließen") {
                            viewModel.closeImportedMesh()
                        }
                    }
                }
            }
            // MARK: - Sheets & Alerts
            .sheet(isPresented: $viewModel.showShareSheet) {
                if let url = viewModel.exportFileURL {
                    ShareSheet(activityItems: [url])
                }
            }
            .sheet(isPresented: $viewModel.showFilePicker) {
                STLDocumentPicker { url in
                    viewModel.importSTL(from: url)
                }
            }
            .alert("Import-Fehler",
                   isPresented: $viewModel.showImportError,
                   presenting: viewModel.importError) { _ in
                Button("OK") {}
            } message: { error in
                Text(error.localizedDescription)
            }
            .alert("Komplexes Mesh",
                   isPresented: $viewModel.showComplexityWarning) {
                Button("Trotzdem fortfahren") {
                    viewModel.acceptComplexMesh()
                }
                Button("Vereinfachen (20.000 Dreiecke)") {
                    viewModel.decimateAndImport()
                }
                Button("Abbrechen", role: .cancel) {
                    viewModel.pendingComplexMesh = nil
                }
            } message: {
                if let pending = viewModel.pendingComplexMesh {
                    Text("Dieses Mesh hat \(pending.mesh.triangles.count) Dreiecke. Displacement kann langsam sein.")
                }
            }
            .onOpenURL { url in
                guard url.pathExtension.lowercased() == "stl" else { return }
                viewModel.importSTL(from: url)
            }
        }
    }

    // MARK: - Drop handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        // Try file URL first
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    viewModel.importSTL(from: url)
                }
            }
            return true
        }

        // Try STL data directly
        if provider.hasItemConformingToTypeIdentifier(UTType.stl.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.stl.identifier) { data, _ in
                guard let data else { return }
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dropped_\(UUID().uuidString).stl")
                try? data.write(to: tempURL)
                Task { @MainActor in
                    viewModel.importSTL(from: tempURL)
                }
            }
            return true
        }

        return false
    }
}

// MARK: - Mesh info badge

private struct MeshInfoBadge: View {
    let imported: ImportedShape
    let scaleFactor: Float

    var body: some View {
        let size = imported.originalSizeInMM * scaleFactor
        VStack(alignment: .leading, spacing: 2) {
            Text(imported.displayName)
                .font(.caption.bold())
            Text("\(imported.originalTriangleCount) Dreiecke")
                .font(.caption2)
            Text("\(Int(size.x)) × \(Int(size.y)) × \(Int(size.z)) mm")
                .font(.caption2)
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Document Picker

struct STLDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.stl, .data])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

// MARK: - UIActivityViewController wrapper

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - UTType extension for STL

extension UTType {
    static let stl = UTType(filenameExtension: "stl") ?? .data
}
