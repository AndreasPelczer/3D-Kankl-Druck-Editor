//
//  ContentView.swift
//  3D-Kankl-Druck-Editor
//
//  Main view: 3D preview on top, parameter sliders below, export button.
//

import SwiftUI

struct ContentView: View {
    @State private var viewModel = ShapeViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // 3D preview (takes remaining space)
                ZStack(alignment: .topTrailing) {
                    PreviewView(geometry: viewModel.previewGeometry)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if viewModel.isComputing {
                        ProgressView()
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                            .padding(12)
                    }
                }

                Divider()

                // Parameter sliders
                ScrollView {
                    ParameterPanel(viewModel: viewModel)
                }
                .frame(maxHeight: 360)

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
                .padding()
            }
            .navigationTitle("STL Builder")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $viewModel.showShareSheet) {
                if let url = viewModel.exportFileURL {
                    ShareSheet(activityItems: [url])
                }
            }
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
