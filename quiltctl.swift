// quiltctl: the only component of quilt that touches macOS private APIs.
//
// Output contract, every subcommand: exactly one JSON object on stdout; human text on stderr.
// Exit codes: 0 success, 1 attempted and verifiably failed, 2 unsupported on this build,
// 3 symbol/framework acquisition failed, 64 bad usage.
//
// Build: /usr/bin/swiftc -O -o quiltctl quiltctl.swift

import Foundation
import CoreGraphics
import ObjectiveC
import Darwin

// MARK: - JSON output

func printJSON(_ obj: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    } else {
        print("{\"error\":\"internal json encode failure\"}")
    }
}

func failExit(_ code: Int32, _ obj: [String: Any]) -> Never {
    printJSON(obj)
    exit(code)
}

// MARK: - SkyLight dynamic symbol acquisition (dlsym path)

func dlfunc<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) -> T? {
    guard let sym = dlsym(handle, name) else { return nil }
    return unsafeBitCast(sym, to: T.self)
}

func requireSym<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) -> T {
    guard let f: T = dlfunc(handle, name, as: type) else {
        failExit(3, ["error": "symbol \(name) unavailable"])
    }
    return f
}

typealias SLSMainConnectionID_t = @convention(c) () -> Int32
typealias SLSCopyManagedDisplaySpaces_t = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias SLSGetActiveSpace_t = @convention(c) (Int32) -> UInt64
typealias SLSCopySpacesForWindows_t = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
typealias SLSSpaceGetType_t = @convention(c) (Int32, UInt64) -> Int32
typealias SLSSpaceSetType_t = @convention(c) (Int32, UInt64, Int32) -> Int32
typealias SLSSpaceCreate_t = @convention(c) (Int32, UnsafeRawPointer?, CFDictionary) -> UInt64
typealias SLSSpaceSetCompatID_t = @convention(c) (Int32, UInt64, Int32) -> Int32
typealias SLSSetWindowListWorkspace_t = @convention(c) (Int32, UnsafePointer<UInt32>, Int32, Int32) -> Int32

// MARK: - Mach-O local symbol resolution (dlsym cannot see file-local C++ symbols)
//
// Offsets confirmed against mach-o/loader.h and mach-o/nlist.h, and confirmed by a working
// probe on this exact machine (macOS 26.5.2 arm64) this session.

func machoFindLocalSymbol(imageContains needle: String, symbol: String) -> UnsafeMutableRawPointer? {
    let count = _dyld_image_count()
    for i in 0..<count {
        guard let cName = _dyld_get_image_name(i) else { continue }
        guard String(cString: cName).contains(needle) else { continue }
        guard let headerPtr = _dyld_get_image_header(i) else { continue }
        let slide = _dyld_get_image_vmaddr_slide(i)
        let hdr = UnsafeRawPointer(headerPtr)

        let ncmds = hdr.load(fromByteOffset: 16, as: UInt32.self)
        var offset = 32
        var symoff: UInt32 = 0, nsyms: UInt32 = 0, stroff: UInt32 = 0
        var linkeditVmaddr: UInt64 = 0, linkeditFileoff: UInt64 = 0
        var haveSymtab = false, haveLinkedit = false

        for _ in 0..<ncmds {
            let cmd = hdr.load(fromByteOffset: offset, as: UInt32.self)
            let cmdsize = hdr.load(fromByteOffset: offset + 4, as: UInt32.self)
            if cmd == 0x19 { // LC_SEGMENT_64
                var nameBytes = [UInt8](repeating: 0, count: 16)
                for j in 0..<16 {
                    nameBytes[j] = hdr.load(fromByteOffset: offset + 8 + j, as: UInt8.self)
                }
                let end = nameBytes.firstIndex(of: 0) ?? nameBytes.count
                let segname = String(decoding: nameBytes[0..<end], as: UTF8.self)
                if segname == "__LINKEDIT" {
                    linkeditVmaddr = hdr.load(fromByteOffset: offset + 24, as: UInt64.self)
                    linkeditFileoff = hdr.load(fromByteOffset: offset + 40, as: UInt64.self)
                    haveLinkedit = true
                }
            } else if cmd == 0x2 { // LC_SYMTAB
                symoff = hdr.load(fromByteOffset: offset + 8, as: UInt32.self)
                nsyms = hdr.load(fromByteOffset: offset + 12, as: UInt32.self)
                stroff = hdr.load(fromByteOffset: offset + 16, as: UInt32.self)
                haveSymtab = true
            }
            offset += Int(cmdsize)
        }
        guard haveSymtab, haveLinkedit else { continue }

        let base = Int(linkeditVmaddr) + slide - Int(linkeditFileoff)
        guard let symtabBase = UnsafeRawPointer(bitPattern: base + Int(symoff)),
              let strtabBase = UnsafeRawPointer(bitPattern: base + Int(stroff)) else { continue }

        for k in 0..<Int(nsyms) {
            let entry = symtabBase.advanced(by: k * 16)
            let strx = entry.load(fromByteOffset: 0, as: UInt32.self)
            if strx == 0 { continue }
            let value = entry.load(fromByteOffset: 8, as: UInt64.self)
            let cstr = strtabBase.advanced(by: Int(strx)).assumingMemoryBound(to: CChar.self)
            if String(cString: cstr) == symbol {
                return UnsafeMutableRawPointer(bitPattern: Int(value) + slide)
            }
        }
    }
    return nil
}

