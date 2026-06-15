#!/usr/bin/env swift
/// Set a custom Finder icon on any file (e.g. .dmg) using an .icns source.
/// Usage: set_file_icon.swift <target-path> <icon.icns>
import AppKit
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2 else {
    fputs("usage: set_file_icon.swift <target> <icon.icns>\n", stderr)
    exit(2)
}

let target = (args[0] as NSString).expandingTildeInPath
let icns = (args[1] as NSString).expandingTildeInPath

guard FileManager.default.fileExists(atPath: target) else {
    fputs("target not found: \(target)\n", stderr)
    exit(1)
}
guard FileManager.default.fileExists(atPath: icns) else {
    fputs("icon not found: \(icns)\n", stderr)
    exit(1)
}
guard let image = NSImage(contentsOf: URL(fileURLWithPath: icns)) else {
    fputs("failed to load icon: \(icns)\n", stderr)
    exit(1)
}

let ok = NSWorkspace.shared.setIcon(image, forFile: target, options: [])
if !ok {
    fputs("NSWorkspace.setIcon failed for \(target)\n", stderr)
    exit(1)
}

print("icon set: \(target)")
