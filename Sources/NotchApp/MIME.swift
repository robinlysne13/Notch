import Foundation

/// Just enough RFC 2045/2047 handling to recover readable text from a verification email:
/// header unfolding, encoded-word subjects, multipart walking, base64/quoted-printable bodies and
/// HTML stripping. Verification mail is usually machine-generated and well-formed, so this favours
/// "never throw, return whatever text we could recover" over strict parsing.
enum MIME {
    static func parse(raw: String, uid: Int) -> MailMessage {
        let (headerBlock, body) = splitHeaders(raw)
        let headers = parseHeaders(headerBlock)
        let extracted = extract(headers: headers, body: body, depth: 0)
        // Prefer the plain-text alternative; fall back to the HTML part with its markup removed.
        let text = extracted.plain ?? extracted.html.map(stripHTML) ?? ""
        return MailMessage(
            uid: uid,
            from: decodeEncodedWords(headers["from"] ?? ""),
            subject: decodeEncodedWords(headers["subject"] ?? ""),
            body: text
        )
    }

    // MARK: Headers

    private static func splitHeaders(_ raw: String) -> (String, String) {
        for separator in ["\r\n\r\n", "\n\n"] {
            if let range = raw.range(of: separator) {
                return (String(raw[raw.startIndex..<range.lowerBound]),
                        String(raw[range.upperBound...]))
            }
        }
        return (raw, "")
    }

    /// Lowercased field names to unfolded values. A repeated field keeps its first value, which is
    /// the one that belongs to the outermost part.
    private static func parseHeaders(_ block: String) -> [String: String] {
        var headers: [String: String] = [:]
        var name: String?
        var value = ""

        func flush() {
            if let name, headers[name] == nil {
                headers[name] = value.trimmingCharacters(in: .whitespaces)
            }
            value = ""
        }

        for line in block.components(separatedBy: .newlines) {
            let stripped = line.replacingOccurrences(of: "\r", with: "")
            // A leading space or tab continues the previous header (RFC 5322 folding).
            if stripped.hasPrefix(" ") || stripped.hasPrefix("\t") {
                value += " " + stripped.trimmingCharacters(in: .whitespaces)
                continue
            }
            flush()
            guard let colon = stripped.firstIndex(of: ":") else {
                name = nil
                continue
            }
            name = stripped[stripped.startIndex..<colon].lowercased()
            value = String(stripped[stripped.index(after: colon)...])
        }
        flush()
        return headers
    }

    /// Value of a `; key=value` parameter on a structured header, quoted or bare.
    private static func parameter(_ key: String, in header: String) -> String? {
        let lower = header.lowercased()
        guard let keyRange = lower.range(of: "\(key)=") else { return nil }
        let rest = header[keyRange.upperBound...]
        if rest.hasPrefix("\"") {
            let afterQuote = rest.dropFirst()
            guard let end = afterQuote.firstIndex(of: "\"") else { return nil }
            return String(afterQuote[afterQuote.startIndex..<end])
        }
        let terminated = rest.prefix { $0 != ";" && !$0.isWhitespace }
        return terminated.isEmpty ? nil : String(terminated)
    }

    // MARK: Bodies

    private struct Extracted {
        var plain: String?
        var html: String?

        mutating func merge(_ other: Extracted) {
            plain = plain ?? other.plain
            html = html ?? other.html
        }
    }

    private static func extract(headers: [String: String], body: String, depth: Int) -> Extracted {
        let contentType = (headers["content-type"] ?? "text/plain").lowercased()

        if contentType.contains("multipart/"), depth < 5,
           let boundary = parameter("boundary", in: headers["content-type"] ?? "") {
            var result = Extracted()
            for part in split(body, boundary: boundary) {
                let (partHeaders, partBody) = splitHeaders(part)
                result.merge(extract(headers: parseHeaders(partHeaders), body: partBody, depth: depth + 1))
                // multipart/alternative lists least-rich first, so keep walking even once we have
                // something: a later text/plain part is still the better answer.
                if result.plain != nil, result.html != nil { break }
            }
            return result
        }

        // Attachments (PDFs, images) carry no code worth reading and would only add noise.
        guard contentType.contains("text/") || headers["content-type"] == nil else {
            return Extracted()
        }
        let decoded = decodeTransfer(
            body,
            encoding: (headers["content-transfer-encoding"] ?? "").lowercased(),
            charset: parameter("charset", in: headers["content-type"] ?? "")
        )
        if contentType.contains("text/html") {
            return Extracted(plain: nil, html: decoded)
        }
        return Extracted(plain: decoded, html: nil)
    }

    private static func split(_ body: String, boundary: String) -> [String] {
        body
            .components(separatedBy: "--\(boundary)")
            .dropFirst()                                  // preamble
            .filter { !$0.hasPrefix("--") }                // closing delimiter
            .map { part in
                var part = part
                while part.hasPrefix("\r") || part.hasPrefix("\n") { part.removeFirst() }
                return part
            }
    }

