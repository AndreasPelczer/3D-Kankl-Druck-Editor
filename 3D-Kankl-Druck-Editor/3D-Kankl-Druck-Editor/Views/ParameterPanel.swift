//
//  ParameterPanel.swift
//  3D-Kankl-Druck-Editor
//
//  Dynamic slider panel for the currently selected shape's parameters.
//

import SwiftUI

struct ParameterPanel: View {
    @Bindable var viewModel: ShapeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Shape picker
            Picker("Form", selection: $viewModel.selectedShape) {
                ForEach(ShapeType.allCases) { shape in
                    Text(shape.rawValue).tag(shape)
                }
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 4)

            switch viewModel.selectedShape {
            case .cube:
                paramSlider("Breite", value: $viewModel.cubeWidth, range: 1...100)
                paramSlider("Höhe", value: $viewModel.cubeHeight, range: 1...100)
                paramSlider("Tiefe", value: $viewModel.cubeDepth, range: 1...100)

            case .cylinder:
                paramSlider("Radius", value: $viewModel.cylinderRadius, range: 1...50)
                paramSlider("Höhe", value: $viewModel.cylinderHeight, range: 1...100)
                segmentSlider("Segmente", value: $viewModel.cylinderSegments, range: 3...128)

            case .sphere:
                paramSlider("Radius", value: $viewModel.sphereRadius, range: 1...50)
                segmentSlider("Segmente", value: $viewModel.sphereSegments, range: 4...128)
            }
        }
        .padding()
    }

    // MARK: - Slider helpers

    private func paramSlider(_ label: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label): \(value.wrappedValue, specifier: "%.1f") mm")
                .font(.subheadline)
            Slider(value: value, in: range)
        }
    }

    private func segmentSlider(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        let floatBinding = Binding<Float>(
            get: { Float(value.wrappedValue) },
            set: { value.wrappedValue = Int($0) }
        )
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(label): \(value.wrappedValue)")
                .font(.subheadline)
            Slider(value: floatBinding, in: Float(range.lowerBound)...Float(range.upperBound), step: 1)
        }
    }
}