let asyncSymbolName =
    "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"
let syncSymbolName =
    "__ZL54_SLSPerformSynchronousBridgedWindowManagementOperationP46SLSSynchronousBridgedWindowManagementOperation"

typealias PerformAsync_t = @convention(c) (UnsafeRawPointer) -> Int64
typealias PerformSync_t = @convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?

func performAsyncPointer() -> PerformAsync_t? {
    guard let p = machoFindLocalSymbol(imageContains: "SkyLight", symbol: asyncSymbolName) else { return nil }
    return unsafeBitCast(p, to: PerformAsync_t.self)
}

func performSyncPointer() -> PerformSync_t? {
    guard let p = machoFindLocalSymbol(imageContains: "SkyLight", symbol: syncSymbolName) else { return nil }
    return unsafeBitCast(p, to: PerformSync_t.self)
}

// MARK: - objc_msgSend, one typed entry point per call site (Swift cannot call it variadically)
//
// Obtain one untyped function pointer via dlsym on the process's own global symbol table (libobjc
// is already linked in) and reinterpret it per call site with the exact signature needed. Multiple
// `@_silgen_name("objc_msgSend")` declarations were tried first and rejected: the -O SIL optimizer
// conflates their distinct signatures under the one shared symbol name, producing a function-type
// mismatch at every call site (confirmed by compiling). Independent `let` bindings via dlsym, the
// same pattern used for every SkyLight symbol above, do not have this problem.
guard let processHandle = dlopen(nil, RTLD_NOW), let objcMsgSendRaw = dlsym(processHandle, "objc_msgSend") else {
    failExit(3, ["error": "symbol objc_msgSend unavailable"])
}
let msgSendAlloc = unsafeBitCast(objcMsgSendRaw, to: (@convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?).self)
let msgSendInitWindowsSpace = unsafeBitCast(objcMsgSendRaw, to: (@convention(c) (AnyObject, Selector, CFArray, UInt64) -> Unmanaged<AnyObject>?).self)
let msgSendInitOptionsValues = unsafeBitCast(objcMsgSendRaw, to: (@convention(c) (AnyObject, Selector, CFDictionary, CFDictionary) -> Unmanaged<AnyObject>?).self)
let msgSendInitSpaceID = unsafeBitCast(objcMsgSendRaw, to: (@convention(c) (AnyObject, Selector, UInt64) -> Unmanaged<AnyObject>?).self)
let msgSendGetSpaceID = unsafeBitCast(objcMsgSendRaw, to: (@convention(c) (AnyObject, Selector) -> UInt64).self)

let allocSel = Selector(("alloc"))

// Alloc borrows the returned pointer (takeUnretainedValue): ownership is meant to be consumed by
// the subsequent init call, whose result is what we take real (retained) ownership of. Treating
// both alloc and init as separately "retained" would double-count a single alloc/init pair.
func allocInstance(of className: String) -> AnyObject? {
    guard let cls = NSClassFromString(className) else { return nil }
    return msgSendAlloc(cls, allocSel)?.takeUnretainedValue()
}

// MARK: - Symbol bindings (evaluated once, in order, before any subcommand runs)

guard let skyLightHandle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
    failExit(3, ["error": "symbol SkyLight framework unavailable"])
}

