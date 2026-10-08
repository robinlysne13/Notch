import Foundation

/// Pulls a one-time verification code out of an email.
///
/// The hard part isn't finding digit runs, it's *not* offering the wrong one — order numbers,
/// years, dollar amounts and promo codes all look alike. So this requires the message to read like
/// a verification email at all, strips the constructs that reliably produce false positives, and
/// then prefers codes that sit next to an explicit label over bare digits.
enum VerificationCodeFinder {
    static func find(subject: String, body: String) -> String? {
        // Codes appear near the top; the tail of a long marketing footer only adds noise.
        let subject = clean(subject)
        let body = clean(String(body.prefix(8000)))
        let combined = subject + "\n" + body

        guard hasVerificationContext(combined), !isPromotional(combined) else { return nil }

        var candidates = scan(subject, region: .subject) + scan(body, region: .body)
        candidates.sort(by: Candidate.isBetter)
        return candidates.first?.code
    }

    // MARK: Context

    /// Phrases that make a message a verification email rather than any other mail with numbers.
    private static let verificationPhrases = [
        "verification code", "verification pin", "verify your", "verify it", "verifying",
        "security code", "confirmation code", "authentication code", "authorization code",
        "one-time", "one time code", "one time passcode", "otp", "2fa", "two-factor",
        "two factor", "access code", "login code", "log in code", "sign-in code",
        "sign in code", "single-use", "single use code", "temporary code", "passcode",
        "your code", "code is", "code:", "enter the code", "enter this code",
        "confirm your", "confirm that", "authenticate",
    ]

    /// Contexts that produce a labelled code which is emphatically not a login code.
    private static let promotionalPhrases = [
        "promo code", "promotional code", "coupon", "discount code", "referral code",
        "invite code", "gift card", "voucher",
    ]

    /// Phrases specific enough to outrank a promotional reading of the same message — a store's
    /// "verify your email" mail can legitimately also mention a coupon.
    private static let unambiguousPhrases = [
        "verification code", "security code", "one-time", "two-factor", "2fa", "otp",
        "authentication code", "sign-in code", "sign in code", "login code", "passcode",
        "single-use",
    ]

    private static func hasVerificationContext(_ text: String) -> Bool {
        let lower = text.lowercased()
        return verificationPhrases.contains { lower.contains($0) }
    }

    private static func isPromotional(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard promotionalPhrases.contains(where: { lower.contains($0) }) else { return false }
        return !unambiguousPhrases.contains { lower.contains($0) }
    }

    // MARK: Cleaning

    /// Removes the shapes that masquerade as codes. Each is replaced with a space rather than
    /// deleted so that surrounding words don't fuse into false labels.
    private static let noisePatterns = [
        #"https?://\S+"#,                                        // links (query params are digit soup)
        #"www\.\S+"#,
        #"\b[\w.+-]+@[\w-]+\.[\w.-]+\b"#,                        // addresses
        #"\b\d{4}-\d{2}-\d{2}\b"#,                               // ISO dates
        #"\b\d{1,2}[/.]\d{1,2}[/.]\d{2,4}\b"#,                   // slashed dates
        #"\b\d{1,2}:\d{2}(?::\d{2})?\s*(?:am|pm)?\b"#,           // times
        #"[$€£¥]\s?\d[\d,]*(?:\.\d{2})?"#,                       // amounts
        #"\+?\d{1,2}[-.\s]?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b"#, // phone numbers
        // Identifiers that are labelled as something other than a code.
        #"(?:order|invoice|receipt|ticket|account|ref|reference|tracking|case|member)\s*(?:number|no\.?|#)?\s*:?\s*[\w-]*\d[\w-]*"#,
        // Long alphanumerics containing a digit: tracking ids and opaque tokens. The digit is
        // required so ordinary long words ("verification", "authentication") survive.
        #"\b(?=[A-Za-z0-9]*\d)[A-Za-z0-9]{12,}\b"#,
    ]

    private static let noiseRegexes: [NSRegularExpression] = noisePatterns.compactMap {
        compile($0, options: [.caseInsensitive])
    }

