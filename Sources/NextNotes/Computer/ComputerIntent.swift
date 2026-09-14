import Foundation

/// Legacy typed representation used by the isolated computer-loop probe.
/// Live Agent turns ask the selected model to choose a computer tool.
enum ComputerIntent: Equatable {
    case inspect
    case activeApp
    case open(String)
    case click(String)
    case type(String)
    case press(String)

}
