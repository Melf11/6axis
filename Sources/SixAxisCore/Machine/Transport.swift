import Foundation

/// A byte connection to a controller: USB serial or the built-in simulator.
public protocol MachineTransport: AnyObject, Sendable {
    /// Called with each complete line from the controller (on the transport's own queue).
    var onLine: (@Sendable (String) -> Void)? { get set }
    var name: String { get }
    func send(_ bytes: [UInt8])
    func close()
}

extension MachineTransport {
    public func send(line: String) { send(Array((line + "\n").utf8)) }
}

/// USB serial port (FTDI, CH340, CP210x and Arduino CDC are built into macOS), 115200 baud 8N1.
public final class SerialPort: MachineTransport, @unchecked Sendable {
    public var onLine: (@Sendable (String) -> Void)?
    public let name: String
    private let fd: Int32
    private let queue = DispatchQueue(label: "app.6axis.serial")
    private var source: DispatchSourceRead?
    private var buffer = [UInt8]()

    /// Controllers on USB: /dev/cu.usbserial*, cu.usbmodem*, cu.wchusbserial*, cu.SLAB_USBtoUART …
    public static func available() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return items.filter { $0.hasPrefix("cu.") && ($0.contains("usb") || $0.contains("wch") || $0.contains("SLAB") || $0.contains("serial")) }
            .sorted().map { "/dev/" + $0 }
    }

    public init(path: String, baud: speed_t = 115200) throws {
        name = (path as NSString).lastPathComponent
        fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw KernelError(verbatim: String(localized: "Anschluss \(path) lässt sich nicht öffnen")) }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, baud)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CRTSCTS)
        tcsetattr(fd, TCSANOW, &t)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.resume()
        source = src
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 512)
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else { return }
        for b in chunk.prefix(n) {
            if b == 0x0A {
                let line = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                buffer.removeAll()
                if !line.isEmpty { onLine?(line) }
            } else if b != 0x0D {
                buffer.append(b)
            }
        }
    }

    public func send(_ bytes: [UInt8]) {
        queue.async { [fd] in
            var offset = 0
            while offset < bytes.count {
                let n = bytes[offset...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
                if n <= 0 { usleep(1000); continue }
                offset += n
            }
        }
    }

    public func close() {
        source?.cancel()
        source = nil
        Darwin.close(fd)
    }

    deinit { if source != nil { close() } }
}
