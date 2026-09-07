// cgprobe: ground truth from CoreGraphics, independent of SimpleDisplay.
// Prints the online list, the active list, main, UUIDs and current modes.
import ColorSync
import CoreGraphics
import Foundation

typealias ListFn = (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError

func list(_ f: ListFn) -> [CGDirectDisplayID] {
    var n: UInt32 = 0
    _ = f(0, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    _ = f(n, &ids, &n)
    return Array(ids.prefix(Int(n)))
}

let online = list(CGGetOnlineDisplayList)
let active = Set(list(CGGetActiveDisplayList))
let main = CGMainDisplayID()
print("PROBE online=\(online.count) active=\(active.count) main=\(main)")
for id in online {
    let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "-"
    let m = CGDisplayCopyDisplayMode(id).map {
        "\($0.width)x\($0.height) px=\($0.pixelWidth)x\($0.pixelHeight) hidpi=\($0.pixelWidth != $0.width ? 1 : 0)"
    } ?? "nomode"
    let modes = (CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] ?? [])
        .map { "\($0.width)x\($0.height)\($0.pixelWidth != $0.width ? "@2x" : "")" }
    print("PROBE id=\(id) active=\(active.contains(id) ? 1 : 0) isActive=\(CGDisplayIsActive(id)) main=\(id == main ? 1 : 0) builtin=\(CGDisplayIsBuiltin(id)) mirrorOf=\(CGDisplayMirrorsDisplay(id)) uuid=\(uuid) \(m) modes=[\(modes.joined(separator: ","))]")
}
// UUID -> ID resolution, for UUIDs passed as arguments (tests the same call the app uses).
for arg in CommandLine.arguments.dropFirst() {
    if let cf = CFUUIDCreateFromString(nil, arg as CFString) {
        print("PROBE resolve \(arg) -> \(CGDisplayGetDisplayIDFromUUID(cf))")
    }
}
