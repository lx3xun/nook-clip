import XCTest
@testable import NookClip

/// LanguageClassifier 统一语言识别回归：
/// 覆盖全部 31 种语言的正样本、非代码负样本、
/// 以及用户报告的核心 bug——Java/Kotlin 代码被标成 swift。
final class LanguageClassifierTests: XCTestCase {
    /// 31 种语言的完整正负样本已下沉至 Rust 核心单测（crates/nookclip-core/src/algorithms/language.rs）。
    /// Swift 侧仅保留跨 FFI 桥接契约（代码识别、JSON 格式化/压缩、非代码散文过滤、展示名映射）冒烟验证。
    func testFFIBridgeCodeAndJSONClassificationSmoke() {
        let javaResult = LanguageClassifier.detect(text: """
        package com.example.demo;
        import java.util.List;
        public class UserService {
            public void run() {}
        }
        """)
        XCTAssertTrue(javaResult.isCode)
        XCTAssertEqual(javaResult.language, "java")

        let jsonResult = LanguageClassifier.detect(text: "{\"name\":\"NookClip\",\"version\":2,\"features\":[\"clipboard\",\"ocr\"]}")
        XCTAssertTrue(jsonResult.isCode)
        XCTAssertTrue(jsonResult.isJSON)
        XCTAssertEqual(jsonResult.language, "json")
        XCTAssertNotNil(jsonResult.formattedJSON)
        XCTAssertNotNil(jsonResult.minifiedJSON)

        let proseResult = LanguageClassifier.detect(text: "今天下午三点开会，请大家准时到二楼会议室参加项目评审。")
        XCTAssertFalse(proseResult.isCode)
        XCTAssertNil(proseResult.language)

        XCTAssertEqual(LanguageClassifier.displayName(for: "objc"), "Objective-C")
        XCTAssertEqual(LanguageClassifier.displayName(for: "cpp"), "C++")
    }
}
