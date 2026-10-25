import Foundation

@main
enum AudioImportTests {
    static func main() {
        func check(_ value: Bool, _ message: String) {
            guard value else { fatalError("FAIL: \(message)") }
        }

        let movie = URL(fileURLWithPath: "/tmp/Lecture Week 4.mp4")
        check(AudioImport.sessionName(for: movie) == "Lecture Week 4", "session name comes from filename without extension")
        check(AudioImport.sessionName(for: URL(fileURLWithPath: "/tmp/lecture.final.wav")) == "lecture.final",
              "session name keeps earlier filename dots")
        check(AudioImport.supports(URL(fileURLWithPath: "/tmp/lecture.wav")), "WAV is audio")
        check(AudioImport.supports(URL(fileURLWithPath: "/tmp/lecture.m4a")), "M4A is audio")
        check(AudioImport.supports(movie), "MP4 is video")
        check(AudioImport.supports(URL(fileURLWithPath: "/tmp/lecture.mov")), "MOV is video")
        check(!AudioImport.supports(URL(fileURLWithPath: "/tmp/notes.txt")), "text files are rejected")
        check(!AudioImport.supports(URL(string: "https://example.com/lecture.mp3")!), "non file URLs are rejected")
        check(AudioImport.destinationLecture(selectedTreeLecture: "CHEM281", currentLecture: "MBB322",
                                             availableLectures: ["MBB322", "CHEM281"]) == "CHEM281",
              "selected tree folder is the import target")
        check(AudioImport.destinationLecture(selectedTreeLecture: nil, currentLecture: "MBB322",
                                             availableLectures: ["CHEM281"]) == "MBB322",
              "main window folder is the fallback target")
        check(AudioImport.destinationLecture(selectedTreeLecture: nil, currentLecture: "__new__",
                                             availableLectures: ["MBB322"]) == "MBB322",
              "existing folder is used when the main window has no current folder")
        check(AudioImport.destinationLecture(selectedTreeLecture: nil, currentLecture: "mbb322",
                                             availableLectures: ["MBB322"]) == "MBB322",
              "current folder matching ignores case")
        print("AUDIO IMPORT TESTS PASS: names, media filtering, destination folder")
    }
}
