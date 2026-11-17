import Foundation
import WorkbenchCore

func decode(_ rows: [[String: Any]]) throws -> [KimiMessage] {
    try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: rows))
}
@main struct PadProbe {
    static func main() throws {
        // bench-shaped large window: 16k messages via wire decode
        var rows: [[String: Any]] = []
        for i in 0..<8000 {
            rows.append(["id": "u\(i)", "role": "user", "created_at": "\(i)",
                         "content": [["type": "text", "text": "第 \(i) 轮：请继续推进任务并验证结果。"]]])
            rows.append(["id": "a\(i)", "role": "assistant", "created_at": "\(i)",
                         "content": [["type": "text", "text": "结论 \(i)：已经处理完毕，见文件与输出。"],
                                     ["type": "tool_use", "tool_call_id": "c\(i)", "tool_name": "Read",
                                      "input": ["file_path": "/repo/File\(i).swift"]]]])
        }
        let window = try decode(rows)
        let split = window.count - 2
        let materialized = Array(window[..<split])
        let bits = round33ReviewSameWindowBits(window[..<split], materialized[...])
        let value = round33ReviewSameWindow(window[..<split], materialized[...])
        // scan SIZE bytes AND the stride padding gap for differences
        var sizeDiffs = 0, padDiffs = 0
        window.withUnsafeBufferPointer { left in
            materialized.withUnsafeBufferPointer { right in
                let a = UnsafeRawPointer(left.baseAddress!)
                let b = UnsafeRawPointer(right.baseAddress!)
                let size = MemoryLayout<KimiMessage>.size, stride = MemoryLayout<KimiMessage>.stride
                for i in 0..<min(split, materialized.count) {
                    for j in 0..<size where a.load(fromByteOffset: i*stride+j, as: UInt8.self) != b.load(fromByteOffset: i*stride+j, as: UInt8.self) { sizeDiffs += 1 }
                    for j in size..<stride where a.load(fromByteOffset: i*stride+j, as: UInt8.self) != b.load(fromByteOffset: i*stride+j, as: UInt8.self) { padDiffs += 1 }
                }
            }
        }
        print("messages=\(window.count) split=\(split) size=\(MemoryLayout<KimiMessage>.size) stride=\(MemoryLayout<KimiMessage>.stride)")
        print("sameWindowBits=\(bits) sameWindow=\(value) size_byte_diffs=\(sizeDiffs) padding_byte_diffs=\(padDiffs)")
        // second materialization from the same source (fresh malloc) to test padding stability
        let materialized2 = Array(window[..<split])
        print("second_copy sameWindowBits=\(round33ReviewSameWindowBits(window[..<split], materialized2[...]))")
        print("copy_vs_copy sameWindowBits=\(round33ReviewSameWindowBits(materialized[...], materialized2[...]))")
    }
}