    private static func decodeTransfer(_ body: String, encoding: String, charset: String?) -> String {
        switch encoding {
        case let value where value.contains("base64"):
            let joined = body.components(separatedBy: .whitespacesAndNewlines).joined()
            guard let data = Data(base64Encoded: joined, options: .ignoreUnknownCharacters) else {
                return body
            }
            return decode(data, charset: charset)
        case let value where value.contains("quoted-printable"):
            return decodeQuotedPrintable(body, charset: charset)
        default:
            return body
        }
    }

    private static func decode(_ data: Data, charset: String?) -> String {
        switch charset?.lowercased() {
        case "iso-8859-1", "latin1", "windows-1252":
            return String(data: data, encoding: .isoLatin1) ?? String(decoding: data)
        default:
            return String(decoding: data)
        }
    }

    private static func decodeQuotedPrintable(_ text: String, charset: String?) -> String {
        var bytes: [UInt8] = []
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            guard character == "=" else {
                bytes.append(contentsOf: Array(String(character).utf8))
                index = text.index(after: index)
                continue
            }
            let afterEquals = text.index(after: index)
            // "=" at end of line is a soft break: the line continues, emit nothing.
            if afterEquals < text.endIndex, text[afterEquals] == "\r" || text[afterEquals] == "\n" {
                index = afterEquals
                while index < text.endIndex, text[index] == "\r" || text[index] == "\n" {
                    index = text.index(after: index)
                }
                continue
            }
            let hexEnd = text.index(afterEquals, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
            if let byte = UInt8(text[afterEquals..<hexEnd], radix: 16) {
                bytes.append(byte)
                index = hexEnd
            } else {
                bytes.append(contentsOf: Array("=".utf8))
                index = afterEquals
            }
        }
        return decode(Data(bytes), charset: charset)
    }

    // MARK: RFC 2047 encoded words

    /// Rewrites `=?utf-8?B?…?=` / `=?…?Q?…?=` runs in a header into plain text.
    static func decodeEncodedWords(_ header: String) -> String {
        guard header.contains("=?") else { return header }
        var result = ""
        var rest = Substring(header)

        while let start = rest.range(of: "=?") {
            result += rest[rest.startIndex..<start.lowerBound]
            let afterMarker = rest[start.upperBound...]
            // charset ? encoding ? text ?=
            guard let charsetEnd = afterMarker.firstIndex(of: "?") else { break }
            let charset = String(afterMarker[afterMarker.startIndex..<charsetEnd])
            let afterCharset = afterMarker[afterMarker.index(after: charsetEnd)...]
            guard let encodingEnd = afterCharset.firstIndex(of: "?") else { break }
            let encoding = afterCharset[afterCharset.startIndex..<encodingEnd].uppercased()
            let payload = afterCharset[afterCharset.index(after: encodingEnd)...]
            guard let terminator = payload.range(of: "?=") else { break }
            let encoded = String(payload[payload.startIndex..<terminator.lowerBound])

            switch encoding {
            case "B":
                if let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) {
                    result += decode(data, charset: charset)
                } else {
                    result += encoded
                }
            case "Q":
                // In Q-encoding "_" stands for a space.
                result += decodeQuotedPrintable(
                    encoded.replacingOccurrences(of: "_", with: " "), charset: charset
                )
            default:
                result += encoded
            }
            rest = payload[terminator.upperBound...]
        }
        result += rest
        return result
    }

    // MARK: HTML

    static func stripHTML(_ html: String) -> String {
        var text = html
        // Script and style bodies are not content, and CSS is full of digit runs that would read
        // like candidate codes.
        for tag in ["script", "style", "head"] {
            text = text.replacingOccurrences(
                of: "<\(tag)[^>]*>.*?</\(tag)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        // Keep block boundaries as newlines so "Your code" and the digits don't fuse together.
        text = text.replacingOccurrences(
            of: "<(br|/p|/div|/td|/tr|/h[1-6]|/li)[^>]*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return decodeEntities(text)
    }

    private static let namedEntities = [
        "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
        "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&zwnj;": "", "&zwj;": "",
    ]

    private static func decodeEntities(_ text: String) -> String {
        var text = text
        for (entity, replacement) in namedEntities {
            text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        // Numeric entities, decimal and hex — some senders encode the code's digits this way.
        let pattern = #"&#(x?)([0-9a-fA-F]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text),
                  let hexRange = Range(match.range(at: 1), in: text),
                  let digitsRange = Range(match.range(at: 2), in: text)
            else { continue }
            let radix = text[hexRange].isEmpty ? 10 : 16
            guard let value = UInt32(text[digitsRange], radix: radix),
                  let scalar = Unicode.Scalar(value)
            else { continue }
            text.replaceSubrange(range, with: String(Character(scalar)))
        }
        return text
    }
}
