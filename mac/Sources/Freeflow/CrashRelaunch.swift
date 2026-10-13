import Darwin
import Foundation

/// Best-effort crash recovery. whisper.cpp can trap (SIGTRAP) on some audio;
/// rather than let the menubar app vanish and the hotkey go dead, we re-exec
/// ourselves on a fatal signal so it comes right back (~2s). Typed text is already
/// in the target field (injection is incremental), so this only restores the app.
///
/// No crash-loop: the audio that triggered the trap isn't replayed on relaunch.
enum CrashRelaunch {
    // C-accessible globals — a signal handler is a bare C function and can't
    // capture Swift state, so the exec target is prepared up front.
    private static var path: UnsafeMutablePointer<CChar>!
    private static var argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>!

    static func install() {
        // Don't fight a debugger — breakpoints raise SIGTRAP, which we'd re-exec on.
        guard !isBeingDebugged() else { return }
        path = strdup(Bundle.main.executablePath ?? CommandLine.arguments[0])
        argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 2)
        argv[0] = path
        argv[1] = nil

        let handler: @convention(c) (Int32) -> Void = { _ in
            // async-signal-safe: replace our (corrupt) image with a fresh one.
            _ = execv(CrashRelaunch.path, CrashRelaunch.argv)
            _exit(1)   // exec failed — give up
        }
        for sig in [SIGILL, SIGABRT, SIGFPE, SIGSEGV, SIGBUS, SIGTRAP] {
            signal(sig, handler)
        }
    }

    /// True if an lldb/gdb is attached (P_TRACED), so we don't re-exec on breakpoints.
    private static func isBeingDebugged() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        return sysctl(&mib, 4, &info, &size, nil, 0) == 0 && (info.kp_proc.p_flag & P_TRACED) != 0
    }
}