let SLSMainConnectionID = requireSym(skyLightHandle, "SLSMainConnectionID", as: SLSMainConnectionID_t.self)
let SLSCopyManagedDisplaySpaces = requireSym(skyLightHandle, "SLSCopyManagedDisplaySpaces", as: SLSCopyManagedDisplaySpaces_t.self)
let SLSGetActiveSpace = requireSym(skyLightHandle, "SLSGetActiveSpace", as: SLSGetActiveSpace_t.self)
let SLSCopySpacesForWindows = requireSym(skyLightHandle, "SLSCopySpacesForWindows", as: SLSCopySpacesForWindows_t.self)
let SLSSpaceGetType = requireSym(skyLightHandle, "SLSSpaceGetType", as: SLSSpaceGetType_t.self)
let SLSSpaceSetType = requireSym(skyLightHandle, "SLSSpaceSetType", as: SLSSpaceSetType_t.self)
let SLSSpaceCreate = requireSym(skyLightHandle, "SLSSpaceCreate", as: SLSSpaceCreate_t.self)
let SLSSpaceSetCompatID = requireSym(skyLightHandle, "SLSSpaceSetCompatID", as: SLSSpaceSetCompatID_t.self)
let SLSSetWindowListWorkspace = requireSym(skyLightHandle, "SLSSetWindowListWorkspace", as: SLSSetWindowListWorkspace_t.self)

// CoreGraphics private/undocumented CGEvent field numbers (55, 110, 123, 124, 129, 132) are not
// among CGEventField's declared cases, so Swift's closed enum init?(rawValue:) rejects them. dlsym
// the raw C setters instead, typed with a plain UInt32 field parameter — this matches the actual
// C ABI exactly (CGEventField is a uint32_t typedef) and sidesteps the Swift-only restriction.
// The same module-visibility gap affects CGDisplayCreateUUIDFromDisplayID, so it is dlsym'd too.
guard let coreGraphicsHandle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else {
    failExit(3, ["error": "symbol CoreGraphics framework unavailable"])
}
typealias CGEventSetIntegerValueField_t = @convention(c) (CGEvent, UInt32, Int64) -> Void
typealias CGEventSetDoubleValueField_t = @convention(c) (CGEvent, UInt32, Double) -> Void
typealias CGDisplayCreateUUIDFromDisplayID_t = @convention(c) (UInt32) -> Unmanaged<CFUUID>?
let cgEventSetIntegerValueField = requireSym(coreGraphicsHandle, "CGEventSetIntegerValueField", as: CGEventSetIntegerValueField_t.self)
let cgEventSetDoubleValueField = requireSym(coreGraphicsHandle, "CGEventSetDoubleValueField", as: CGEventSetDoubleValueField_t.self)
// Not required: absent on this build (confirmed empirically), so mainDisplayUUID() degrades to
// the plan's own stated fallback — the first display entry, correct whenever there is one display.
let cgDisplayCreateUUIDFromDisplayID: CGDisplayCreateUUIDFromDisplayID_t? =
    dlfunc(coreGraphicsHandle, "CGDisplayCreateUUIDFromDisplayID", as: CGDisplayCreateUUIDFromDisplayID_t.self)

let cid = SLSMainConnectionID()

// MARK: - Space inventory

struct SpaceEntry { let index: Int; let id: UInt64 }
struct Inventory { let display: String; let current: UInt64; let currentIndex: Int; let spaces: [SpaceEntry] }

func mainDisplayUUID() -> String? {
    guard let fn = cgDisplayCreateUUIDFromDisplayID else { return nil }
    let displayID = CGMainDisplayID()
    guard let uuidRef = fn(displayID) else { return nil }
    let uuid = uuidRef.takeRetainedValue()
    guard let cfStr = CFUUIDCreateString(nil, uuid) else { return nil }
    return cfStr as String
}

