// cgmain <displayID>: make a display main by shifting every active display's origin.
import CoreGraphics
import Foundation
guard CommandLine.arguments.count == 2, let id = UInt32(CommandLine.arguments[1]) else { print("usage: cgmain <displayID>"); exit(2) }
var n: UInt32 = 0
CGGetActiveDisplayList(0, nil, &n)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
CGGetActiveDisplayList(n, &ids, &n)
let b = CGDisplayBounds(id)
var cfg: CGDisplayConfigRef?
guard CGBeginDisplayConfiguration(&cfg) == .success else { print("begin failed"); exit(1) }
for d in ids {
    let db = CGDisplayBounds(d)
    CGConfigureDisplayOrigin(cfg, d, Int32(db.origin.x - b.origin.x), Int32(db.origin.y - b.origin.y))
}
let done = CGCompleteDisplayConfiguration(cfg, .forSession)
print("main -> \(id): \(done.rawValue)")
exit(done == .success ? 0 : 1)
