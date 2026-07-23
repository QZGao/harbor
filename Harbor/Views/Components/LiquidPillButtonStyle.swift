import SwiftUI

struct LiquidPillButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(minHeight: 32)
            .foregroundStyle(prominent ? Color.white : Color.secondary)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)

        if #available(macOS 26, *) {
            label
                .glassEffect(
                    prominent ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                    in: .rect(cornerRadius: 16)
                )
                .contentShape(.rect(cornerRadius: 16))
        } else {
            label
                .background(
                    prominent ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            prominent ? Color.accentColor.opacity(0.24) : Color.secondary.opacity(0.16)
                        )
                }
                .contentShape(.rect(cornerRadius: 16))
        }
    }
}
