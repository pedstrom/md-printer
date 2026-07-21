import AppKit

public struct FontBook {
    public let configuration: RendererConfiguration

    public init(configuration: RendererConfiguration) {
        self.configuration = configuration
    }

    public func regular(size: CGFloat) -> NSFont {
        font(named: configuration.fontFamily, size: size, fallbackWeight: .regular)
    }

    public func bold(size: CGFloat) -> NSFont {
        font(named: configuration.fontFamily + " Demi Bold", size: size, fallbackWeight: .semibold)
    }

    public func italic(size: CGFloat) -> NSFont {
        NSFont(name: configuration.fontFamily + " Italic", size: size)
            ?? NSFontManager.shared.convert(regular(size: size), toHaveTrait: .italicFontMask)
    }

    public func boldItalic(size: CGFloat) -> NSFont {
        NSFont(name: configuration.fontFamily + " Demi Bold Italic", size: size)
            ?? NSFontManager.shared.convert(bold(size: size), toHaveTrait: .italicFontMask)
    }

    public func monospaced(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func font(named name: String, size: CGFloat, fallbackWeight: NSFont.Weight) -> NSFont {
        NSFont(name: name, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: fallbackWeight)
    }
}
