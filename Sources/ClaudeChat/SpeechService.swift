import AVFoundation
import ClaudeChatCore
import Observation

/// Reads responses aloud. Picks the best installed voice (Premium > Enhanced > Default) for the
/// response's language, speaks block by block with natural pauses, and can be stopped any time.
@MainActor
@Observable
final class SpeechService: NSObject {
    /// The message currently being read, or a fresh ID for ad-hoc speech (e.g. voice preview).
    private(set) var speakingID: UUID?

    @ObservationIgnored private let settings: AppSettings
    /// A fresh synthesizer per playback: late callbacks from a stopped playback can't touch the new one,
    /// and speaking right after `stopSpeaking` is not dropped.
    @ObservationIgnored private var synthesizer: AVSpeechSynthesizer?
    @ObservationIgnored private var remainingUtterances = 0

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
    }

    var isSpeaking: Bool { speakingID != nil }

    func speak(markdown: String, id: UUID = UUID(), length: SpeechLength? = nil) {
        stop()
        let segments = SpeechScript.segments(fromMarkdown: markdown, length: length ?? settings.speechLength)
        guard !segments.isEmpty else { return }

        let language = SpeechScript.dominantLanguage(of: segments.map(\.text).joined(separator: " "))
        let voice = Self.voice(identifier: settings.speechVoiceIdentifier, language: language)

        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        self.synthesizer = synthesizer
        remainingUtterances = segments.count
        speakingID = id
        for segment in segments {
            let utterance = AVSpeechUtterance(string: segment.text)
            utterance.voice = voice
            utterance.rate = settings.speechRate
            utterance.postUtteranceDelay = segment.pauseAfter
            synthesizer.speak(utterance)
        }
    }

    func toggle(markdown: String, id: UUID) {
        if speakingID == id {
            stop()
        } else {
            speak(markdown: markdown, id: id)
        }
    }

    func stop() {
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
        remainingUtterances = 0
        speakingID = nil
    }

    private func utteranceFinished(by source: ObjectIdentifier) {
        guard let synthesizer, ObjectIdentifier(synthesizer) == source else { return }
        remainingUtterances -= 1
        if remainingUtterances <= 0 {
            self.synthesizer = nil
            speakingID = nil
        }
    }

    // MARK: - Voices

    /// Voices offered in Settings: no novelty voices, best quality first within each language.
    static var selectableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
            .sorted {
                if $0.language != $1.language { return $0.language < $1.language }
                if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
                return $0.name < $1.name
            }
    }

    static func voice(identifier: String, language: String?) -> AVSpeechSynthesisVoice? {
        if !identifier.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: identifier) {
            return chosen
        }
        return bestVoice(for: language ?? AVSpeechSynthesisVoice.currentLanguageCode())
    }

    /// Highest quality voice for a language; the user's region breaks ties (de-CH before de-DE in Switzerland).
    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let base = language.components(separatedBy: "-").first?.lowercased() ?? language
        let region = Locale.current.region?.identifier
        let candidates = selectableVoices.filter { $0.language.lowercased().hasPrefix(base) }
        return candidates.max { lhs, rhs in
            score(lhs, region: region) < score(rhs, region: region)
        } ?? AVSpeechSynthesisVoice(language: language)
    }

    private static func score(_ voice: AVSpeechSynthesisVoice, region: String?) -> Int {
        var score = voice.quality.rawValue * 10
        if let region, voice.language.hasSuffix("-\(region)") { score += 2 }
        return score
    }

    static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Standard"
        }
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let source = ObjectIdentifier(synthesizer)
        Task { @MainActor in self.utteranceFinished(by: source) }
    }
}
