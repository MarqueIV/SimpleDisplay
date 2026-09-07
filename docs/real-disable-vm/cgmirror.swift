// cgmirror <displayID> <targetID|0>: mirror a display onto another (0 = stop mirroring),
// with the same CG transaction the app uses. Standalone, for probing what the
// window server tolerates.
import CoreGraphics
import Foundation

let args = CommandLine.arguments.dropFirst().compactMap { UInt32($0) }
guard args.count == 2 else { print("usage: cgmirror <displayID> <targetID|0>"); exit(2) }
var config: CGDisplayConfigRef?
guard CGBeginDisplayConfiguration(&config) == .success else { print("begin failed"); exit(1) }
let err = CGConfigureDisplayMirrorOfDisplay(config, args[0], args[1])
guard err == .success else { CGCancelDisplayConfiguration(config); print("configure failed: \(err.rawValue)"); exit(1) }
let done = CGCompleteDisplayConfiguration(config, .forSession)
print("complete: \(done.rawValue) (\(args[0]) -> \(args[1]))")
exit(done == .success ? 0 : 1)
