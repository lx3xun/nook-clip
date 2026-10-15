import XCTest
@testable import NookClip

/// LanguageClassifier 统一语言识别回归：
/// 覆盖全部 31 种语言的正样本、非代码负样本、
/// 以及用户报告的核心 bug——Java/Kotlin 代码被标成 swift。
final class LanguageClassifierTests: XCTestCase {
    private func assertLanguage(_ code: String, _ expected: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let result = LanguageClassifier.detect(text: code)
        XCTAssertTrue(result.isCode, "应为代码: \(expected)", file: file, line: line)
        XCTAssertEqual(result.language, expected, file: file, line: line)
    }

    // MARK: - 用户报告的 bug（Java 复制成 Swift）

    func testJavaClassIsNotSwift() {
        // SmartTitleExtractor 旧首条正则把 class 一律标成 swift 的直接回归样本
        assertLanguage("""
        package com.example.demo;

        import java.util.List;

        public class UserService {
            private final UserRepository repository;

            public User findById(Long id) {
                return repository.findById(id).orElseThrow();
            }
        }
        """, "java")
    }

    func testKotlinDataClassIsNotSwift() {
        assertLanguage("""
        data class User(val name: String, val age: Int)

        fun main() {
            println(User("Alice", 30))
        }
        """, "kotlin")
    }

    // MARK: - 各语言正样本

    func testSwift() {
        assertLanguage("""
        import SwiftUI

        struct CounterView: View {
            @State private var count = 0
            func increment() -> Int {
                return count + 1
            }
        }
        """, "swift")
    }

    func testObjectiveC() {
        assertLanguage("""
        #import <Foundation/Foundation.h>

        @interface User : NSObject
        @property (nonatomic, strong) NSString *name;
        @end

        @implementation User
        - (void)greet {
            NSLog(@"Hello %@", self.name);
        }
        @end
        """, "objc")
    }

    func testPython() {
        assertLanguage("""
        import numpy as np

        def process_data(items):
            result = [x * 2 for x in items]
            return np.array(result)
        """, "python")
    }

    func testJavaScript() {
        assertLanguage("""
        const arr = [1, 2, 3];
        const doubled = arr.map(x => x * 2);
        console.log(doubled);
        """, "javascript")
    }

    func testTypeScript() {
        assertLanguage("""
        interface User {
            name: string;
            age: number;
        }

        function greet(user: User): string {
            return `Hello ${user.name}`;
        }
        """, "typescript")
    }

    func testReactJSX() {
        assertLanguage("""
        import React, { useState } from 'react';

        function Counter() {
            const [count, setCount] = useState(0);
            return (
                <div className="counter">
                    <button onClick={() => setCount(count + 1)}>Click</button>
                </div>
            );
        }
        """, "jsx")
    }

    func testVueSFC() {
        assertLanguage("""
        <template>
          <div>{{ message }}</div>
        </template>

        <script>
        export default {
          data() { return { message: 'Hello' } }
        }
        </script>

        <style scoped>
        .card { padding: 8px; }
        </style>
        """, "vue")
    }

    func testGo() {
        assertLanguage("""
        package main

        import "fmt"

        func main() {
            ch := make(chan int, 1)
            defer close(ch)
            fmt.Println("hello", ch)
        }
        """, "go")
    }

    func testRust() {
        assertLanguage("""
        use std::collections::HashMap;

        fn main() {
            let mut map = HashMap::new();
            map.insert("key", 42);
            println!("{}", map.len());
        }
        """, "rust")
    }

    func testC() {
        assertLanguage("""
        #include <stdio.h>

        int main() {
            printf("Hello, World!\\n");
            return 0;
        }
        """, "c")
    }

    func testCpp() {
        assertLanguage("""
        #include <iostream>
        using namespace std;

        int main() {
            cout << "Hello" << endl;
            return 0;
        }
        """, "cpp")
    }

    func testCSharp() {
        assertLanguage("""
        using System;
        using System.Collections.Generic;

        namespace Demo {
            public class Program {
                static void Main(string[] args) {
                    Console.WriteLine("Hello");
                }
            }
        }
        """, "csharp")
    }

    func testRuby() {
        assertLanguage("""
        class User < ApplicationRecord
          def initialize(name)
            @name = name
          end

          def greet
            puts "Hello #{@name}"
          end
        end
        """, "ruby")
    }

    func testPHP() {
        assertLanguage("""
        <?php
        function greet($name) {
            echo "Hello " . $name;
            return true;
        }
        ?>
        """, "php")
    }

    func testShell() {
        assertLanguage("""
        #!/bin/bash
        set -e
        for f in *.txt; do
          echo "Processing $f"
        done
        """, "shell")
    }

    func testSQL() {
        assertLanguage("""
        SELECT id, title, created_at FROM items
        WHERE is_favorite = 1
        ORDER BY last_used_at DESC
        """, "sql")
    }

    func testHTML() {
        assertLanguage("""
        <!DOCTYPE html>
        <html>
        <head><title>Test</title></head>
        <body>
          <div class="container">Hello</div>
        </body>
        </html>
        """, "html")
    }

    func testXML() {
        assertLanguage("""
        <?xml version="1.0" encoding="UTF-8"?>
        <root>
          <item id="1">hello</item>
        </root>
        """, "xml")
    }

