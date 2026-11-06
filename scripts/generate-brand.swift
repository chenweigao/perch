#!/usr/bin/env swift
import Foundation

let temp = FileManager.default.temporaryDirectory.appendingPathComponent("perch-brand-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let binary = temp.appendingPathComponent("generate-brand")
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
compiler.arguments = ["swiftc", "-parse-as-library", "scripts/brand-export.swift", "-o", binary.path]
try compiler.run()
compiler.waitUntilExit()
if compiler.terminationStatus != 0 { exit(compiler.terminationStatus) }
let export = Process()
export.executableURL = binary
try export.run()
export.waitUntilExit()
exit(export.terminationStatus)
