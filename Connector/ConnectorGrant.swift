import Foundation

// The app writes this independent connector grant. Missing or malformed grants fail closed.
enum ConnectorGrant {
    static func allows(root: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let support = environment["NOSY_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent("Library/Application Support/Nosy", isDirectory: true)
        let file = support.appendingPathComponent("connector-grant.json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let library = object["library"], !library.isEmpty else { return false }
        return URL(fileURLWithPath: library, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
            == root.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