    func testJSON() {
        let result = LanguageClassifier.detect(text: "{\"name\":\"NookClip\",\"version\":2,\"features\":[\"clipboard\",\"ocr\"]}")
        XCTAssertTrue(result.isCode)
        XCTAssertTrue(result.isJSON)
        XCTAssertEqual(result.language, "json")
        XCTAssertNotNil(result.formattedJSON)
        XCTAssertTrue(result.formattedJSON?.contains("\n") == true)
        XCTAssertNotNil(result.minifiedJSON)
    }

    func testYAML() {
        assertLanguage("""
        name: nook
        version: 1.2.3
        dependencies:
          - swift
          - sqlite
        """, "yaml")
    }

    func testTOML() {
        assertLanguage("""
        [package]
        name = "nook"
        version = "0.1.0"

        [dependencies]
        sqlite = "0.4"
        """, "toml")
    }

    func testCSS() {
        assertLanguage("""
        .card {
          display: flex;
          padding: 16px;
          color: #333;
          border-radius: 8px;
        }
        """, "css")
    }

    func testDart() {
        assertLanguage("""
        class User {
          final String name;
          User(this.name);

          void greet() => print('Hello $name');
        }
        """, "dart")
    }

    func testLua() {
        assertLanguage("""
        local function greet(name)
          print("Hello, " .. name)
        end
        """, "lua")
    }

    func testR() {
        assertLanguage("""
        library(ggplot2)
        df <- data.frame(x = c(1, 2, 3))
        ggplot(df, aes(x)) + geom_point()
        """, "r")
    }

    func testScala() {
        assertLanguage("""
        object Main extends App {
          def greet(name: String): Unit = println(s"hello $name")
        }
        """, "scala")
    }

    func testVB() {
        assertLanguage("""
        Module Program
            Sub Main()
                Console.WriteLine("Hello")
            End Sub
        End Module
        """, "vb")
    }

    func testMATLAB() {
        assertLanguage("""
        function y = square(x)
            y = x.^2;
            disp(y)
        end
        """, "matlab")
    }

    func testGroovy() {
        assertLanguage("""
        def message = ['hello', 'world']
        println message.join(' ')
        """, "groovy")
    }

    // MARK: - 负样本与严格置信策略

    func testChineseProseIsNotCode() {
        let result = LanguageClassifier.detect(text: "今天下午三点开会，请大家准时到二楼会议室参加项目评审。")
        XCTAssertFalse(result.isCode)
        XCTAssertNil(result.language)
    }

    func testChineseKeyValueNotesAreNotYAML() {
        // 中文笔记的「时间: 三点」伪 key:value 不应误判为 YAML
        let result = LanguageClassifier.detect(text: "时间: 下午三点\n地点: 二楼会议室\n议题: 项目评审")
        XCTAssertFalse(result.isCode)
    }

    func testEnglishProseIsNotCode() {
        let result = LanguageClassifier.detect(text: "Please return the items you selected from the list and put them back where they belong.")
        XCTAssertFalse(result.isCode)
    }

    func testAmbiguousFragmentFallsBackToCode() {
        // Java/C# 同构的单行方法片段：宁可显示 Code 也不硬猜（严格置信策略）
        let result = LanguageClassifier.detect(text: "public ResponseDTO<Void> loginUser(LoginRequest req) { return ResponseDTO.ok(); }")
        XCTAssertEqual(result.language, nil)
    }

    func testShortTextIsNotCode() {
        let result = LanguageClassifier.detect(text: "ok")
        XCTAssertFalse(result.isCode)
    }

    // MARK: - 展示名与规范 id

    func testDisplayName() {
        XCTAssertEqual(LanguageClassifier.displayName(for: "objc"), "Objective-C")
        XCTAssertEqual(LanguageClassifier.displayName(for: "cpp"), "C++")
    }

    // MARK: - 终端输出与弱词防误判

    func testTerminalBannerIsNotCode() {
        // 用户实测样本特征：omp 欢迎横幅（ASCII 边框 + Unicode 框线），
        // 旧实现靠 until/then 英文词凑分被误判成 Lua
        let banner = """
        +--- omp v18.4.10 ------------------------------------------------------------+
        |                          | Tips                                             |
        |  Welcome back!            |  # for prompt action                            |
        |  GLM 5.3                  |  / for commands                                |
        |                           |  ! to run bash                                 |
        |  ┌─────────┐              |  $ to run python                               |
        |  │ Recent  │              |                                                 |
        |  └─────────┘              |                                                 |
        +--------------------------------------------------------------------------------+
        Wait until the sync finishes, then check the status.
        """
        let result = LanguageClassifier.detect(text: banner)
        XCTAssertFalse(result.isCode, "终端横幅不应判为代码")
        XCTAssertNil(result.language, "终端横幅不应断言语言（曾误判 Lua）")
    }

    func testProseWithUntilThenIsNotCode() {
        // 英文普通句子里出现 until/then 不应凑够 Lua 的分数
        let prose = "Please wait until the build finishes, then close the terminal window."
        let result = LanguageClassifier.detect(text: prose)
        XCTAssertFalse(result.isCode)
        XCTAssertNil(result.language)
    }

    func testANSIEscapeOutputIsNotCode() {
        let output = "\u{1B}[32mSuccess\u{1B}[0m\n\u{1B}[31mError: timeout\u{1B}[0m\nDone in 2s"
        let result = LanguageClassifier.detect(text: output)
        XCTAssertFalse(result.isCode)
    }

    func testLuaStillDetected() {
        assertLanguage("""
        local function greet(name)
            print("Hello, " .. name)
        end
        """, "lua")
        // repeat/until 循环单独出现也应是 Lua
        assertLanguage("""
        local i = 0
        repeat
            i = i + 1
        until i >= 10
        """, "lua")
    }
}
