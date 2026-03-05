//
//  ContentView.swift
//  3D-Kankl-Druck-Editor
//
//  Main view: 3D preview on top, parameter sliders below, export button.
//  Supports STL import via file picker, drag & drop, and onOpenURL.
//  Includes mesh analysis + repair UI.
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

                    // Import loading / analyzing / repairing overlay
                    if viewModel.isImporting || viewModel.isRepairing {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text(viewModel.isRepairing ? "Reparatur läuft..." : "STL wird geladen...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(24)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    // Computing indicator (top right)
                    if viewModel.isComputing && !viewModel.isImporting && !viewModel.isRepairing {
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

                    // Mesh info + analysis badge (top left) for imported meshes
                    if let imported = viewModel.importedShape {
                        VStack {
                            HStack {
                                MeshInfoBadge(
                                    imported: imported,
                                    scaleFactor: viewModel.importScaleFactor,
                                    analysis: viewModel.meshAnalysis,
                                    isAnalyzing: viewModel.isAnalyzing
                                )
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

                // MARK: - Repair banner (below preview, above sliders)
                if let analysis = viewModel.meshAnalysis, !analysis.isPrintable, viewModel.hasImportedMesh {
                    RepairBanner(
                        analysis: analysis,
                        onRepair: { viewModel.repairMesh() },
                        onDetails: { viewModel.showRepairDetails = true }
                    )
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
                        viewModel.tryExportSTL()
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
            .sheet(isPresented: $viewModel.showRepairDetails) {
                RepairDetailsSheet(analysis: viewModel.meshAnalysis)
            }
            .sheet(isPresented: $viewModel.showRepairLog) {
                RepairLogSheet(log: viewModel.repairLog, analysis: viewModel.meshAnalysis)
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
            .alert("Mesh hat Probleme",
                   isPresented: $viewModel.showExportWarning) {
                Button("Erst reparieren") {
                    viewModel.repairMesh()
                }
                Button("Trotzdem exportieren") {
                    viewModel.exportSTL()
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Das Mesh ist nicht druckbereit. Trotzdem exportieren?")
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

// MARK: - Mesh info badge with analysis status

private struct MeshInfoBadge: View {
    let imported: ImportedShape
    let scaleFactor: Float
    let analysis: MeshAnalysis?
    let isAnalyzing: Bool

    var body: some View {
        let size = imported.originalSizeInMM * scaleFactor
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(imported.displayName)
                    .font(.caption.bold())

                if isAnalyzing {
                    ProgressView()
                        .scaleEffect(0.6)
                } else if let analysis {
                    Text(analysis.isPrintable ? "Druckbereit" : "\(analysis.issues.count) Probleme")
                        .font(.caption2.bold())
                        .foregroundStyle(analysis.isPrintable ? .green : .orange)
                }
            }
            Text("\(imported.originalTriangleCount) Dreiecke")
                .font(.caption2)
            Text("\(Int(size.x)) \u{00D7} \(Int(size.y)) \u{00D7} \(Int(size.z)) mm")
                .font(.caption2)
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Repair banner

private struct RepairBanner: View {
    let analysis: MeshAnalysis
    let onRepair: () -> Void
    let onDetails: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(analysis.issues.count) Probleme gefunden")
                    .font(.caption.bold())
                Text("Mesh ist nicht druckbereit")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Details", action: onDetails)
                .font(.caption)
                .buttonStyle(.bordered)

            Button("Reparieren", action: onRepair)
                .font(.caption.bold())
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }
}

// MARK: - Repair details sheet

private struct RepairDetailsSheet: View {
    let analysis: MeshAnalysis?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let analysis {
                    Section("Zusammenfassung") {
                        LabeledContent("Wasserdicht", value: analysis.isWatertight ? "Ja" : "Nein")
                        LabeledContent("Komponenten", value: "\(analysis.componentCount)")
                        LabeledContent("Status", value: analysis.isPrintable ? "Druckbereit" : "Probleme vorhanden")
                    }

                    if !analysis.issues.isEmpty {
                        Section("Gefundene Probleme") {
                            ForEach(analysis.issues) { issue in
                                HStack(spacing: 10) {
                                    Image(systemName: issueIcon(issue.type))
                                        .foregroundStyle(issueColor(issue.type))
                                    Text(issue.description)
                                        .font(.subheadline)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Mesh-Analyse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }

    private func issueIcon(_ type: MeshIssue.IssueType) -> String {
        switch type {
        case .openEdge: return "circle.dotted"
        case .nonManifoldEdge: return "exclamationmark.triangle"
        case .flippedNormal: return "arrow.uturn.backward"
        case .floatingComponent: return "cube.transparent"
        case .degenerateTriangle: return "triangle"
        }
    }

    private func issueColor(_ type: MeshIssue.IssueType) -> Color {
        switch type {
        case .openEdge, .nonManifoldEdge: return .red
        case .flippedNormal: return .orange
        case .floatingComponent: return .yellow
        case .degenerateTriangle: return .gray
        }
    }
}

// MARK: - Repair log sheet

private struct RepairLogSheet: View {
    let log: [String]
    let analysis: MeshAnalysis?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(log, id: \.self) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(entry)
                                .font(.subheadline)
                        }
                    }
                } header: {
                    Text("Reparatur abgeschlossen")
                }

                if let analysis {
                    Section("Neuer Status") {
                        HStack(spacing: 8) {
                            Image(systemName: analysis.isPrintable ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(analysis.isPrintable ? .green : .orange)
                            Text(analysis.isPrintable ? "Druckbereit" : "Noch Probleme vorhanden")
                                .font(.subheadline.bold())
                        }
                    }
                }
            }
            .navigationTitle("Reparatur-Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
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
