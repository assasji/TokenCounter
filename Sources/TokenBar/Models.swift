import Foundation

enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude, openAI, gemini
    var id: String { rawValue }
    var name: String { switch self { case .claude: "Claude"; case .openAI: "GPT / Codex"; case .gemini: "Gemini" } }
    var iconResource: String { rawValue + "-icon" }
}

/// One usage window (e.g. the 5-hour session limit or the weekly limit).
struct UsageWindow: Codable, Equatable, Sendable {
    var label: String            // "5시간" / "이번 주"
    var remainingPercent: Double // 0...100 (100 = full)
    var resetsAt: Date?
}

struct ProviderSnapshot: Codable, Equatable, Sendable {
    var windows: [UsageWindow] = []
    var updatedAt: Date?
    var error: String?

    /// Primary value shown in the menu bar (first window = 5h session).
    var primaryPercent: Double? { windows.first?.remainingPercent }

    static let empty = ProviderSnapshot(windows: [], updatedAt: nil, error: nil)
}

enum ProviderError: LocalizedError, Equatable {
    case missingCredential, authentication, forbidden, notFound, rateLimited, invalidResponse, network(String)
    var errorDescription: String? {
        switch self {
        case .missingCredential: "로그인 정보를 찾을 수 없음"
        case .authentication: "인증 실패 (토큰 만료 — 해당 CLI로 다시 로그인)"
        case .forbidden: "권한 없음"
        case .notFound: "사용량 엔드포인트 없음"
        case .rateLimited: "요청 제한"
        case .invalidResponse: "응답 형식 오류"
        case .network(let message): message
        }
    }
}

protocol ProviderService: Sendable {
    var provider: ProviderID { get }
    func fetchUsageWindows() async throws -> [UsageWindow]
}
