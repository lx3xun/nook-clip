#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICON_SRC="$ROOT/assets/logo-kit/exports/nookclip-appicon-1024.png"
BRANDING_DIR="$ROOT/platform/macOS/Sources/NookClip/Resources"

if [[ ! -f "$ICON_SRC" ]]; then
  echo "Error: Master icon not found at $ICON_SRC" >&2
  exit 1
fi

mkdir -p "$BRANDING_DIR"

ICONSET_TMP="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET_TMP"

echo "Generating transparent squircle master and iconset from $ICON_SRC..."
swift -e '
import AppKit

guard let data = try? Data(contentsOf: URL(fileURLWithPath: "'"$ICON_SRC"'")),
      let srcImage = NSImage(data: data) else {
    fputs("Error: Failed to load icon.png\n", stderr)
    exit(1)
}

let brandingDir = "'"$BRANDING_DIR"'"
let squircleRect: NSRect
let menuBarCropRect: NSRect

if srcImage.size.width > 1200 {
    squircleRect = NSRect(x: 239, y: 234, width: 778, height: 778)
    menuBarCropRect = NSRect(x: 370, y: 368, width: 516, height: 516)
} else {
    squircleRect = NSRect(x: 0, y: 0, width: srcImage.size.width, height: srcImage.size.height)
    let w = srcImage.size.width
    let h = srcImage.size.height
    menuBarCropRect = NSRect(x: w * 0.168, y: h * 0.172, width: w * 0.663, height: h * 0.663)
}

func createSquirclePNG(pixelSize: Int, sourceRect: NSRect = squircleRect) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: pixelSize * 4,
        bitsPerPixel: 32
    )!

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context

    let rect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
    let radius = CGFloat(pixelSize) * 0.2237
    let clipPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    clipPath.addClip()

    srcImage.draw(in: rect, from: sourceRect, operation: .copy, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])!
}

func writePNG(size: Int, path: String, sourceRect: NSRect = squircleRect) {
    let data = createSquirclePNG(pixelSize: size, sourceRect: sourceRect)
    try! data.write(to: URL(fileURLWithPath: path))
}

// Generate branding PNG assets
writePNG(size: 1024, path: "\(brandingDir)/AppIcon-1024.png")
writePNG(size: 256, path: "\(brandingDir)/AppIcon-256.png")
writePNG(size: 128, path: "\(brandingDir)/AppIcon-128.png")
writePNG(size: 64, path: "\(brandingDir)/AppIcon-64.png")
writePNG(size: 32, path: "\(brandingDir)/AppIcon-32.png")

writePNG(size: 18, path: "\(brandingDir)/MenuBarIcon.png", sourceRect: menuBarCropRect)
writePNG(size: 36, path: "\(brandingDir)/MenuBarIcon@2x.png", sourceRect: menuBarCropRect)

// Generate iconset for .icns
let iconsetDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
if !iconsetDir.isEmpty {
    try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)
    writePNG(size: 16, path: "\(iconsetDir)/icon_16x16.png")
    writePNG(size: 32, path: "\(iconsetDir)/icon_16x16@2x.png")
    writePNG(size: 32, path: "\(iconsetDir)/icon_32x32.png")
    writePNG(size: 64, path: "\(iconsetDir)/icon_32x32@2x.png")
    writePNG(size: 128, path: "\(iconsetDir)/icon_128x128.png")
    writePNG(size: 256, path: "\(iconsetDir)/icon_128x128@2x.png")
    writePNG(size: 256, path: "\(iconsetDir)/icon_256x256.png")
    writePNG(size: 512, path: "\(iconsetDir)/icon_256x256@2x.png")
    writePNG(size: 512, path: "\(iconsetDir)/icon_512x512.png")
    writePNG(size: 1024, path: "\(iconsetDir)/icon_512x512@2x.png")
}
' "$ICONSET_TMP"

echo "Compiling clean AppIcon.icns..."
iconutil -c icns "$ICONSET_TMP" -o "$BRANDING_DIR/AppIcon.icns"
rm -rf "$(dirname "$ICONSET_TMP")"

echo "Successfully updated icons in $BRANDING_DIR"
