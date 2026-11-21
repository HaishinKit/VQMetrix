import Foundation
import SwiftUI

package enum VMAFModel: String, CaseIterable, Codable, Sendable {
    case v1 = "vmaf_v1.0.16_3d0h"
    case legacy = "vmaf_v0.6.1"
    package var label: String { self == .v1 ? "VMAF v1 · 1080p / 3H" : "VMAF v0.6.1" }
    package func dimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        guard self == .v1 else { return (width, height) }
        let scale = 1080.0 / Double(min(width, height))
        return (Int((Double(width) * scale / 2).rounded()) * 2, Int((Double(height) * scale / 2).rounded()) * 2)
    }
    package var bitDepth: Int { self == .v1 ? 10 : 8 }
}

struct VMAFModelPicker: View {
    let language: AppLanguage
    @AppStorage("vmafEvaluationModel") private var model = VMAFModel.v1
    var body: some View {
        HStack {
            Picker(language.text("VMAF model"), selection: $model) {
                ForEach(VMAFModel.allCases, id: \.self) { Text($0.label).tag($0) }
            }.frame(width: 300)
            Text(language.text("Scores and bitrate estimates depend on the model. Uploads keep the model selected when accepted."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

package struct VMAFEncoding: Sendable {
    package let width: Int
    package let height: Int
    package let bitDepth: Int
}
