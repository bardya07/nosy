@main
enum TranscriptionQualityTests {
    static func main() {
        expect("Mac16,1", "Apple M4", 4, .fast)
        expect("MacBookAir10,1", "Apple M1", 4, .fast)
        expect("MacBookPro18,3", "Apple M2 Pro", 6, .detailed)
        expect("MacBookPro18,3", "Apple M3 Max", 12, .detailed)
        expect("MacStudio1,1", "Apple M2 Ultra", 16, .detailed)
        expect("Macmini9,1", "Apple M2", 4, .fast)
        expect("Macmini9,1", "Intel Xeon", 8, .detailed)
    }

    private static func expect(_ model: String, _ cpuBrand: String, _ cores: Int,
                               _ expected: TranscriptionQuality) {
        precondition(TranscriptionQuality.recommended(model: model, cpuBrand: cpuBrand,
                                                      performanceCores: cores) == expected)
    }
}
