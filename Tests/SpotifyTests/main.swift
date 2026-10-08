import Foundation

// Pins the pure parts of the Spotify OAuth flow. These are the pieces where a quiet bug shows up
// only as an opaque rejection from Spotify, so they are worth checking directly.

var failures = 0
var passed = 0

func checkEqual<T: Equatable>(_ name: String, _ got: T, _ expect: T) {
    if got == expect {
        passed += 1
    } else {
        failures += 1
        print("FAIL  \(name)\n      expected \(expect)\n      got      \(got)")
    }
}

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        passed += 1
    } else {
        failures += 1
        let d = detail()
        print("FAIL  \(name)" + (d.isEmpty ? "" : "\n      \(d)"))
    }
}

// MARK: PKCE challenge
//
// The worked example from RFC 7636 appendix B. If this drifts, Spotify rejects the token
// exchange with a generic "invalid_grant" and the cause is near-invisible.

checkEqual(
    "S256 challenge matches the RFC 7636 test vector",
    SpotifyAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
    "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
)

let challenge = SpotifyAuth.challenge(for: "a-test-verifier")
check("challenge is base64url, never plain base64",
      !challenge.contains("+") && !challenge.contains("/") && !challenge.contains("="),
      "got \(challenge)")
check("challenge is stable for one verifier",
      SpotifyAuth.challenge(for: "same") == SpotifyAuth.challenge(for: "same"))
check("different verifiers give different challenges",
      SpotifyAuth.challenge(for: "one") != SpotifyAuth.challenge(for: "two"))

// MARK: Form encoding
//
// URLComponents leaves "+" alone, which a form parser reads back as a space — that would corrupt
// an authorization code and is the exact trap this helper exists to avoid.

func encoded(_ fields: [String: String]) -> String {
    String(data: SpotifyAuth.formEncoded(fields) ?? Data(), encoding: .utf8) ?? ""
}

checkEqual("plain pair", encoded(["grant_type": "refresh_token"]), "grant_type=refresh_token")
check("plus is escaped", encoded(["code": "a+b"]).contains("a%2Bb"), encoded(["code": "a+b"]))
check("slash is escaped", encoded(["code": "a/b"]).contains("a%2Fb"))
check("equals is escaped", encoded(["code": "a=b"]).contains("a%3Db"))
check("space is escaped", encoded(["scope": "a b"]).contains("a%20b"))
check("unreserved characters are left alone",
      encoded(["v": "Aa0-._~"]).contains("v=Aa0-._~"), encoded(["v": "Aa0-._~"]))
checkEqual("empty value", encoded(["a": ""]), "a=")

// MARK: Redirect callback parsing

let ok = OAuthCallback.parse("GET /callback?code=ABC123&state=XYZ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
checkEqual("code is read", ok.code, "ABC123")
checkEqual("state is read", ok.state, "XYZ")
check("no error on success", ok.error == nil)

let denied = OAuthCallback.parse("GET /callback?error=access_denied&state=XYZ HTTP/1.1\r\n")
check("a denial carries no code", denied.code == nil)
checkEqual("the denial reason is kept", denied.error, "access_denied")
checkEqual("state survives a denial", denied.state, "XYZ")

let escaped = OAuthCallback.parse("GET /callback?code=a%2Bb%2Fc&state=s HTTP/1.1\r\n")
checkEqual("percent-escapes in the code are decoded", escaped.code, "a+b/c")

let swapped = OAuthCallback.parse("GET /callback?state=first&code=second HTTP/1.1\r\n")
checkEqual("order doesn't matter (code)", swapped.code, "second")
checkEqual("order doesn't matter (state)", swapped.state, "first")

check("bare path with no query yields nothing",
      OAuthCallback.parse("GET /callback HTTP/1.1\r\n").code == nil)
check("empty request is handled", OAuthCallback.parse("").error != nil)
check("garbage is handled", OAuthCallback.parse("not an http request").code == nil)

// A favicon request can reach the listener before the real redirect does; it must not be
// mistaken for a callback carrying no code.
check("unrelated request has no code", OAuthCallback.parse("GET /favicon.ico HTTP/1.1\r\n").code == nil)

print("\n\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
