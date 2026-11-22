import XCTest
@testable import TokenCounter

final class TopUpLinkTests: XCTestCase {
    func testEveryProviderHasOfficialHTTPSTopUpPage() {
        let expectedHosts: [ProviderID: String] = [
            .claude: "claude.ai",
            .openAI: "chatgpt.com",
            .gemini: "one.google.com",
        ]
        for provider in ProviderID.allCases {
            let url = AppDelegate.topUpURL(provider)
            XCTAssertEqual(url?.scheme, "https", "\(provider)")
            XCTAssertEqual(url?.host, expectedHosts[provider], "\(provider)")
            XCTAssertFalse(AppDelegate.topUpTitle(provider).isEmpty)
        }
    }
}
