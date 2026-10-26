// Draws kumiko's app icon into an .iconset folder, every size from the shapes themselves so the
// small ones stay sharp: the kumiko layout (a big cell with an asanoha star, three windows beside
// it) in hinoki lines on a walnut gradient, on Apple's 1024 px icon grid. The menu bar icon in
// StatusMenu.swift draws the same mark.
//
// Usage: swift scripts/app-icon.swift <AppIcon.iconset>

import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> CGColor {
	CGColor(
		srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
		blue: CGFloat(hex & 255) / 255, alpha: 1
	)
}

/// The rounded square of macOS icons: a superellipse, whose corners ease in the way Apple's do.
func squircle(_ rect: CGRect) -> CGPath {
	let path = CGMutablePath()
	for i in 0...720 {
		let t = CGFloat(i) / 720 * 2 * .pi
		let (c, s) = (cos(t), sin(t))
		let point = CGPoint(
			x: rect.midX + rect.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 0.4),
			y: rect.midY + rect.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), 0.4)
		)
		i == 0 ? path.move(to: point) : path.addLine(to: point)
	}
	path.closeSubpath()
	return path
}

/// In the units of the 1024 px canvas; the caller scales to the size it renders.
func draw(_ ctx: CGContext) {
	let body = CGRect(x: 100, y: 100, width: 824, height: 824)
	let shape = squircle(body)

	ctx.saveGState()
	ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: CGColor(gray: 0, alpha: 0.28))
	ctx.addPath(shape)
	ctx.setFillColor(color(0x4E2F1F))
	ctx.fillPath()
	ctx.restoreGState()

	ctx.saveGState()
	ctx.addPath(shape)
	ctx.clip()
	let walnut = CGGradient(colorsSpace: nil, colors: [color(0x8A5A3C), color(0x4E2F1F)] as CFArray, locations: [0, 1])!
	ctx.drawLinearGradient(walnut, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
	ctx.restoreGState()

	ctx.setStrokeColor(color(0xF3DFC0))
	ctx.setLineCap(.round)
	ctx.setLineJoin(.round)

	let frame = CGRect(x: 262, y: 262, width: 500, height: 500)
	let split = frame.minX + frame.width * 0.64
	ctx.setLineWidth(40)
	ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 56, cornerHeight: 56, transform: nil))
	ctx.move(to: CGPoint(x: split, y: frame.minY))
	ctx.addLine(to: CGPoint(x: split, y: frame.maxY))
	for row in 1...2 {
		let y = frame.minY + frame.height * CGFloat(row) / 3
		ctx.move(to: CGPoint(x: split, y: y))
		ctx.addLine(to: CGPoint(x: frame.maxX, y: y))
	}
	ctx.strokePath()

	let centre = CGPoint(x: (frame.minX + split) / 2, y: frame.midY)
	let radius = (split - frame.minX) / 2 - 52
	ctx.setLineWidth(30)
	for ray in 0..<6 {
		let angle = CGFloat(ray) * .pi / 3 + .pi / 2
		ctx.move(to: centre)
		ctx.addLine(to: CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle)))
	}
	ctx.strokePath()
}

for points in [16, 32, 128, 256, 512] {
	for scale in [1, 2] {
		let pixels = points * scale
		let rep = NSBitmapImageRep(
			bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
			hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
		)!
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
		let ctx = NSGraphicsContext.current!.cgContext
		ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
		draw(ctx)
		NSGraphicsContext.restoreGraphicsState()

		let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
		try rep.representation(using: .png, properties: [:])!.write(to: output.appending(path: name))
	}
}