// Include only user spaces (type == 0); native-fullscreen/tiled spaces sit inline in the raw
// "Spaces" array but macOS numbers only user desktops, so filtering is what makes `index` agree
// with Mission Control ordering. Every <spaceIndex> argument in this CLI is a user-desktop ordinal.
func readInventory() -> Inventory? {
    guard let arrRef = SLSCopyManagedDisplaySpaces(cid) else { return nil }
    let displays = arrRef.takeRetainedValue() as NSArray
    let active = SLSGetActiveSpace(cid)
    guard displays.count > 0 else { return nil }

    var chosenEntry = mainDisplayUUID().flatMap { uuid in
        displays.first { ($0 as? NSDictionary)?["Display Identifier"] as? String == uuid } as? NSDictionary
    }
    if chosenEntry == nil {
        chosenEntry = displays.firstObject as? NSDictionary
    }
    guard let entry = chosenEntry, let displayId = entry["Display Identifier"] as? String,
          let rawSpaces = entry["Spaces"] as? NSArray else { return nil }

    var userSpaces: [SpaceEntry] = []
    for spaceAny in rawSpaces {
        guard let spaceDict = spaceAny as? NSDictionary else { continue }
        let type = (spaceDict["type"] as? NSNumber)?.int32Value ?? 0
        guard type == 0 else { continue }
        var sid: UInt64? = (spaceDict["ManagedSpaceID"] as? NSNumber)?.uint64Value
        if sid == nil { sid = (spaceDict["id64"] as? NSNumber)?.uint64Value }
        guard let spaceId = sid else { continue }
        guard SLSSpaceGetType(cid, spaceId) == 0 else { continue }
        userSpaces.append(SpaceEntry(index: userSpaces.count + 1, id: spaceId))
    }

    let currentIndex = userSpaces.first(where: { $0.id == active })?.index ?? 0
    return Inventory(display: displayId, current: active, currentIndex: currentIndex, spaces: userSpaces)
}

func inventoryJSON(_ inv: Inventory, extra: [String: Any] = [:]) -> [String: Any] {
    var obj: [String: Any] = [
        "display": inv.display,
        "current": NSNumber(value: inv.current),
        "currentIndex": inv.currentIndex,
        "spaces": inv.spaces.map { ["index": $0.index, "id": NSNumber(value: $0.id)] as [String: Any] },
    ]
    for (k, v) in extra { obj[k] = v }
    return obj
}

// MARK: - space-focus: Dock-swipe gesture, self-calibrating direction

func stateDir() -> String {
    let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".local/state/quilt")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

func signPath() -> String { stateDir() + "/swipe-sign" }

func readSign() -> Double {
    guard let s = try? String(contentsOfFile: signPath(), encoding: .utf8) else { return 1.0 }
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == "-1" ? -1.0 : 1.0
}

func persistSign(_ sign: Double) {
    try? (sign < 0 ? "-1" : "1").write(toFile: signPath(), atomically: true, encoding: .utf8)
}

func postDockSwipeGesture(sign: Double) {
    guard let event = CGEvent(source: nil) else { return }
    cgEventSetIntegerValueField(event, 55, 30)  // kCGSEventTypeField = kCGSEventDockControl
    cgEventSetIntegerValueField(event, 110, 23) // kCGEventGestureHIDType = kIOHIDEventTypeDockSwipe
    cgEventSetIntegerValueField(event, 123, 1)  // kCGEventGestureSwipeMotion = horizontal
    cgEventSetDoubleValueField(event, 124, sign)
    cgEventSetDoubleValueField(event, 129, sign * 9999.0)
    cgEventSetIntegerValueField(event, 132, 1) // phase began
    event.post(tap: .cgSessionEventTap)
    cgEventSetIntegerValueField(event, 132, 4) // phase ended
    event.post(tap: .cgSessionEventTap)
}

func pollActiveSpaceChanged(from previous: UInt64, timeoutMs: Int) -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    while Date() < deadline {
        if SLSGetActiveSpace(cid) != previous { return true }
        usleep(20_000)
    }
    return SLSGetActiveSpace(cid) != previous
}

func cmdSpaceFocus(_ targetIndex: Int) {
    guard let inv0 = readInventory() else { failExit(1, ["error": "main display not found"]) }
    if inv0.currentIndex == targetIndex {
        printJSON(["focused": true, "index": inv0.currentIndex, "id": NSNumber(value: inv0.current), "steps": 0])
        exit(0)
    }

    var sign = readSign()
    var steps = 0
    var lastIndex = inv0.currentIndex
    var lastActive = inv0.current

    while steps < 16 {
        let direction: Double = (targetIndex > lastIndex) ? 1.0 : -1.0
        postDockSwipeGesture(sign: sign * direction)
        var moved = pollActiveSpaceChanged(from: lastActive, timeoutMs: 600)

        if !moved {
            sign = -sign
            persistSign(sign)
            postDockSwipeGesture(sign: sign * direction)
            moved = pollActiveSpaceChanged(from: lastActive, timeoutMs: 600)
            if !moved {
                failExit(1, ["focused": false,
                              "error": "gesture ignored — grant Accessibility to the app that runs quiltctl (your terminal for manual runs, or the key-binding tool once installed)"])
            }
        }

        guard let inv = readInventory() else { failExit(1, ["error": "main display not found"]) }
        steps += 1
        if inv.currentIndex == targetIndex {
            printJSON(["focused": true, "index": inv.currentIndex, "id": NSNumber(value: inv.current), "steps": steps])
            exit(0)
        }
        if abs(inv.currentIndex - targetIndex) >= abs(lastIndex - targetIndex) {
            sign = -sign
            persistSign(sign)
        }
        lastIndex = inv.currentIndex
        lastActive = inv.current
    }
    failExit(1, ["focused": false, "error": "did not converge"])
}

