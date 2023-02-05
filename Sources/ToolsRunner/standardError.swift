import Foundation

var standardError = StdioOutputStream(file: stderr)

struct StdioOutputStream: TextOutputStream {
    let file: UnsafeMutablePointer<FILE>

    func write(_ string: String) {
        string.withCString { ptr in
            flockfile(file)
            defer {
                funlockfile(file)
            }
            _ = fputs(ptr, file)
            _ = fflush(file)
        }
    }
}
