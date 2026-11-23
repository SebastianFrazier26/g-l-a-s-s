import GlassContrast
import SwiftUI

struct BackdropView: View {
    let stripes: [RGB]

    var body: some View {
        Canvas { ctx, size in
            let w = size.width / CGFloat(stripes.count)
            for (i, c) in stripes.enumerated() {
                // +1 overlap hides hairline seams between stripes at fractional widths.
                let r = CGRect(x: CGFloat(i) * w, y: 0, width: w + 1, height: size.height)
                ctx.fill(Path(r), with: .color(Color(c)))
            }
        }
    }
}

struct DemoContentView: View {
    let model: DemoModel
    /// Offscreen ImageRenderer can't draw system glass/materials, so snapshots use a drawn
    /// approximation (blurred backdrop + tint) that matches what the solver assumes.
    var useSystemGlass = true

    var body: some View {
        ZStack {
            BackdropView(stripes: model.stripes)
            panel
                .frame(width: 520, height: 250)
        }
        .frame(width: 720, height: 420)
    }

    @ViewBuilder private var panel: some View {
        let content = VStack(alignment: .leading, spacing: 8) {
            ForEach(model.lines) { line in
                HStack(alignment: .firstTextBaseline) {
                    Text(line.label)
                        .font(.system(size: line.fontSize, weight: .semibold))
                        .foregroundStyle(Color(model.displayColor(for: line)))
                    Spacer()
                    Text(String(format: "Lc %.0f", model.worstCaseLc(for: line)))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color(model.displayColor(for: line)).opacity(0.85))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    Color(line.adaptive.scrim).opacity(model.scrimOpacity(for: line)),
                    in: .rect(cornerRadius: 8))
            }
        }
        .padding(24)

        if useSystemGlass {
            systemGlass(content)
        } else {
            content
                .background {
                    ZStack {
                        BackdropView(stripes: model.stripes).blur(radius: 18)
                        Color(model.tint.color).opacity(model.tint.opacity)
                    }
                    .frame(width: 720, height: 420)
                    .frame(width: 520, height: 250)
                    .clipped()
                }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.35)))
        }
    }

    @ViewBuilder private func systemGlass(_ content: some View) -> some View {
        // .glassEffect only exists in the macOS 26 SDK (Swift 6.2+ toolchains); older CI toolchains
        // fall back to the pre-Tahoe material so the target still builds there.
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content.glassEffect(
                    .regular.tint(Color(model.tint.color).opacity(model.tint.opacity)),
                    in: .rect(cornerRadius: 28))
            } else {
                content.background(.ultraThinMaterial, in: .rect(cornerRadius: 28))
            }
        #else
            content.background(.ultraThinMaterial, in: .rect(cornerRadius: 28))
        #endif
    }
}

struct DemoWindow: View {
    @State private var model = DemoModel()

    var body: some View {
        DemoContentView(model: model)
            .overlay(alignment: .bottomTrailing) {
                Toggle("Adaptive", isOn: $model.adaptiveEnabled)
                    .toggleStyle(.switch)
                    .padding(12)
            }
            .task {
                // 30 fps keeps CPU low; the spring is closed-form so a lower rate stays smooth.
                let dt = 1.0 / 30
                while !Task.isCancelled {
                    model.step(dt: dt)
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
    }
}
