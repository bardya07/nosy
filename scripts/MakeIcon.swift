// Copies the owner's design E artwork without re-masking the supplied macOS icon.
// Source files are design assets; no code from the handoff package is executed.
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
for (source, target) in [("Resources/Brand/Nosy.icns", "Resources/AppIcon.icns"),
                         ("Resources/Brand/nosy-app-icon.png", "Resources/NosyMark.png")] {
    let data = try Data(contentsOf: root.appendingPathComponent(source))
    try data.write(to: root.appendingPathComponent(target), options: .atomic)
}
print("ICON PASS")
