import Foundation

/// Exclusive advisory lock that guarantees one daemon per support directory.
///
/// A ping check alone can't do this: two daemons started together both see
/// "nobody home", and `RPCServer` unlinks any existing socket before binding,
/// so the second silently takes the first one's place while both keep scaling
/// VMs. `flock` is atomic and the kernel drops it when the process dies, so
/// there is no stale-lock cleanup.
final class DaemonLock {
    static var defaultURL: URL { Paths.appSupport.appendingPathComponent("daemon.lock") }

    private let fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        // Closing the descriptor releases the lock; a failed close leaves nothing to recover.
        close(fd)
    }

    /// Takes the lock or throws `DaemonError.alreadyRunning` when another
    /// process (or another `DaemonLock` in this one) holds it. Hold the
    /// returned object for as long as the daemon should own the fleet.
    static func acquire(at url: URL = defaultURL) throws -> DaemonLock {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw Daemon.DaemonError.lockFailed("cannot open \(url.path): \(String(cString: strerror(errno)))")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { throw Daemon.DaemonError.alreadyRunning }
            throw Daemon.DaemonError.lockFailed("cannot lock \(url.path): \(String(cString: strerror(code)))")
        }
        // The pid is diagnostic only; the lock itself is the source of truth.
        let pid = Data("\(getpid())\n".utf8)
        if ftruncate(fd, 0) == 0 {
            _ = pid.withUnsafeBytes { pwrite(fd, $0.baseAddress, pid.count, 0) }
        }
        return DaemonLock(fd: fd)
    }
}
