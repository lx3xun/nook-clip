import XCTest
@testable import NookClip

/// 真实规模历史记录性能基准（5000 / 10000 / 50000 三档，确定性随机种子，可复现）。
///
/// 存储引擎：nook-core（Rust）经 RustHistoryStore/UniFFI 桥接，取代旧 SQLiteHistoryStore。
///
/// 数据构成（按档位等比缩放，10,000 档为基准比例）：
/// - 活跃唯一条目 89%：文本 48%（含代码/JSON/色值/中英文）、链接 16%、
///   图片 16%（带 OCR 文本）、文件 5%、敏感条目 4%（掩码 + 加密内容）
/// - 内容重复行 6%（验证 Rust 引擎内容去重合并链路）
/// - 回收站软删除条目 5%（摘要加独立后缀，避免被内容去重折叠回活跃行）
/// - 收藏约 8%、copyCount 1–15、lastUsedAt 覆盖近 90 天、7 个来源 App
///
/// 统计口径：每次迭代独立计时，输出 P50 / P95 / max / 均值。
/// 50000 档搜索迭代 ≥5 次以满足 P95 统计要求。
///
/// 运行：`NOOK_PERF=1 swift test --package-path platform/macOS --filter PerformanceBenchmarkTests`
/// 未设置 NOOK_PERF=1 时整体跳过，不影响常规测试基线。
@MainActor
final class PerformanceBenchmarkTests: XCTestCase {

    // MARK: - 确定性随机数（xorshift64*，与历史基线同种子）

