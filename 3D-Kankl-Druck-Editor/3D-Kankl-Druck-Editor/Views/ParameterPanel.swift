//
//  ParameterPanel.swift
//  3D-Kankl-Druck-Editor
//
//  Dynamic slider panel: shape parameters + surface pattern selection + pattern sliders.
//

import SwiftUI

struct ParameterPanel: View {
    @Bindable var viewModel: ShapeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // MARK: - Shape picker

            Picker("Form", selection: $viewModel.selectedShape) {
                ForEach(ShapeType.allCases) { shape in
                    Text(shape.rawValue).tag(shape)
                }
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 4)

            // MARK: - Shape parameters

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
        }
        .padding()
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
