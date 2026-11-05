import CoreServices
import Foundation

/// FSEvents on some paths (files or directories, watched recursively), calling back on the main
/// actor with the paths that changed. Coalesced over 0.2 s, so a burst of writes is one call.
@MainActor
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void

    init(paths: [String], onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            MainActor.assumeIsolated { watcher.onChange(changed) }
        }
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            FSEventStreamCreateFlags(flags)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
