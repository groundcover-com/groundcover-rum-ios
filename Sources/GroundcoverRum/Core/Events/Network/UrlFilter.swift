import Foundation

private let globMeta = NSRegularExpression(sdkPattern: #"[.+^${}()|\[\]\\]"#)

// Leading and trailing `*` add nothing to an unanchored match, and a pattern opening on `.*`
// backtracks across the whole URL from every position.
private let outerStars = NSRegularExpression(sdkPattern: #"^\*+|\*+$"#)

/// Whether a request is left uncaptured: the SDK's own traffic to `endpoint`, or a match in
/// `excludedUrls` (a regular expression, a `*`/`?` glob that matches anywhere in the URL, or an
/// exact URL).
func shouldIgnoreUrl(_ url: String, endpoint: String? = nil, excludedUrls: [URLPattern] = [])
    -> Bool
{
    if let endpoint, !endpoint.isEmpty, url.contains(endpoint) { return true }
    return excludedUrls.contains { pattern in
        switch pattern {
        case .regex(let regex):
            return regex.hasMatch(url)
        case .string(let string):
            guard string.contains("*") || string.contains("?") else { return url == string }
            // `?` is any one character, as excludedUrls documents.
            let glob = globMeta.replacingMatches(
                in: outerStars.replacingMatches(in: string) { _ in "" }
            ) { groups in "\\" + groups[0] }
            .replacingOccurrences(of: "*", with: ".*")
            .replacingOccurrences(of: "?", with: ".")
            if glob.isEmpty { return true }
            guard let regex = try? NSRegularExpression(pattern: glob) else { return false }
            return regex.hasMatch(url)
        }
    }
}