    private struct PerfRNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 2_685_821_657_736_338_717
        }
        mutating func next(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }
    }

    // MARK: - 基准工具

    private let clock = ContinuousClock()
    private var report: [(name: String, iterations: Int, avgMs: Double, p50: Double, p95: Double, maxMs: Double, note: String)] = []

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    /// 线性插值分位数（样本不足 5 个时 P95 退化为 max，报告中以样本数标注）
    private static func percentile(_ samples: [Double], _ p: Double) -> Double {
        guard samples.count > 1 else { return samples.first ?? 0 }
        let sorted = samples.sorted()
        let rank = p * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        guard lower != upper, upper < sorted.count else { return sorted[min(upper, sorted.count - 1)] }
        let weight = rank - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    private func record(_ name: String, samples: [Double], note: String) {
        let avg = samples.reduce(0, +) / Double(max(samples.count, 1))
        report.append((
            name: name,
            iterations: samples.count,
            avgMs: avg,
            p50: Self.percentile(samples, 0.5),
            p95: Self.percentile(samples, 0.95),
            maxMs: samples.max() ?? 0,
            note: note
        ))
    }

    @discardableResult
    private func bench<T>(_ name: String, note: String = "", iterations: Int = 1, _ body: () throws -> T) rethrows -> [T] {
        var results: [T] = []
        var samples: [Double] = []
        for _ in 0..<iterations {
            let start = clock.now
            let value = try body()
            samples.append(Self.milliseconds(clock.now - start))
            results.append(value)
        }
        record(name, samples: samples, note: note)
        return results
    }

    @discardableResult
    private func benchAsync<T>(_ name: String, note: String = "", iterations: Int = 1, _ body: () async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        var samples: [Double] = []
        for _ in 0..<iterations {
            let start = clock.now
            let value = try await body()
            samples.append(Self.milliseconds(clock.now - start))
            results.append(value)
        }
        record(name, samples: samples, note: note)
        return results
    }

    /// 批量操作：测整段循环，按单次操作均值上报（单样本：P50=P95=max=单次均值）
    private func benchPerOp(_ name: String, note: String = "", ops: Int, _ body: () -> Void) {
        let start = clock.now
        body()
        let perOp = Self.milliseconds(clock.now - start) / Double(ops)
        record(name, samples: [perOp], note: note)
    }

    private func printReport(header: String) {
        print("\n===== \(header) =====")
        for entry in report {
            let line = String(
                format: "%@ | 次数 %d | P50 %.2f | P95 %.2f | max %.2f | 均值 %.2f ms | %@",
                entry.name, entry.iterations,
                entry.p50, entry.p95, entry.maxMs, entry.avgMs, entry.note)
            print(line)
        }
        print("===== 结束 \(header) =====\n")
    }

    // MARK: - 主流程（默认跳过，NOOK_PERF=1 启用）

    func testFiveThousandItemsBenchmark() async throws {
        try await runScaleBenchmark(total: 5_000)
    }

    func testTenThousandItemsFullFeatureBenchmark() async throws {
        try await runScaleBenchmark(total: 10_000)
    }

    func testFiftyThousandItemsBenchmark() async throws {
        try await runScaleBenchmark(total: 50_000)
    }

    private func runScaleBenchmark(total: Int) async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOOK_PERF"] == "1",
            "性能基准默认跳过；运行：NOOK_PERF=1 swift test --filter PerformanceBenchmarkTests"
        )
        let label = "\(total)"
        let now = Date()
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("nook-perf-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("history.sqlite").path
        // 50000 档适当降低读取类迭代次数控制总时长；搜索仍 ≥5 次以满足 P95
        let heavy = total >= 50_000
        let readIters = heavy ? 3 : 5
        let searchIters = heavy ? 5 : 7

        // ---------- 1. 造数 + 批量写入（单事务批量接口，含内容去重与 FTS 维护） ----------
        let (unique, duplicates, trash) = Self.makeItems(now: now, total: total)
        let activeRows = unique.count // 重复行被 Rust 引擎按 (type, summary) 合并进原行
        let db = try RustHistoryStore(path: dbPath, encryptionKey: Data(repeating: 0x42, count: 32))

        bench("批量写入 \(label) 条（单事务批量接口，含去重与 FTS 索引）", iterations: 1) {
            XCTAssertTrue(db.saveBatch(unique + duplicates + trash), "批量写入必须整体提交成功")
        }
        let seedMs = report.last!.avgMs
        report[report.count - 1].note = String(format: "%.0f 条/s", Double(unique.count + duplicates.count + trash.count) / (seedMs / 1_000))

        // 逐条 save 吞吐（交互路径参考：同 id 重存走合并 upsert，不新增行）
        bench("逐条 save 吞吐 \(label) 条（独立事务/条）", iterations: 1) {
            var ok = true
            for item in unique + duplicates { ok = (db.save(item) != nil) && ok }
            XCTAssertTrue(ok, "逐条写入必须全部成功")
        }
        let perItemMs = report.last!.avgMs
        report[report.count - 1].note = String(format: "%.0f 条/s", Double(unique.count + duplicates.count + trash.count) / (perItemMs / 1_000))

        // 功能校验：重复行被内容去重合并、回收站独立成行
        XCTAssertEqual(db.countItems(), activeRows, "活跃行 = 唯一条目数（重复行按内容合并）")
        XCTAssertEqual(db.countFavorites(), unique.filter(\.isFavorite).count)
        // 回收站查询上限 1000 行（RustHistoryStore.trashItems 固定 limit）：50k 档截断
        let trashLoadable = min(trash.count, 1_000)
        XCTAssertEqual(db.trashItems().count, trashLoadable)

        // ---------- 2. 冷启动 ----------
        let defaults = makeIsolatedDefaults()
        defaults.set(0, forKey: "historyRetentionDays") // 无限制：基准库不被启动清理改写
        defaults.set(true, forKey: InMemoryHistoryStore.demoSeededKey) // 跳过演示数据播种
        let cold = bench("冷启动 InMemoryHistoryStore（首页100+回收站+清理检查）",
                         note: "items=\(db.page(limit: InMemoryHistoryStore.pageSize).count)") {
            InMemoryHistoryStore(rustStore: db, syncEngine: self.makeDisabledSyncEngine(), defaults: defaults)
        }
        XCTAssertEqual(cold.count, 1)
        let store = try XCTUnwrap(cold.first)
        XCTAssertEqual(store.items.count, min(InMemoryHistoryStore.pageSize, activeRows), "首页恰好一页")
        XCTAssertEqual(store.trashItems.count, trashLoadable)
        if activeRows > InMemoryHistoryStore.pageSize {
            XCTAssertTrue(store.hasMoreItems, "\(activeRows) 活跃行 > 首页 \(InMemoryHistoryStore.pageSize)")
        }

        // ---------- 3. 读取路径 ----------
        bench("首页查询 page(limit:100)", iterations: readIters) { db.page(limit: 100, offset: 0) }
            .forEach { XCTAssertEqual($0.count, min(100, activeRows)) }

        bench("翻页替换查询 page(limit:1000)", iterations: readIters) { db.page(limit: 1_000, offset: 0) }
            .forEach { XCTAssertEqual($0.count, min(1_000, activeRows)) }

        bench("翻页替换查询 page(limit:2000)", iterations: 3) { db.page(limit: 2_000, offset: 0) }
            .forEach { XCTAssertEqual($0.count, min(2_000, activeRows)) }

        let allActive = try XCTUnwrap(
            bench("全量载入 page(limit:全量)", iterations: 1) { db.page(limit: 1_000_000, offset: 0) }.first
        )
        XCTAssertEqual(allActive.count, activeRows, "重复行已在引擎侧按内容去重")

        bench("回收站载入 trashItems()（上限 1000 行）", iterations: readIters) { db.trashItems() }
            .forEach { XCTAssertEqual($0.count, trashLoadable) }

        bench("计数 countItems()/countFavorites()（Rust 聚合查询）", iterations: 10) {
            _ = db.countItems(); _ = db.countFavorites()
        }

        // ---------- 4. 全历史搜索（Rust FTS5 trigram，异步串行队列路径） ----------
        let searchLimit = 200
        let common = await benchAsync("搜索·常见中文词「会议纪要」（trigram，广泛命中）", iterations: searchIters) {
            await store.searchHistory(queryText: "会议纪要", categoryID: 0, limit: searchLimit)
        }
        XCTAssertEqual(common.first?.items.count, min(searchLimit, activeRows), "命中超过一页")
        if activeRows > searchLimit { XCTAssertEqual(common.first?.hasMore, true) }
        XCTAssertFalse(common.first?.failed ?? true)

        let expectedRare = unique.filter { $0.summary.contains("罕见标记NOOK") }.count
        let rare = await benchAsync("搜索·稀有词「罕见标记NOOK」（trigram，\(expectedRare) 命中）", iterations: searchIters) {
            await store.searchHistory(queryText: "罕见标记NOOK", categoryID: 0, limit: searchLimit)
        }
        XCTAssertEqual(rare.first?.items.count, min(expectedRare, searchLimit))

        let short = await benchAsync("搜索·短词「ai」（<3 标量，LIKE 回退）", iterations: searchIters) {
            await store.searchHistory(queryText: "ai", categoryID: 0, limit: searchLimit)
        }
        XCTAssertGreaterThanOrEqual(short.first?.items.count ?? 0, 1, "英文正文含 ai 子串")

        let multiKeyword = await benchAsync("搜索·「性能优化 任务分配」（多关键词 AND）", iterations: searchIters) {
            await store.searchHistory(queryText: "性能优化 任务分配", categoryID: 0, limit: searchLimit)
        }
        XCTAssertGreaterThanOrEqual(multiKeyword.first?.items.count ?? 0, 1, "多关键词 AND 命中中文正文")
        XCTAssertTrue(multiKeyword.first?.items.allSatisfy {
            $0.summary.contains("性能优化") && $0.summary.contains("任务分配")
        } ?? false, "多关键词 AND：命中必须同时包含两个词")

        let expectedImageHits = unique.filter { $0.type == .image }.count
        let imageSearch = await benchAsync("搜索·分类预筛=图片 +「performance」", iterations: searchIters) {
            await store.searchHistory(queryText: "performance", categoryID: 2, limit: searchLimit)
        }
        XCTAssertEqual(imageSearch.first?.items.count, min(searchLimit, expectedImageHits))
        XCTAssertTrue(imageSearch.first?.items.allSatisfy { $0.type == .image } ?? false)

        let favSearch = await benchAsync("搜索·分类预筛=收藏 +「performance」", iterations: searchIters) {
            await store.searchHistory(queryText: "performance", categoryID: 8, limit: searchLimit)
        }
        XCTAssertTrue(favSearch.first?.items.allSatisfy(\.isFavorite) ?? false)

        // 敏感条目不入 FTS 索引（明文与掩码均不可搜）——这是产品不变量，基准验证其快速返回空
        let sensitiveSearch = await benchAsync("搜索·敏感掩码「••••」（FTS 排除敏感条目，0 命中）", iterations: searchIters) {
            await store.searchHistory(queryText: "••••", categoryID: 0, limit: searchLimit)
        }
        XCTAssertEqual(sensitiveSearch.first?.items.count, 0, "敏感条目必须不可被搜索命中")

        // ---------- 5. UI 派生与内存过滤链（非搜索态，全量行模型） ----------
        let rows = try XCTUnwrap(
            bench("行模型派生 ClipboardRowModel.map（全量，含代码/JSON/色值检测）", iterations: 1) {
                ClipboardRowModel.map(allActive)
            }.first
        )
        XCTAssertEqual(rows.count, activeRows)

        bench("侧边栏分类计数 SidebarCategories.categories", iterations: 3) {
            SidebarCategories.categories(for: rows)
        }

        for (catID, catLabel) in [(1, "文本"), (2, "图片"), (4, "链接"), (8, "收藏")] {
            bench("内存分类过滤 matchesCategory=\(catLabel)", iterations: 3) {
                rows.filter { SidebarCategories.matchesCategory(catID, $0) }
            }
        }

        bench("时间线分组 Timeline.group（今天/昨天/本周/月归档）", iterations: 3) {
            Timeline.group(rows)
        }

        // ---------- 6. 变更操作（Rust 引擎直写，覆盖全历史而非仅首页） ----------
        let favIDs = Array(allActive.filter(\.isFavorite).prefix(100))
        benchPerOp("切换收藏 toggleFavorite ×100", ops: 100) {
            for item in favIDs { db.toggleFavorite(item.id) }
        }

        let titleIDs = Array(allActive.prefix(100))
        benchPerOp("自定义标题 updateTitle ×100（索引行同步替换）", ops: 100) {
            for (i, item) in titleIDs.enumerated() { db.updateTitle(id: item.id, title: "自定义标题\(i)") }
        }

        let imageIDs = Array(allActive.filter { $0.type == .image }.prefix(100))
        benchPerOp("OCR 回写 updateOCR ×100", ops: 100) {
            for (i, item) in imageIDs.enumerated() { db.updateOCR(id: item.id, ocrText: "OCR 补充文本 \(i)") }
        }

        // 置顶合并：取首页之外的旧条目（同 id upsert 刷新 lastUsedAt + copyCount）
        let oldIDs = Array(allActive.suffix(20))
        benchPerOp("复制置顶 upsert save ×20（旧条目刷新 lastUsedAt/copyCount）", ops: 20) {
            for item in oldIDs {
                var updated = item
                updated.lastUsedAt = Date()
                updated.copyCount += 1
                db.save(updated)
            }
        }

        // 重复复制：同内容新 id → Rust 引擎按 (type, summary) 命中合并
        let dupSource = allActive[500]
        benchPerOp("重复复制合并 save（同内容）×20", ops: 20) {
            for _ in 0..<20 {
                db.save(ClipboardItem(
                    id: UUID(), type: dupSource.type,
                    title: dupSource.title, summary: dupSource.summary,
                    createdAt: now, lastUsedAt: now, copyCount: 1,
                    isFavorite: dupSource.isFavorite,
                    payloadPath: dupSource.payloadPath,
                    ocrText: dupSource.ocrText,
                    sourceAppBundleId: dupSource.sourceAppBundleId,
                    sourceAppName: dupSource.sourceAppName,
                    isSensitive: dupSource.isSensitive,
                    encryptedContent: dupSource.encryptedContent,
                    metadata: dupSource.metadata
                ))
            }
        }
        XCTAssertEqual(db.countItems(), activeRows, "同内容复制必须合并，不新增行")

        benchPerOp("新条目入库 save ×50（去重查询 + 双表写入）", ops: 50) {
            for i in 0..<50 {
                db.save(ClipboardItem(
                    type: .text, title: "新条目", summary: "性能基准新条目 \(UUID().uuidString) #\(i)",
                    createdAt: now, lastUsedAt: now
                ))
            }
        }

        // ---------- 7. 回收站（store 层内存镜像 + 引擎软删除/恢复） ----------
        let deleteIDs = Set(store.items.map(\.id))
        benchPerOp("批量软删除 deleteMultiple ×\(deleteIDs.count)", ops: deleteIDs.count) {
            store.deleteMultiple(deleteIDs)
        }
        XCTAssertEqual(store.trashItems.count, trashLoadable + deleteIDs.count)

        benchPerOp("回收站恢复 restoreFromTrash ×\(deleteIDs.count)", ops: deleteIDs.count) {
            store.restoreFromTrash(deleteIDs)
        }
        XCTAssertEqual(store.trashItems.count, trashLoadable)

        // ---------- 8. 导入导出 ----------
        let jsonData = try bench("导出 JSON exportToJSON（全量活跃）", iterations: 1) {
            try store.exportToJSON()
        }.first!
        bench("导出 Markdown exportToMarkdown（全量活跃）", iterations: 1) {
            _ = try? store.exportToMarkdown()
        }

        let db2 = try RustHistoryStore(path: dir.appendingPathComponent("history-import.sqlite").path, encryptionKey: Data(repeating: 0x42, count: 32))
        let store2 = InMemoryHistoryStore(rustStore: db2, syncEngine: makeDisabledSyncEngine(), defaults: makeIsolatedDefaults())
        let imported = try await benchAsync("导入 JSON importFromJSON（空库整批）", iterations: 1) {
            try store2.importFromJSON(jsonData)
        }.first!
        XCTAssertGreaterThan(imported, Int(Double(unique.count) * 0.8), "导入应落库绝大部分条目")

        // ---------- 9. 清理（破坏性，置于最后） ----------
        bench("保留期清理 pruneExpired(days:7)（收藏豁免）", note: "清掉 7 天前非收藏条目", iterations: 1) {
            db.pruneExpired(days: 7, maxCount: nil)
        }

        bench("清空历史 clearAllHistory(keepFavorites:true)", iterations: 1) {
            db.clearAllHistory(keepFavorites: true)
        }
        // 切换收藏基准把前 favIDs.count 个收藏翻转为非收藏，清空后剩余 = 初始收藏 - 翻转数
        let expectedFavorites = unique.filter(\.isFavorite).count - favIDs.count
        XCTAssertEqual(db.countItems(), expectedFavorites, "清空后仅剩收藏")
        XCTAssertEqual(db.countItems(), db.countFavorites(), "清空后仅剩收藏")

        // ---------- 10. 搜索性能阈值守护 ----------
        // SC-002：各档全部搜索 P95 ≤ 250ms（PRD 目标 10k 档 ≤ 250ms 的外推）。
        // 阈值修改需同步 specs/003-systematic-refactor/data-model.md §6。
        assertSearchP95Threshold()

        printReport(header: "NookClip \(label) 条数据性能基准（Rust 核心）")
    }

    /// 搜索性能阈值断言（SC-002）：对本次运行的全部「搜索·」基准项断言 P95 ≤ 250ms。
    /// CI performance job 依赖此断言变红来拦截性能回退，而非仅打印报告。
    private func assertSearchP95Threshold(limitMs: Double = 250) {
        let searchEntries = report.filter { $0.name.hasPrefix("搜索·") }
        XCTAssertFalse(searchEntries.isEmpty, "搜索基准项缺失，阈值守护失效")
        for entry in searchEntries {
            XCTAssertLessThanOrEqual(
                entry.p95, limitMs,
                "搜索性能回退：「\(entry.name)」P95=\(entry.p95)ms 超过 \(Int(limitMs))ms（SC-002）"
            )
        }
    }

    // MARK: - 造数

    /// 按目标总行数（unique + duplicates + trash）等比缩放生成确定性数据。
    /// 默认 total = 10_000，与历史基线的数据构成完全一致。
    private static func makeItems(now: Date, total: Int = 10_000) -> (unique: [ClipboardItem], duplicates: [ClipboardItem], trash: [ClipboardItem]) {
        var rng = PerfRNG(state: 0x4E4F4F4B) // "NOOK"

        let sources: [(String, String)] = [
            ("Safari", "com.apple.Safari"), ("Xcode", "com.apple.dt.Xcode"),
            ("微信", "com.tencent.xinWeChat"), ("备忘录", "com.apple.Notes"),
            ("Terminal", "com.apple.Terminal"), ("Figma", "com.figma.Desktop"),
            ("Finder", "com.apple.finder"),
        ]
        func source() -> (String, String) { sources[rng.next(sources.count)] }

        // 10,000 档基准构成：unique 8900（text 4800/url 1600/image 1600/file 500/sensitive 400）+ dup 600 + trash 500
        let f = Double(total) / 10_000.0
        let textCount = Int((4_800.0 * f).rounded()), urlCount = Int((1_600.0 * f).rounded())
        let imageCount = Int((1_600.0 * f).rounded()), fileCount = Int((500.0 * f).rounded())
        let sensitiveCount = Int((400.0 * f).rounded())
        let dupCount = Int((600.0 * f).rounded()), trashCount = Int((500.0 * f).rounded())
        let uniqueCount = textCount + urlCount + imageCount + fileCount + sensitiveCount
        let ageStep: TimeInterval = 90 * 86_400 / Double(uniqueCount) // 90 天均匀铺开

        func baseItem(type: ClipboardItemType, summary: String, index: Int,
                      payloadPath: String? = nil, ocrText: String? = nil,
                      metadata: ClipboardMetadata = ClipboardMetadata(),
                      isSensitive: Bool = false, encrypted: Data? = nil) -> ClipboardItem {
            let lastUsed = now - Double(index) * ageStep - TimeInterval(rng.next(300))
            let src = source()
            return ClipboardItem(
                type: type,
                title: type == .file ? ((payloadPath ?? "") as NSString).lastPathComponent : "",
                summary: summary,
                createdAt: lastUsed - TimeInterval(rng.next(30 * 86_400)),
                lastUsedAt: lastUsed,
                copyCount: 1 + rng.next(15),
                isFavorite: index % 12 == 0, // ≈8%
                payloadPath: payloadPath,
                ocrText: ocrText,
                sourceAppBundleId: src.1,
                sourceAppName: src.0,
                isSensitive: isSensitive,
                encryptedContent: encrypted,
                metadata: metadata
            )
        }

        var unique: [ClipboardItem] = []
        unique.reserveCapacity(uniqueCount)

        // 文本：普通中文 / 代码 / JSON / 色值 / 英文 / 稀有标记
        for i in 0..<textCount {
            var summary: String
            switch i % 100 {
            case 0..<10:
                summary = """
                func handleTask\(i)(_ input: String) throws -> Int {
                    let result = input.count * \(i)
                    guard result > 0 else { throw NSError(domain: "perf", code: \(i)) }
                    return result
                }
                """
            case 10..<14:
                summary = #"{"id": \#(i), "name": "perf-item-\#(i)", "tags": ["benchmark", "nook"], "score": \#(i % 100)}"#
            case 14..<18:
                let hex = String(format: "#%02X%02X%02X", rng.next(256), rng.next(256), rng.next(256))
                summary = hex
            case 18..<38:
                summary = "Performance benchmark sample \(i): the quick brown fox jumps over the lazy dog, unicode 标量混合 \(i)."
            default:
                summary = "会议纪要第\(i)次：讨论本季度性能优化、任务分配与风险跟进，责任人与截止时间已同步到备忘录（编号 NOOK-\(i)）。"
            }
            if i % 960 == 5 { summary += " 罕见标记NOOK" }
            var metadata = ClipboardMetadata()
            if i % 100 < 10 { metadata.language = "swift" }
            unique.append(baseItem(type: .text, summary: summary, index: i, metadata: metadata))
        }

        // 链接
        for i in 0..<urlCount {
            let summary = "https://example\(i % 50).com/docs/perf/\(i)?q=benchmark&page=\(i % 20)#section"
            var metadata = ClipboardMetadata()
            metadata.url = summary
            unique.append(baseItem(type: .url, summary: summary, index: textCount + i, metadata: metadata))
        }

        // 图片（带 OCR 文本；不落虚构载荷路径，避免触发 OCR 任务）
        for i in 0..<imageCount {
            let summary = "性能基准截图 \(i) #\(String(format: "%08x", rng.next(Int(UInt32.max))))"
            unique.append(baseItem(
                type: .image, summary: summary, index: textCount + urlCount + i,
                ocrText: "OCR 识别文本 performance 记录 \(i)：图表与文字混合内容"
            ))
        }

        // 文件
        for i in 0..<fileCount {
            let ext = ["pdf", "md", "zip", "png", "txt"][i % 5]
            let path = "/tmp/nook-perf/attachment-\(i).\(ext)"
            var metadata = ClipboardMetadata()
            metadata.fileInfo = "\(1 + rng.next(20)) MB"
            unique.append(baseItem(type: .file, summary: path, index: textCount + urlCount + imageCount + i,
                                   payloadPath: path, metadata: metadata))
        }

        // 敏感条目（掩码 + 加密内容占位）
        for i in 0..<sensitiveCount {
            var encrypted = Data(repeating: 0xA5, count: 152)
            encrypted.append(contentsOf: (0..<8).map { _ in UInt8(rng.next(256)) })
            unique.append(baseItem(
                type: .text, summary: "••••••••（敏感条目 \(i) 已加密）", index: textCount + urlCount + imageCount + fileCount + i,
                isSensitive: true, encrypted: encrypted
            ))
        }

        // 重复行：复制较旧区的唯一条目（不进首页，验证引擎内容去重与合并）
        let fileStart = textCount + urlCount + imageCount
        var duplicates: [ClipboardItem] = []
        duplicates.reserveCapacity(dupCount)
        for j in 0..<dupCount {
            // 目标限定文件条目区（摘要互异且可按内容去重；
            // 敏感条目按 id 去重不折叠，混入会让活跃行断言失真）
            let target = unique[fileStart + (j * 13) % max(fileCount, 1)]
            let copy = ClipboardItem(
                id: UUID(),
                type: target.type, title: target.title, summary: target.summary,
                createdAt: target.createdAt,
                lastUsedAt: target.lastUsedAt + 61, // 比原条目略新，仍在旧区
                copyCount: 1 + rng.next(5), isFavorite: target.isFavorite,
                payloadPath: target.payloadPath, ocrText: target.ocrText,
                sourceAppBundleId: target.sourceAppBundleId, sourceAppName: target.sourceAppName,
                isSensitive: target.isSensitive, encryptedContent: target.encryptedContent,
                metadata: target.metadata
            )
            duplicates.append(copy)
        }

        // 软删除（撤销宽限内，跨类型）：摘要追加独立后缀，
        // 否则 Rust 引擎按 (type, summary) 内容去重会命中活跃原行并把它拉回活跃集
        var trash: [ClipboardItem] = []
        trash.reserveCapacity(trashCount)
        for i in 0..<trashCount {
            // 步长 19 与 uniqueCount 互素（uniqueCount 为 89 的倍数时成立）：模板互不相同
            let template = unique[(i * 19 + 7) % uniqueCount]
            let item = ClipboardItem(
                type: template.type, title: template.title,
                summary: "\(template.summary) [回收站副本 \(i)]",
                createdAt: template.createdAt, lastUsedAt: now - TimeInterval(i % 50) * 0.5,
                copyCount: 1, isFavorite: template.isFavorite,
                payloadPath: template.payloadPath, ocrText: template.ocrText,
                sourceAppBundleId: template.sourceAppBundleId, sourceAppName: template.sourceAppName,
                isSensitive: template.isSensitive, encryptedContent: template.encryptedContent,
                metadata: template.metadata, deletedAt: now - TimeInterval(i % 50) * 0.5
            )
            trash.append(item)
        }

        return (unique, duplicates, trash)
    }
}
