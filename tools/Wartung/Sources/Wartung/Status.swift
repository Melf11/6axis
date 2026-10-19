import Foundation

/// The JSON from `scripts/release.py --status-json`.
struct Status: Decodable {
    var repo: String
    var bugs: [Bug]
    var prs: [PullRequest]
    var release: Release

    struct Bug: Decodable, Identifiable {
        var number: Int
        var title: String
        var url: URL
        var author: String
        var state: String
        var ready: Bool
        var reason: String
        var id: Int { number }
    }

    struct PullRequest: Decodable, Identifiable {
        var number: Int
        var title: String
        var url: URL
        var author: String
        var head: String
        var issues: [Int]
        var ci: String
        var additions: Int
        var deletions: Int
        var files: Int
        var blockers: [String]
        var warnings: [String]
        var id: Int { number }
    }

    struct Release: Decodable {
        var last: String
        var head: String
        var changes: [String]
        var next: [String: String]
    }
}
