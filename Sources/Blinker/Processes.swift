import Darwin
import Foundation

/// One process we own, read straight from the kernel (no `ps`, no `lsof`).
struct Proc {
    let pid: pid_t
    let ppid: pid_t
    let started: Date
    let name: String
    var argv: [String] = []
    var exe = ""
    var cwd = ""
}

/// Read-only views of the process table, limited to the current user's processes.
enum Processes {
    static func table() -> [pid_t: Proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        let stride = MemoryLayout<kinfo_proc>.stride
        var list: [kinfo_proc] = []
        var size = 0
        // Processes can appear between sizing and reading. Retry with more room rather than
        // returning nothing, which would show up as "an unknown program is asking".
        for attempt in 1...4 {
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [:] }
            size += size / 4 * attempt
            list = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
            size = list.count * stride // never claim more room than the array really has
            if sysctl(&mib, 4, &list, &size, nil, 0) == 0 { break }
            guard errno == ENOMEM, attempt < 4 else { return [:] }
        }

        var result: [pid_t: Proc] = [:]
        for var k in list.prefix(size / stride) {
            let t = k.kp_proc.p_starttime
            let name = withUnsafeBytes(of: &k.kp_proc.p_comm) { cString($0) }
            result[k.kp_proc.p_pid] = Proc(
                pid: k.kp_proc.p_pid,
                ppid: k.kp_eproc.e_ppid,
                started: Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1e6),
                name: name
            )
        }
        return result
    }

    /// Fills in argv, executable path and working directory.
    static func detailed(_ proc: Proc) -> Proc {
        var p = proc
        p.argv = arguments(proc.pid)
        if p.argv.isEmpty { p.argv = [proc.name] }
        p.exe = executable(proc.pid)
        p.cwd = workingDirectory(proc.pid)
        return p
    }

    private static let argMax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctl(&mib, 2, &value, &size, nil, 0) == 0 ? Int(value) : 1 << 20
    }()

    /// argv via KERN_PROCARGS2: exactly argc strings, capped at 256. The process can rewrite this
    /// memory, so treat it as the process's own claim. We never read past it into the environment
    /// on purpose, though a process that strips its NULs could make its environment look like argv.
    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argMax
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size, buffer[i] != 0 { i += 1 } // exec path
        while i < size, buffer[i] == 0 { i += 1 } // padding
        var args: [String] = []
        while args.count < argc, args.count < 256, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    static func executable(_ pid: pid_t) -> String {
        var buf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        let length = Int(proc_pidpath(pid, &buf, UInt32(buf.count)))
        return length > 0 ? String(decoding: buf[..<length], as: UTF8.self) : ""
    }

    static func workingDirectory(_ pid: pid_t) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { cString($0) }
    }

    /// Unix-domain sockets a process holds: the path it listens on, or the path it connected to.
    static func unixSockets(_ pid: pid_t) -> [(bound: String, peer: String)] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)
        var filled: Int32 = 0
        while true {
            let capacity = Int32(fds.count * stride)
            filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, capacity)
            guard filled > 0 else { return [] }
            if filled < capacity || fds.count >= 1 << 16 { break }
            fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fds.count * 4)
        }
        var result: [(String, String)] = []
        let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                  info.psi.soi_kind == SOCKINFO_UN else { continue }
            var un = info.psi.soi_proto.pri_un
            let bound = withUnsafeBytes(of: &un.unsi_addr.ua_sun.sun_path) { cString($0) }
            let peer = withUnsafeBytes(of: &un.unsi_caddr.ua_sun.sun_path) { cString($0) }
            if !bound.isEmpty || !peer.isEmpty { result.append((bound, peer)) }
        }
        return result
    }

    /// A C string from a fixed-size buffer that may not be NUL-terminated.
    static func cString(_ raw: UnsafeRawBufferPointer) -> String {
        let bytes = raw.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
