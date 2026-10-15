import XCTest

@testable import DSHKit

/// `workspaceFiles/readBytes` 的响应是 **multipart**，不是 JSON。
///
/// 这条链路承载**二进制**（图片、PDF），所以解析必须**字节级正确** ——
/// 用 `String` 中转会把非 UTF-8 的字节毁掉。这里的样本逐字节照着活宿主
/// 抓下来的形状写（`Content-Disposition: form-data; name="bytes-0"` +
/// `metadata` 两个 part）。
final class MultipartTests: XCTestCase {
    /// 按活宿主的形状拼一个 multipart 响应体。
    private func multipart(
        boundary: String = "----formdata-undici-0123456789",
        parts: [(name: String, body: Data)]
    ) -> Data {
        var data = Data()
        for part in parts {
            data.append(Data("--\(boundary)\r\n".utf8))
            data.append(Data("Content-Disposition: form-data; name=\"\(part.name)\"; filename=\"blob\"\r\n".utf8))
            data.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
            data.append(part.body)
            data.append(Data("\r\n".utf8))
        }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }

    func testBoundaryIsExtractedFromContentType() {
        XCTAssertEqual(
            DSHClient.multipartBoundary(in: "multipart/form-data; boundary=----formdata-undici-060589215976"),
            "----formdata-undici-060589215976"
        )
        XCTAssertEqual(
            DSHClient.multipartBoundary(in: "multipart/form-data; boundary=\"abc123\""),
            "abc123"
        )
        XCTAssertNil(DSHClient.multipartBoundary(in: "application/json"))
        XCTAssertNil(DSHClient.multipartBoundary(in: "multipart/form-data; boundary="))
    }

    /// 纯文本文件：拿到的必须和原始字节逐字节相等。
    func testExtractsTextPartByteForByte() {
        let text = "# 标题\n\n一段正文，带中文。\n"
        let body = multipart(parts: [
            (name: "bytes-0", body: Data(text.utf8)),
            (name: "metadata", body: Data(#"{"bytes":\#(text.utf8.count)}"#.utf8)),
        ])
        let got = DSHClient.multipartPart(named: "bytes-0", in: body, boundary: "----formdata-undici-0123456789")
        XCTAssertEqual(got, Data(text.utf8))
    }

    /// **二进制不许被毁**：塞进所有 0x00…0xFF 字节，取回来必须一模一样。
    ///
    /// 这是这条链路最容易写错的地方 —— 只要中途过一次 `String`，非法 UTF-8 字节
    /// 就会变成替换字符，图片直接打不开。
    func testExtractsBinaryPartWithoutCorruption() {
        let binary = Data((0...255).map { UInt8($0) })
        let body = multipart(parts: [
            (name: "bytes-0", body: binary),
            (name: "metadata", body: Data("{}".utf8)),
        ])
        let got = DSHClient.multipartPart(named: "bytes-0", in: body, boundary: "----formdata-undici-0123456789")
        XCTAssertEqual(got, binary, "0x00…0xFF 全量字节必须原样取回")
    }

    /// 真实的 PNG 头必须原样取回（不能只测人造数据）。
    func testExtractsPNGMagicIntact() {
        // 1x1 透明 PNG
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        let body = multipart(parts: [
            (name: "bytes-0", body: png),
            (name: "metadata", body: Data(#"{"bytes":\#(png.count)}"#.utf8)),
        ])
        let got = DSHClient.multipartPart(named: "bytes-0", in: body, boundary: "----formdata-undici-0123456789")
        XCTAssertEqual(got, png)
        XCTAssertEqual(Array(got!.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "PNG magic 必须完整")
    }

    /// part 顺序不影响（`bytes-0` 在后也能取到），且取不存在的 part 返回 nil。
    func testPartOrderIndependentAndMissingPartIsNil() {
        let body = multipart(parts: [
            (name: "metadata", body: Data("{}".utf8)),
            (name: "bytes-0", body: Data("payload".utf8)),
        ])
        XCTAssertEqual(
            DSHClient.multipartPart(named: "bytes-0", in: body, boundary: "----formdata-undici-0123456789"),
            Data("payload".utf8)
        )
        XCTAssertNil(DSHClient.multipartPart(named: "nope", in: body, boundary: "----formdata-undici-0123456789"))
    }

    /// 空文件也要能取到（是空 Data，不是 nil）——"文件存在但内容为空"和"读失败"要能分开。
    func testEmptyFileYieldsEmptyDataNotNull() {
        let body = multipart(parts: [
            (name: "bytes-0", body: Data()),
            (name: "metadata", body: Data(#"{"bytes":0}"#.utf8)),
        ])
        let got = DSHClient.multipartPart(named: "bytes-0", in: body, boundary: "----formdata-undici-0123456789")
        XCTAssertNotNil(got, "空文件必须返回空 Data，不能当成没找到")
        XCTAssertEqual(got?.count, 0)
    }

    /// 正文里**恰好包含 boundary 文本**时不能截断。
    ///
    /// multipart 的正规做法是"只在行首且前面有 CRLF 时才算分隔符"。这里钉住
    /// 一个务实结论：正文里出现同名字符串属于病态输入，宿主不会这么发；但
    /// **文件内容里出现 `--` 开头的行**是很常见的（Markdown 分隔线、代码注释），
    /// 它们不能把 part 截断。
    func testBodyContainingDoubleDashIsNotTruncated() {
        let text = "---\ntitle: 前言\n---\n\n正文\n\n-- 这不是分隔符\n"
        let body = multipart(parts: [
            (name: "bytes-0", body: Data(text.utf8)),
            (name: "metadata", body: Data("{}".utf8)),
        ])
        let got = DSHClient.multipartPart(named: "bytes-0", in: body, boundary: "----formdata-undici-0123456789")
        XCTAssertEqual(got, Data(text.utf8))
    }

    /// `workspaceFiles/read` 的结果解析。
    func testReadResultParsing() {
        let value = Fixture.json("""
        {"absolutePath":"/tmp/a.md","bytes":10923,"offset":1,"lines":122,"eof":true,"text":"# hi"}
        """)
        let result = WorkspaceFileText(json: value)
        XCTAssertEqual(result.text, "# hi")
        XCTAssertEqual(result.absolutePath, "/tmp/a.md")
        XCTAssertEqual(result.byteSize, 10923)
        XCTAssertEqual(result.lines, 122)
        XCTAssertTrue(result.isEOF)
    }

    /// `workspaceFiles/stat` 的结果解析（打开之前用它判断文件还在不在）。
    func testStatResultParsing() {
        let value = Fixture.json("""
        {"absolutePath":"/tmp/a.md","version":"16777229:54690197:10923:1:2","bytes":10923}
        """)
        let stat = WorkspaceFileStat(json: value)
        XCTAssertEqual(stat.absolutePath, "/tmp/a.md")
        XCTAssertEqual(stat.byteSize, 10923)
        XCTAssertEqual(stat.version, "16777229:54690197:10923:1:2")
    }
}
