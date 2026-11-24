import AppKit
import SwiftUI

/// The supplied Emulsion assets are the single source of colour values.
/// Script builds retain the catalog as resources when actool is unavailable.
enum FP {
    private static var resourceURL: URL {
        ProcessInfo.processInfo.environment["CANON_PROFILE_RESOURCES"]
            .map { URL(fileURLWithPath: $0) } ?? Bundle.main.resourceURL!
    }

    private static func colour(_ name: String) -> Color {
        if let compiled = NSColor(named: NSColor.Name(name), bundle: .main) {
            return Color(nsColor: compiled)
        }
        let url = resourceURL.appendingPathComponent("Assets.xcassets/\(name).colorset/Contents.json")
        guard let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(ColourSet.self, from: data),
              let light = catalog.colors.first(where: { !$0.isDark })?.nsColor else {
            assertionFailure("Missing brand colour: \(name)")
            return Color(nsColor: .labelColor)
        }
        let dark = catalog.colors.first(where: \.isDark)?.nsColor ?? light
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    private struct ColourSet: Decodable {
        struct Entry: Decodable {
            struct Appearance: Decodable { let appearance: String; let value: String }
            struct Value: Decodable {
                struct Components: Decodable { let red: String; let green: String; let blue: String; let alpha: String }
                let components: Components
            }
            let color: Value
            let appearances: [Appearance]?
            var isDark: Bool { appearances?.contains { $0.appearance == "luminosity" && $0.value == "dark" } ?? false }
            var nsColor: NSColor? {
                func component(_ value: String) -> Double? {
                    value.hasPrefix("0x") ? UInt8(value.dropFirst(2), radix: 16).map { Double($0) / 255 } : Double(value)
                }
                let c = color.components
                guard let r = component(c.red), let g = component(c.green),
                      let b = component(c.blue), let a = component(c.alpha) else { return nil }
                return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
            }
        }
        let colors: [Entry]
    }

    static let accent = colour("AccentColor")
    static let brandInk = colour("FPBrandInk")
    static let onGreen = colour("FPOnGreen")
    static let buttonTop = colour("FPButtonTop")
    static let buttonBottom = colour("FPButtonBottom")
    static let slotBadgeText = colour("FPSlotBadgeText")
    static let cautionText = colour("FPCautionText")
    static let cautionFill = colour("FPCautionFill")
    static let cautionStroke = colour("FPCautionStroke")
    static let chipFill = colour("FPChipFill")
    static let inspectorBackground = colour("FPInspectorBackground")
    static let slotCard = colour("FPSlotCard")
    static let secondaryText = colour("FPSecondaryText")
    private static let slots = [colour("FPSlot1"), colour("FPSlot2"), colour("FPSlot3")]

    /// Preserve an explicit system accent choice; Multicolour uses the app brand.
    static let controlAccent = Color(nsColor: NSColor(name: nil) { _ in
        let preference = UserDefaults.standard.object(forKey: "AppleAccentColor") as? Int
        if let preference, preference != -2 { return .controlAccentColor }
        return NSColor(accent)
    })

    static func slot(_ number: Int) -> Color { slots[max(0, min(2, number - 1))] }
    static func cameraString(_ style: Font.TextStyle = .caption) -> Font { .system(style, design: .monospaced) }

    static let mark: NSImage = {
        if let compiled = NSImage(named: "FPMark") { return compiled }
        let result = NSImage(size: NSSize(width: 24, height: 24))
        let directory = resourceURL.appendingPathComponent("Assets.xcassets/FPMark.imageset")
        for file in ["FPMark.png", "FPMark@2x.png", "FPMark@3x.png"] {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(file)),
               let representation = NSBitmapImageRep(data: data) {
                representation.size = result.size
                result.addRepresentation(representation)
            }
        }
        return result
    }()
}

struct FPMark: View {
    var size: CGFloat = 24
    var body: some View {
        Image(nsImage: FP.mark).resizable().interpolation(.high)
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct FPSidebarHeader: View {
    var body: some View {
        HStack(spacing: 9) {
            FPMark()
            Text("FILM PROFILES")
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .tracking(3).foregroundStyle(FP.brandInk)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Film Profiles")
    }
}

struct FPSlotBadge: View {
    let slot: Int
    var body: some View {
        Text("\(slot)").font(.system(size: 11, weight: .bold))
            .foregroundStyle(FP.slotBadgeText).frame(width: 20, height: 20)
            .background(Circle().fill(FP.slot(slot))).accessibilityHidden(true)
    }
}

struct FPSlotTag: View {
    let slot: Int
    var compact = false
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(FP.slot(slot)).frame(width: 9, height: 9)
            if !compact { Text("Slot \(slot)").font(.caption2) }
        }
        .fpSecondaryText()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("On camera, user slot \(slot)")
    }
}

struct FPCautionChip: View {
    let text: String
    @Environment(\.backgroundProminence) private var prominence
    var body: some View {
        let selected = prominence == .increased
        Text(text).font(.caption2.weight(.semibold))
            .foregroundStyle(selected ? FP.onGreen : FP.cautionText)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(selected ? FP.onGreen.opacity(0.18) : FP.chipFill))
    }
}

struct FPCautionCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(FP.cautionFill))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(FP.cautionStroke, lineWidth: 0.5))
    }
}

struct FPCautionTitle: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "info.circle").font(.body.weight(.semibold))
            .foregroundStyle(FP.cautionText).symbolRenderingMode(.monochrome)
            .frame(minHeight: 36, alignment: .leading)
    }
}

struct FPPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration) }
    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label.font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FP.onGreen).frame(maxWidth: .infinity, minHeight: 34)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [FP.buttonTop, FP.buttonBottom],
                                         startPoint: .top, endPoint: .bottom)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
        }
    }
}

/// Stronger secondary text over the actual sidebar and tinted surfaces.
/// Keep system secondary styling for emphasized native selections.
private struct FPSecondaryText: ViewModifier {
    @Environment(\.backgroundProminence) private var prominence
    func body(content: Content) -> some View {
        if prominence == .increased {
            content.foregroundStyle(.secondary)
        } else {
            content.foregroundStyle(FP.secondaryText)
        }
    }
}

extension View {
    func fpSecondaryText() -> some View { modifier(FPSecondaryText()) }
}
