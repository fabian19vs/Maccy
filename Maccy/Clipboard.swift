import AppKit
import Carbon

class Clipboard {
  typealias OnNewCopyHook = (HistoryItem) -> Void

  public var onNewCopyHooks: [OnNewCopyHook] = []

  private let pasteboard = NSPasteboard.general
  private let timerInterval = 1.0

  // See http://nspasteboard.org for more details.
  private let ignoredTypes: Set = [
    "org.nspasteboard.TransientType",
    "org.nspasteboard.ConcealedType",
    "org.nspasteboard.AutoGeneratedType"
  ]

  private let supportedTypes: Set = [
    NSPasteboard.PasteboardType.fileURL.rawValue,
    NSPasteboard.PasteboardType.png.rawValue,
    NSPasteboard.PasteboardType.string.rawValue,
    NSPasteboard.PasteboardType.tiff.rawValue
  ]

  private var changeCount: Int

  init() {
    changeCount = pasteboard.changeCount
  }

  func onNewCopy(_ hook: @escaping OnNewCopyHook) {
    onNewCopyHooks.append(hook)
  }

  func startListening() {
    Timer.scheduledTimer(timeInterval: timerInterval,
                         target: self,
                         selector: #selector(checkForChangesInPasteboard),
                         userInfo: nil,
                         repeats: true)
  }

  func copy(_ item: HistoryItem, removeFormatting: Bool = false) {
    pasteboard.clearContents()
    var contents = item.getContents()

    if removeFormatting {
      contents = contents.filter({
        NSPasteboard.PasteboardType($0.type) == .string
      })
    }

    for content in contents {
      pasteboard.setData(content.value, forType: NSPasteboard.PasteboardType(content.type))
    }

    if UserDefaults.standard.playSounds {
      NSSound(named: NSSound.Name("knock"))?.play()
    }
  }

  // Based on https://github.com/Clipy/Clipy/blob/develop/Clipy/Sources/Services/PasteService.swift.
  func paste() {
    checkAccessibilityPermissions()

    DispatchQueue.main.async {
      let vCode = UInt16(kVK_ANSI_V)
      let source = CGEventSource(stateID: .combinedSessionState)
      // Disable local keyboard events while pasting
      source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                         state: .eventSuppressionStateSuppressionInterval)

      let keyVDown = CGEvent(keyboardEventSource: source, virtualKey: vCode, keyDown: true)
      let keyVUp = CGEvent(keyboardEventSource: source, virtualKey: vCode, keyDown: false)
      keyVDown?.flags = .maskCommand
      keyVUp?.flags = .maskCommand
      keyVDown?.post(tap: .cgAnnotatedSessionEventTap)
      keyVUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
  }

  @objc
  func checkForChangesInPasteboard() {
    guard pasteboard.changeCount != changeCount else {
      return
    }

    if UserDefaults.standard.ignoreEvents {
      return
    }

    // Some applications add 2 items to pasteboard when copying:
    //   1. The proper meaningful string.
    //   2. The empty item with no data and types.
    // An example of such application is BBEdit.
    // To handle such cases, handle all new pasteboard items,
    // not only the last one.
    // See https://github.com/p0deje/Maccy/issues/78.
    pasteboard.pasteboardItems?.forEach({ item in
      if shouldIgnore(item.types) {
        return
      }

      if item.types.contains(.string) && isEmptyString(item) {
        return
      }

      let contents = item.types.map({ type in
        return HistoryItemContent(type: type.rawValue, value: item.data(forType: type))
      })
      let historyItem = HistoryItem(contents: contents)

      onNewCopyHooks.forEach({ $0(historyItem) })
    })

    changeCount = pasteboard.changeCount
  }

  private func checkAccessibilityPermissions() {
    let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
    AXIsProcessTrustedWithOptions(options)
  }

  private func shouldIgnore(_ types: [NSPasteboard.PasteboardType]) -> Bool {
    let ignoredTypes = self.ignoredTypes.union(UserDefaults.standard.ignoredPasteboardTypes)
    let passedTypes = Set(types.map({ $0.rawValue }))
    return passedTypes.isDisjoint(with: supportedTypes) || !passedTypes.isDisjoint(with: ignoredTypes)

  }

  private func isEmptyString(_ item: NSPasteboardItem) -> Bool {
    guard let string = item.string(forType: .string) else {
      return true
    }

    return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
