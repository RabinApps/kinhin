import Foundation
import KinhinKit

/// Reads one line from stdin. On a terminal the echo is switched off while
/// typing (the prompt promises hidden input) and restored afterwards; piped
/// input is read as-is.
func readSecretLine() -> String? {
    let fd = STDIN_FILENO
    var original = termios()
    let isTerminal = isatty(fd) == 1 && tcgetattr(fd, &original) == 0
    if isTerminal {
        var silent = original
        silent.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(fd, TCSANOW, &silent)
    }
    defer {
        if isTerminal {
            tcsetattr(fd, TCSANOW, &original)
            print("")  // the Enter keypress was not echoed
        }
    }
    return readLine(strippingNewline: true)
}