// MARK: - spaces

func cmdSpaces() {
    guard let inv = readInventory() else {
        failExit(1, ["error": "main display not found"])
    }
    printJSON(inventoryJSON(inv))
    exit(0)
}

// MARK: - move

func cmdMove(_ wid: UInt32, _ targetIndex: Int) {
    guard let inv = readInventory() else { failExit(1, ["error": "main display not found"]) }
    guard let target = inv.spaces.first(where: { $0.index == targetIndex }) else {
        failExit(64, ["error": "space index \(targetIndex) out of range"])
    }

    let windowsArray = [NSNumber(value: wid)] as CFArray

    func membershipContainsTarget() -> Bool {
        guard let ref = SLSCopySpacesForWindows(cid, 0x7, windowsArray) else { return false }
        let spaces = (ref.takeRetainedValue() as NSArray).compactMap { ($0 as? NSNumber)?.uint64Value }
        return spaces.contains(target.id)
    }

    if membershipContainsTarget() {
        printJSON(["moved": true, "noop": true, "tier": 0])
        exit(0)
    }

    // Tier 1: bridged asynchronous move operation.
    if let instance = allocInstance(of: "SLSBridgedMoveWindowsToManagedSpaceOperation"),
       let op = msgSendInitWindowsSpace(instance, Selector(("initWithWindows:spaceID:")), windowsArray, target.id)?.takeRetainedValue(),
       let performAsync = performAsyncPointer() {
        let opPtr = Unmanaged.passUnretained(op).toOpaque()
        _ = performAsync(opPtr)
        for _ in 0..<20 {
            usleep(25_000)
            if membershipContainsTarget() {
                printJSON(["moved": true, "noop": false, "tier": 1])
                exit(0)
            }
        }
    }

    // Tier 3: compat-ID fallback (the pre-14.5 mechanism this space-management approach falls back to).
    let magic: Int32 = 0x79616265
    _ = SLSSpaceSetCompatID(cid, target.id, magic)
    var widVar = wid
    withUnsafePointer(to: &widVar) { ptr in
        _ = SLSSetWindowListWorkspace(cid, ptr, 1, magic)
    }
    _ = SLSSpaceSetCompatID(cid, target.id, 0)
    for _ in 0..<20 {
        usleep(25_000)
        if membershipContainsTarget() {
            printJSON(["moved": true, "noop": false, "tier": 3])
            exit(0)
        }
    }

    failExit(1, ["moved": false, "noop": false, "tier": 0,
                 "error": "neither the bridged operation nor the compat-ID fallback moved the window"])
}

// MARK: - ensure

