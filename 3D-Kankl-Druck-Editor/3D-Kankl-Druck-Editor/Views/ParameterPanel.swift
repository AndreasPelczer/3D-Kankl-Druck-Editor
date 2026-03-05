//
//  ParameterPanel.swift
//  3D-Kankl-Druck-Editor
//
//  Dynamic slider panel: shape or import parameters + surface pattern selection + pattern sliders.
//

import SwiftUI

struct ParameterPanel: View {
    @Bindable var viewModel: ShapeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            if viewModel.hasImportedMesh {
                importParameterSection
            } else {
                shapeParameterSection
            }

            Divider()
                .padding(.vertical, 4)

            // MARK: - Surface pattern picker

            Text("Oberflächenstruktur")
                .font(.subheadline.bold())

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(SurfacePattern.allCases) { pattern in
                        PatternButton(
                            pattern: pattern,
                            isSelected: viewModel.selectedPattern == pattern
                        ) {
                            viewModel.selectedPattern = pattern
                            viewModel.resetPatternParams()
                        }
                    }
                }
            }

            // MARK: - Pattern global controls (only when not smooth)

            if viewModel.selectedPattern != .smooth {
                paramSlider("Intensität", value: $viewModel.patternIntensity, range: 0.01...1, unit: "%", multiplier: 100)
                paramSlider("Skalierung", value: $viewModel.patternScale, range: 0.2...5, unit: "×")

                // MARK: - Pattern-specific parameters
                ForEach(viewModel.selectedPattern.parameters) { param in
                    patternParamSlider(param)
                }
            }

            // MARK: - Reset button for imported mesh
            if viewModel.hasImportedMesh && viewModel.hasModifications {
                Divider()
                    .padding(.vertical, 4)

                Button {
                    viewModel.resetToOriginal()
                } label: {
                    Label("Original wiederherstellen", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
    }

    // MARK: - Shape parameter section (generated shapes)

    private var shapeParameterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
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
    }

    // MARK: - Import parameter section

    private var importParameterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Importiertes Mesh")
                .font(.subheadline.bold())

            // Scale slider
            VStack(alignment: .leading, spacing: 2) {
                Text("Skalierung: \(Int(viewModel.importScaleFactor * 100))%")
                    .font(.subheadline)
                Slider(value: $viewModel.importScaleFactor, in: 0.1...5.0)
            }

            // Quick scale buttons
            HStack(spacing: 8) {
                scaleButton("÷10", factor: 0.1)
                scaleButton("÷2", factor: 0.5)
                scaleButton("1:1", factor: 1.0)
                scaleButton("×2", factor: 2.0)
                scaleButton("×10", factor: 10.0)
                scaleButton("in→mm", factor: 25.4 / max(viewModel.importScaleFactor, 0.001))
            }
        }
    }

    // MARK: - Slider helpers

    private func paramSlider(
        _ label: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        unit: String = "mm",
        multiplier: Float = 1
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label): \(value.wrappedValue * multiplier, specifier: "%.1f") \(unit)")
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

    private func patternParamSlider(_ param: PatternParameter) -> some View {
        let binding = Binding<Float>(
            get: { viewModel.patternParams[param.id] ?? param.defaultValue },
            set: { viewModel.patternParams[param.id] = $0 }
        )
        return VStack(alignment: .leading, spacing: 2) {
            if let step = param.step {
                Text("\(param.name): \(Int(binding.wrappedValue))")
                    .font(.subheadline)
                Slider(value: binding, in: param.range, step: step)
            } else {
                Text("\(param.name): \(binding.wrappedValue, specifier: "%.2f")")
                    .font(.subheadline)
                Slider(value: binding, in: param.range)
            }
        }
    }

    private func scaleButton(_ label: String, factor: Float) -> some View {
        Button(label) {
            viewModel.importScaleFactor = factor
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .buttonStyle(.plain)
    }
}

// MARK: - Pattern selection button

private struct PatternButton: View {
    let pattern: SurfacePattern
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: pattern.iconName)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(isSelected ? Color.accentColor : Color(.systemGray5))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(pattern.rawValue)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 70)
        }
        .buttonStyle(.plain)
    }
}
