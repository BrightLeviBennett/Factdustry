//
//  SafeAsset.swift
//
//
//
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

import SpriteKit

/// Returns true if an image asset with `name` exists in the main bundle's asset catalog.
@inline(__always)
public func assetExists(_ name: String) -> Bool {
    #if canImport(UIKit)
    return UIImage(named: name) != nil
    #elseif canImport(AppKit)
    return NSImage(named: NSImage.Name(name)) != nil
    #else
    // Fallback: if we can't check, assume missing only when name is empty.
    return !name.isEmpty
    #endif
}

/// Returns `name` if the asset exists; otherwise returns "404".
@inline(__always)
public func safeAssetName(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "404" }
    return assetExists(trimmed) ? trimmed : "404"
}

/// Drop-in SwiftUI Image that falls back to "404" when `name` is not found.
public struct SafeImage: View {
    private let name: String
    private let renderingMode: Image.TemplateRenderingMode?
    private let resizable: Bool

    /// Create a SafeImage.
    /// - Parameters:
    ///   - name: Asset name to load; if not present, uses "404".
    ///   - renderingMode: Optional rendering mode (e.g., .template).
    ///   - resizable: If true, returns a resizable Image; otherwise fixed.
    public init(_ name: String, renderingMode: Image.TemplateRenderingMode? = nil, resizable: Bool = false) {
        self.name = name
        self.renderingMode = renderingMode
        self.resizable = resizable
    }

    public var body: some View {
        var img = Image(safeAssetName(name))
        if let m = renderingMode {
            img = img.renderingMode(m)
        }
        return resizable ? img.resizable() : img
    }
}

public extension Image {
    /// Convenience initializer: Image(safe: "block-icon")
    init(safe name: String) {
        self.init(safeAssetName(name))
    }
}

public extension SKTexture {
    /// Loads an SKTexture by name, falling back to "404" if missing.
    static func safe(named name: String) -> SKTexture {
        SKTexture(imageNamed: safeAssetName(name))
    }
}