func cmdEnsure(_ count: Int) {
    guard var currentInv = readInventory() else { failExit(1, ["error": "main display not found"]) }
    var created = 0
    var consecutiveFailures = 0

    while currentInv.spaces.count < count && consecutiveFailures < 3 {
        var grew = false

        // Tier A: bridged synchronous create — preferred, since on macOS 15+ space bookkeeping
        // lives behind the window-management bridge, which is why the bridged move works where
        // the raw call does not.
        if let instance = allocInstance(of: "SLSBridgedSpaceCreateOperation") {
            let options = ["type": 0, "uuid": UUID().uuidString] as CFDictionary
            let values = [:] as CFDictionary
            if let op = msgSendInitOptionsValues(instance, Selector(("initWithOptions:values:")), options, values)?.takeRetainedValue(),
               let performSync = performSyncPointer() {
                let opPtr = Unmanaged.passUnretained(op).toOpaque()
                if let resultPtr = performSync(opPtr) {
                    let resultObj = Unmanaged<AnyObject>.fromOpaque(resultPtr).takeRetainedValue()
                    let newId = msgSendGetSpaceID(resultObj, Selector(("spaceID")))
                    if newId != 0, let refreshed = readInventory(), refreshed.spaces.count > currentInv.spaces.count {
                        currentInv = refreshed
                        created += 1
                        grew = true
                    }
                }
            }
        }

        // Tier B: raw SLSSpaceCreate + SLSSpaceSetType, retried once with the display UUID.
        if !grew {
            for useDisplayUUID in [false, true] {
                let opts = ["type": 0, "uuid": UUID().uuidString] as CFDictionary
                var newSid: UInt64
                if useDisplayUUID, let duuid = mainDisplayUUID() {
                    let cfStr = duuid as CFString
                    let rawPtr = Unmanaged.passUnretained(cfStr).toOpaque()
                    newSid = SLSSpaceCreate(cid, rawPtr, opts)
                } else {
                    newSid = SLSSpaceCreate(cid, nil, opts)
                }
                if newSid != 0, SLSSpaceGetType(cid, newSid) != 0 {
                    _ = SLSSpaceSetType(cid, newSid, 0)
                }
                if let refreshed = readInventory(), refreshed.spaces.count > currentInv.spaces.count {
                    currentInv = refreshed
                    created += 1
                    grew = true
                    break
                }
            }
        }

        // Tier C: killall Dock forces it to rebuild its space list from WindowServer.
        if !grew {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            task.arguments = ["Dock"]
            try? task.run()
            task.waitUntilExit()
            usleep(1_500_000)
            if let refreshed = readInventory(), refreshed.spaces.count > currentInv.spaces.count {
                currentInv = refreshed
                created += 1
                grew = true
            }
        }

        consecutiveFailures = grew ? 0 : consecutiveFailures + 1
    }

    let obj = inventoryJSON(currentInv, extra: ["created": created])
    if currentInv.spaces.count >= count {
        printJSON(obj)
        exit(0)
    } else {
        FileHandle.standardError.write(
            "create-space unsupported on this build; create \(count) spaces once in Mission Control (they persist)\n"
                .data(using: .utf8)!)
        printJSON(obj)
        exit(2)
    }
}

// MARK: - destroy

func cmdDestroy(_ targetIndex: Int) {
    guard let inv = readInventory() else { failExit(1, ["error": "main display not found"]) }
    guard let target = inv.spaces.first(where: { $0.index == targetIndex }) else {
        failExit(64, ["error": "space index \(targetIndex) out of range"])
    }
    if target.id == inv.current {
        failExit(64, ["destroyed": false, "error": "refusing to destroy the active space"])
    }
    if inv.spaces.count <= 1 {
        failExit(64, ["destroyed": false, "error": "refusing to destroy the only remaining space"])
    }

    guard let instance = allocInstance(of: "SLSBridgedSpaceDestroyOperation"),
          let op = msgSendInitSpaceID(instance, Selector(("initWithSpaceID:")), target.id)?.takeRetainedValue(),
          let performSync = performSyncPointer() else {
        failExit(2, ["error": "class SLSBridgedSpaceDestroyOperation unavailable"])
    }
    let opPtr = Unmanaged.passUnretained(op).toOpaque()
    _ = performSync(opPtr)

    if let refreshed = readInventory(), refreshed.spaces.count < inv.spaces.count {
        printJSON(inventoryJSON(refreshed))
        exit(0)
    }
    failExit(1, ["destroyed": false, "error": "space count did not shrink"])
}

// MARK: - argv dispatch

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: quiltctl <spaces|space-focus|move|ensure|destroy> [args]\n".data(using: .utf8)!)
    exit(64)
}

switch args[1] {
case "spaces":
    cmdSpaces()
case "space-focus":
    guard args.count >= 3, let idx = Int(args[2]) else { failExit(64, ["error": "usage: quiltctl space-focus <index>"]) }
    cmdSpaceFocus(idx)
case "move":
    guard args.count >= 4, let wid = UInt32(args[2]), let idx = Int(args[3]) else {
        failExit(64, ["error": "usage: quiltctl move <windowID> <spaceIndex>"])
    }
    cmdMove(wid, idx)
case "ensure":
    guard args.count >= 3, let count = Int(args[2]) else { failExit(64, ["error": "usage: quiltctl ensure <count>"]) }
    cmdEnsure(count)
case "destroy":
    guard args.count >= 3, let idx = Int(args[2]) else { failExit(64, ["error": "usage: quiltctl destroy <spaceIndex>"]) }
    cmdDestroy(idx)
default:
    failExit(64, ["error": "unknown subcommand \(args[1])"])
}
