import AppKit
import Foundation

enum FeatureSendSource {
  case screenshot
  case website
}

struct PostSendActions {
  var openChat: Bool
  var copyToClipboard: Bool
  var playAudio: Bool
}

@MainActor
enum PostSendActionHandler {
  static func apply(
    actions: PostSendActions,
    response: String,
    showPanel: () -> Void
  ) {
    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    if actions.openChat {
      showPanel()
    }

    if actions.copyToClipboard {
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(trimmed, forType: .string)
    }

    if actions.playAudio {
      let speechText = SpeechTextShrunker.shrinkForSpeech(trimmed)
      SpeechService.shared.speak(speechText)
    }
  }
}
