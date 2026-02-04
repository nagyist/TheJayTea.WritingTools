import SwiftUI
import AppKit

enum AppTheme: String {
    case standard
    case gradient
    case glass
    case oled
}

struct WindowBackground: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    @Bindable private var settings = AppSettings.shared
    let useGradient: Bool
    let cornerRadius: CGFloat?

    init(useGradient: Bool, cornerRadius: CGFloat? = nil) {
        self.useGradient = useGradient
        self.cornerRadius = cornerRadius
    }

    var currentTheme: AppTheme {
        if !useGradient {
            return .standard
        }
        return AppTheme(rawValue: settings.themeStyle) ?? .gradient
    }

    func body(content: Content) -> some View {
        content
            .background(
                Group {
                    switch currentTheme {
                    case .standard:
                        Color(.windowBackgroundColor)
                    case .gradient:
                        MeshLikeGradientBackground()
                    case .glass:
                        GlassmorphicBackground()
                    case .oled:
                        Color.black
                    }
                }
                .clipShape(.rect(cornerRadius: cornerRadius ?? 0))
            )
    }
}

struct MeshLikeGradientBackground: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        // Use MeshGradient on macOS 15+ for better performance, fall back to optimized implementation
        if #available(macOS 15.0, *) {
            MeshGradientBackground(colorScheme: colorScheme)
        } else {
            LegacyMeshGradientBackground(colorScheme: colorScheme)
        }
    }
}

/// Modern MeshGradient implementation for macOS 15+
/// Uses hardware-accelerated mesh gradient for optimal performance
@available(macOS 15.0, *)
struct MeshGradientBackground: View {
    let colorScheme: ColorScheme
    
    var body: some View {
        if colorScheme == .light {
            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                    [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                    [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                ],
                colors: [
                    Color(hex: "f1f5f9"), Color(hex: "a5f3fc"), Color(hex: "818cf8"),
                    Color(hex: "e2e8f0"), Color(hex: "bae6fd"), Color(hex: "a5b4fc"),
                    Color(hex: "f1f5f9"), Color(hex: "a5f3fc"), Color(hex: "818cf8")
                ]
            )
        } else {
            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                    [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                    [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                ],
                colors: [
                    Color(hex: "083344"), Color(hex: "6366f1"), Color(hex: "881337"),
                    Color(hex: "0c4a5e"), Color(hex: "4f46e5"), Color(hex: "9f1239"),
                    Color(hex: "083344"), Color(hex: "6366f1"), Color(hex: "881337")
                ]
            )
        }
    }
}

/// Optimized legacy gradient for macOS < 15
/// Uses fewer shapes and caches the gradient layer
struct LegacyMeshGradientBackground: View {
    let colorScheme: ColorScheme
    
    var body: some View {
        Canvas { context, size in
            // Draw base color
            let baseColor = colorScheme == .light 
                ? Color(hex: "f1f5f9") 
                : Color(hex: "083344")
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(baseColor)
            )
            
            // Define gradient colors based on color scheme
            let colors: [(Color, CGPoint, CGFloat)] = colorScheme == .light ? [
                (Color(hex: "a5f3fc").opacity(0.6), CGPoint(x: 0.5, y: 0.2), 0.5),
                (Color(hex: "818cf8").opacity(0.5), CGPoint(x: 0.85, y: 0.3), 0.4),
                (Color(hex: "a5f3fc").opacity(0.6), CGPoint(x: 0.5, y: 0.8), 0.5),
                (Color(hex: "818cf8").opacity(0.5), CGPoint(x: 0.15, y: 0.7), 0.4)
            ] : [
                (Color(hex: "6366f1").opacity(0.6), CGPoint(x: 0.5, y: 0.2), 0.5),
                (Color(hex: "881337").opacity(0.5), CGPoint(x: 0.85, y: 0.3), 0.4),
                (Color(hex: "6366f1").opacity(0.6), CGPoint(x: 0.5, y: 0.8), 0.5),
                (Color(hex: "881337").opacity(0.5), CGPoint(x: 0.15, y: 0.7), 0.4)
            ]
            
            // Draw radial gradients for each color blob
            for (color, relativeCenter, relativeRadius) in colors {
                let center = CGPoint(
                    x: size.width * relativeCenter.x,
                    y: size.height * relativeCenter.y
                )
                let radius = max(size.width, size.height) * relativeRadius
                
                let gradient = Gradient(colors: [color, color.opacity(0)])
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )),
                    with: .radialGradient(
                        gradient,
                        center: center,
                        startRadius: 0,
                        endRadius: radius
                    )
                )
            }
        }
        // Use drawingGroup to rasterize and cache the gradient
        .drawingGroup(opaque: true)
    }
}

struct GlassmorphicBackground: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        // Respect Reduce Transparency accessibility setting
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

        ZStack {
            if reduceTransparency {
                // Fall back to a solid, high-contrast background
                colorScheme == .light ? Color(.windowBackgroundColor) : Color.black
            } else {
                // Use native Liquid Glass effect on macOS 16.0+ (internal version 26.0)
                if #available(macOS 26.0, *) {
                    LiquidGlassBackground()
                } else {
                    // Legacy glass effect for older macOS versions
                    LegacyGlassBackground(colorScheme: colorScheme)
                }
            }
        }
    }
}

/// Native Liquid Glass effect for macOS 26.0+
@available(macOS 26.0, *)
struct LiquidGlassBackground: View {
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        // Use SwiftUI's native Liquid Glass effect with rectangular shape
        Color.clear
            .glassEffect(
                .regular.tint(
                    colorScheme == .light 
                        ? Color.blue.opacity(0.08)
                        : Color.blue.opacity(0.05)
                ),
                in: .rect(cornerRadius: 0)
            )
    }
}

/// Legacy glass effect for macOS versions before 26.0
struct LegacyGlassBackground: View {
    let colorScheme: ColorScheme
    
    var body: some View {
        ZStack {
            // Base subtle tint for both light and dark (increased opacity)
            (colorScheme == .light ? Color.white.opacity(0.15) : Color.white.opacity(0.08))

            // Soft white highlight from top-left to center to enhance "glass" sheen
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .light ? 0.35 : 0.20),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .center
            )
            .blendMode(.plusLighter)

            // Gentle color tint for depth (subtle and theme-agnostic)
            LinearGradient(
                colors: [
                    Color.blue.opacity(0.15),
                    Color.purple.opacity(0.12),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.softLight)

            // Core blur/translucency material (using thicker material)
            Rectangle()
                .fill(Material.thick)
                .opacity(0.75)

            // Subtle inner border to define edges of the glass
            Rectangle()
                .strokeBorder(
                    Color.white.opacity(colorScheme == .light ? 0.30 : 0.15),
                    lineWidth: 1
                )
                .blendMode(.overlay)
        }
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

extension View {
    func windowBackground(useGradient: Bool, cornerRadius: CGFloat? = nil) -> some View {
        modifier(WindowBackground(useGradient: useGradient, cornerRadius: cornerRadius))
    }
}



#Preview {
    MeshLikeGradientBackground()
}
