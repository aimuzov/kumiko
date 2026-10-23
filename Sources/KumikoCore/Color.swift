/// A colour from the config: `"#8aadf4"`, `"#8aadf4cc"` with alpha last, or JankyBorders' and
/// sketchybar's `"0xff8aadf4"` with alpha first.
public struct Color: Equatable, Sendable {
	public var red: Double
	public var green: Double
	public var blue: Double
	public var alpha: Double

	public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
		self.red = red
		self.green = green
		self.blue = blue
		self.alpha = alpha
	}

	public static func parse(_ text: String) throws(ConfigError) -> Color {
		let lowered = text.lowercased()

		if lowered.hasPrefix("0x"), lowered.count == 10, let value = UInt32(lowered.dropFirst(2), radix: 16) {
			return Color(argb: value)
		}

		if lowered.hasPrefix("#"), let value = UInt32(lowered.dropFirst(), radix: 16) {
			switch lowered.count {
			case 7: return Color(argb: 0xFF00_0000 | value)
			case 9: return Color(argb: (value >> 8) | (value << 24))
			default: break
			}
		}

		throw ConfigError.invalid("bad colour \"\(text)\", expected #rrggbb, #rrggbbaa or 0xaarrggbb")
	}

	/// The colour as the config writes it: `#rrggbb`, or `#rrggbbaa` when it is not opaque.
	public var hex: String {
		let bytes = [red, green, blue, alpha].map { Int((min(max($0, 0), 1) * 255).rounded()) }
		let digits = (bytes[3] == 255 ? bytes.dropLast() : bytes[...]).map { String(format: "%02x", $0) }
		return "#" + digits.joined()
	}

	private init(argb: UInt32) {
		alpha = Double((argb >> 24) & 0xFF) / 255
		red = Double((argb >> 16) & 0xFF) / 255
		green = Double((argb >> 8) & 0xFF) / 255
		blue = Double(argb & 0xFF) / 255
	}
}
