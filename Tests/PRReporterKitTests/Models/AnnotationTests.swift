import Testing
@testable import PRReporterKit

@Suite("Annotation Tests")
struct AnnotationTests {
    @Test("Create annotation with minimal parameters")
    func createMinimalAnnotation() {
        let annotation = Annotation(
            path: "Sources/MyApp/File.swift",
            line: 42,
            level: .warning,
            message: "Variable unused"
        )

        #expect(annotation.path == "Sources/MyApp/File.swift")
        #expect(annotation.line == 42)
        #expect(annotation.level == .warning)
        #expect(annotation.message == "Variable unused")
        #expect(annotation.endLine == nil)
        #expect(annotation.column == nil)
        #expect(annotation.title == nil)
        #expect(annotation.sticky == false)
    }

    @Test("Create annotation with all parameters")
    func createFullAnnotation() {
        let annotation = Annotation(
            path: "Sources/MyApp/File.swift",
            line: 10,
            endLine: 15,
            column: 5,
            level: .failure,
            message: "Type mismatch",
            title: "Error",
            sticky: true
        )

        #expect(annotation.path == "Sources/MyApp/File.swift")
        #expect(annotation.line == 10)
        #expect(annotation.endLine == 15)
        #expect(annotation.column == 5)
        #expect(annotation.level == .failure)
        #expect(annotation.message == "Type mismatch")
        #expect(annotation.title == "Error")
        #expect(annotation.sticky == true)
    }

    @Test("Annotation levels have correct raw values")
    func levelRawValues() {
        #expect(Annotation.Level.notice.rawValue == "notice")
        #expect(Annotation.Level.warning.rawValue == "warning")
        #expect(Annotation.Level.failure.rawValue == "failure")
    }

    @Test("Annotations are equatable")
    func equatable() {
        let annotation1 = Annotation(
            path: "file.swift",
            line: 1,
            level: .warning,
            message: "test"
        )

        let annotation2 = Annotation(
            path: "file.swift",
            line: 1,
            level: .warning,
            message: "test"
        )

        let annotation3 = Annotation(
            path: "file.swift",
            line: 2,
            level: .warning,
            message: "test"
        )

        #expect(annotation1 == annotation2)
        #expect(annotation1 != annotation3)
    }

    @Test("Annotations are hashable")
    func hashable() {
        let annotation = Annotation(
            path: "file.swift",
            line: 1,
            level: .warning,
            message: "test"
        )

        var set: Set<Annotation> = []
        set.insert(annotation)

        #expect(set.contains(annotation))
    }
}
