import AppKit
import SwiftUI
import SixAxisCore

/// Measures what makes the app feel heavy, for scripts/budget-check.py: SIXAXIS_BUDGET_TEST=1
/// Prints BUDGET <key> <value> lines (time to first frame, memory, toolbar widths).
@MainActor
enum BudgetProbe {
    static func report(_ key: String, _ value: Double) { print("BUDGET \(key) \(Int(value.rounded()))") }

    static func run(_ editor: Editor) async {
        // Launch → first frame on screen (from the kernel's process start time).
        let end = Date().addingTimeInterval(20)
        while firstFrameRenderer() == nil && Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
        // A sleeping or locked display presents no frames: then the start time can't be rated.
        if firstFrameRenderer() != nil {
            report("startup_ms", (Date().timeIntervalSince1970 - processStart()) * 1000)
        } else {
            print("BUDGET note no frame on screen (display asleep?) – start time not rated")
        }
        report("memory_empty_mb", footprintMB())

        // Toolbars: width needed by the model and the sketch toolbar (must fit a 13" MacBook window).
        report("toolbar_model_pt", width(of: Ribbon(editor: editor)))
        editor.beginSketch(on: .xy)
        try? await Task.sleep(nanoseconds: 300_000_000)
        report("toolbar_sketch_pt", width(of: Ribbon(editor: editor)))
        editor.finishSketch()

        // Memory after opening every example (the last one stays open); also catches leaks between documents.
        for example in Examples.all {
            editor.openExample(example)
            while editor.isRebuilding { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        report("memory_example_mb", footprintMB())
        if let dir = ProcessInfo.processInfo.environment["SIXAXIS_SNAPSHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            await captureLive(to: dir)
        }
    }

    /// The frame as it reaches the screen (not the offscreen snapshot path).
    private static func captureLive(to dir: String) async {
        func find(_ v: NSView?) -> ViewportNSView? {
            guard let v else { return nil }
            if let vp = v as? ViewportNSView { return vp }
            for sub in v.subviews { if let f = find(sub) { return f } }
            return nil
        }
        guard let vp = NSApp.windows.lazy.compactMap({ find($0.contentView) }).first, let r = vp.renderer else { return }
        vp.framebufferOnly = false
        var image: CGImage?
        r.captureNextFrame = { tex in
            var bytes = [UInt8](repeating: 0, count: tex.width * tex.height * 4)
            tex.getBytes(&bytes, bytesPerRow: tex.width * 4, from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0)
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            image = CGImage(width: tex.width, height: tex.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: tex.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        vp.needsDisplay = true   // request a frame
        let end = Date().addingTimeInterval(3)
        while image == nil && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        if let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("live-frame.png"))
            print("BUDGET live_frame_px \(image.width)")
        }
    }

    private static func width<V: View>(of view: V) -> Double {
        let host = NSHostingView(rootView: view.fixedSize())
        return host.fittingSize.width
    }

    private static func firstFrameRenderer() -> Renderer? {
        func find(_ v: NSView?) -> ViewportNSView? {
            guard let v else { return nil }
            if let vp = v as? ViewportNSView { return vp }
            for sub in v.subviews { if let f = find(sub) { return f } }
            return nil
        }
        guard let r = NSApp.windows.lazy.compactMap({ find($0.contentView)?.renderer }).first else { return nil }
        r.stats.lock.lock(); defer { r.stats.lock.unlock() }
        return r.stats.frames > 0 ? r : nil
    }

    private static func processStart() -> TimeInterval {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let t = info.kp_proc.p_un.__p_starttime
        return TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000
    }

    /// Same number Activity Monitor shows as "Memory".
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