    private static func clean(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        for regex in noiseRegexes {
            text = regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " "
            )
        }
        return text
    }

    // MARK: Candidates

    private enum Region: Int {
        // A code in the subject line is the clearest signal a sender can give.
        case subject = 0
        case body = 1
    }

    private struct Candidate {
        let code: String
        let tier: Int
        let region: Region
        let position: Int

        /// Six digits is overwhelmingly the most common one-time code length, then eight.
        var lengthRank: Int {
            switch code.count {
            case 6: return 0
            case 8: return 1
            case 7: return 2
            case 5: return 3
            default: return 4
            }
        }

        static func isBetter(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.region != rhs.region { return lhs.region.rawValue < rhs.region.rawValue }
            if lhs.lengthRank != rhs.lengthRank { return lhs.lengthRank < rhs.lengthRank }
            return lhs.position < rhs.position
        }
    }

    /// Tier 0: the code is explicitly labelled. Tier 1: it stands alone on its own line, which is
    /// how nearly every HTML template renders it. Tier 2: a bare digit run somewhere in a message
    /// that we already know is about verification.
    private static let tieredPatterns: [(tier: Int, pattern: String, requiresMixed: Bool)] = [
        (0, #"(?:verification|security|confirmation|authentication|authorization|access|login|log ?in|sign[- ]?in|one[- ]?time|single[- ]?use|temporary)\s+(?:code|passcode|pin)\s*(?:is|:|-|–|—)?\s*(\d{4,8})\b"#, false),
        (0, #"\b(?:code|passcode|otp|pin)\b\s*(?:is|:|=|-|–|—)?\s*(\d{4,8})\b"#, false),
        (0, #"\b(\d{4,8})\b\s+is\s+(?:your|the)\b"#, false),
        (0, #"\b(?:use|enter|type)\s+(?:the\s+|this\s+|code\s+)*(\d{4,8})\b"#, false),
        // Alphanumeric codes, only when labelled — unlabelled they are indistinguishable from words.
        (1, #"\b(?:code|passcode|otp)\b\s*(?:is|:|=|-|–|—)?\s*((?-i:[A-Z0-9]{5,8}))\b"#, true),
        (1, #"^[^\dA-Za-z]*(\d{4,8})[^\dA-Za-z]*$"#, false),
        // Templates routinely space out the code for legibility — "903 221", "1234 5678" — and
        // sometimes letter-space it one digit per element. Both arrive here as separate runs.
        (1, #"\b(\d{3})[   ·•‧-](\d{3})\b"#, false),
        (1, #"\b(\d{4})[   ·•‧-](\d{4})\b"#, false),
        (2, #"\b(\d)[   ](\d)[   ](\d)[   ](\d)[   ](\d)[   ](\d)\b"#, false),
        (2, #"\b(\d{4,8})\b"#, false),
    ]

    private static let tieredRegexes: [(tier: Int, regex: NSRegularExpression, requiresMixed: Bool)] =
        tieredPatterns.compactMap { entry in
            guard let regex = compile(entry.pattern, options: [.caseInsensitive, .anchorsMatchLines])
            else { return nil }
            return (entry.tier, regex, entry.requiresMixed)
        }

    /// A pattern that doesn't compile would otherwise be dropped in silence, leaving the finder
    /// quietly worse at its job — these patterns are ICU, not the Swift regex dialect, so that is
    /// an easy mistake to make. Trap it in debug builds.
    private static func compile(
        _ pattern: String, options: NSRegularExpression.Options
    ) -> NSRegularExpression? {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            assertionFailure("Bad verification-code pattern \(pattern): \(error)")
            return nil
        }
    }

    private static func scan(_ text: String, region: Region) -> [Candidate] {
        var best: [String: Candidate] = [:]
        let full = NSRange(text.startIndex..., in: text)

        for entry in tieredRegexes {
            for match in entry.regex.matches(in: text, range: full) {
                guard match.numberOfRanges > 1 else { continue }
                // Joined across groups, because templates often split the code visually and each
                // fragment lands in its own capture.
                let code = (1..<match.numberOfRanges).compactMap { index in
                    Range(match.range(at: index), in: text).map { String(text[$0]) }
                }.joined()
                guard !code.isEmpty else { continue }
                guard isPlausible(code, requiresMixed: entry.requiresMixed) else { continue }

                let candidate = Candidate(
                    code: code.uppercased(),
                    tier: entry.tier,
                    region: region,
                    position: match.range(at: 1).location
                )
                // The same digits can match several patterns; keep the strongest reading.
                if let existing = best[candidate.code],
                   !Candidate.isBetter(candidate, existing) { continue }
                best[candidate.code] = candidate
            }
        }
        return Array(best.values)
    }

    private static func isPlausible(_ code: String, requiresMixed: Bool) -> Bool {
        guard (4...8).contains(code.count) else { return false }

        if requiresMixed {
            // An all-letter token is a word, and an all-digit one is handled by the digit tiers.
            let hasDigit = code.contains { $0.isNumber }
            let hasLetter = code.contains { $0.isLetter }
            guard hasDigit, hasLetter else { return false }
            return true
        }

        guard code.allSatisfy({ $0.isNumber }) else { return false }
        // A bare four-digit year is almost never the code, and appears in every copyright footer.
        if code.count == 4, let value = Int(code), (1900...2099).contains(value) { return false }
        // All-identical digits are placeholders in template text ("000000", "123456" is real
        // though, so only the degenerate case is filtered).
        if Set(code).count == 1 { return false }
        return true
    }
}
