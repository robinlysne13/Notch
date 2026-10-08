import Foundation

var failures = 0
var passed = 0

func check(_ name: String, subject: String = "", body: String, expect: String?) {
    let got = VerificationCodeFinder.find(subject: subject, body: body)
    if got == expect {
        passed += 1
    } else {
        failures += 1
        print("FAIL  \(name)\n      expected \(expect.map { "\"\($0)\"" } ?? "nil"), got \(got.map { "\"\($0)\"" } ?? "nil")")
    }
}

// MARK: Real-world shapes of verification mail

check("Apple labelled",
      subject: "Apple Account Verification Code",
      body: "Your Apple Account verification code is: 123456\n\nDon't share it with anyone.",
      expect: "123456")

check("Google subject-first",
      subject: "G-728394 is your Google verification code",
      body: "Use the code G-728394 to sign in. If you didn't request it, ignore this email.",
      expect: "728394")

check("code on its own line",
      subject: "Verify your new Amazon account",
      body: "To verify your email address, enter the following code:\n\n418205\n\nThere is nothing else to do.",
      expect: "418205")

check("four digit code",
      subject: "Your security code",
      body: "Your verification code is 8421. It expires in 10 minutes.",
      expect: "8421")

check("eight digit code",
      subject: "Sign-in code",
      body: "Your one-time passcode is 91827364.",
      expect: "91827364")

check("space-grouped six digits",
      subject: "Your verification code",
      body: "Enter this code to continue\n\n903 221\n\nThis code expires in 15 minutes.",
      expect: "903221")

check("letter-spaced digits",
      subject: "Two-factor authentication",
      body: "Your security code:\n\n4 8 1 2 9 0\n\nDo not share this code.",
      expect: "481290")

check("labelled alphanumeric",
      subject: "Confirm your email",
      body: "Your verification code is A3F9K2. Enter it to finish signing in.",
      expect: "A3F9K2")

// MARK: Things that must NOT be offered as codes

check("promo code is not a login code",
      subject: "20% off this weekend only",
      body: "Use promo code SAVE20 at checkout. Offer ends Sunday.",
      expect: nil)

check("order confirmation",
      subject: "Your order has shipped",
      body: "Order #1234567 is on its way. Tracking number 9400110200881234567890.",
      expect: nil)

check("newsletter with numbers",
      subject: "This week in tech",
      body: "Revenue hit $1,250,000 in 2026, up from 2025. Read more at https://example.com/a/8837261",
      expect: nil)

check("copyright year not taken as code",
      subject: "Verify your email",
      body: "Your verification code is 456789.\n\nCopyright 2026 Acme Inc. All rights reserved.",
      expect: "456789")

check("receipt with amounts and a date",
      subject: "Your receipt from Acme",
      body: "Thanks! You paid $49.99 on 2026-09-28. Invoice 8871234. Questions? Call +1 415-555-0199.",
      expect: nil)

// MARK: Preference and ranking

check("prefers labelled code over stray digits",
      subject: "Security alert",
      body: "We noticed a sign-in from device 55512. Your verification code is 674321 if you want to continue.",
      expect: "674321")

check("prefers subject code",
      subject: "556677 is your verification code",
      body: "Someone requested a code. If this wasn't you, see case 119283 in your account.",
      expect: "556677")

check("ignores digits inside links",
      subject: "Your login code",
      body: "Your login code is 246810.\nManage settings: https://example.com/settings?uid=99887766&t=135790",
      expect: "246810")

check("no verification context at all",
      subject: "Lunch tomorrow?",
      body: "Are we still on for 12:30? I'll be at the office until 1400.",
      expect: nil)

// MARK: MIME decoding end to end

func checkMessage(_ name: String, raw: String, expectCode: String?, expectSubject: String? = nil) {
    let message = MIME.parse(raw: raw, uid: 1)
    let code = VerificationCodeFinder.find(subject: message.subject, body: message.body)
    if code != expectCode {
        failures += 1
        print("FAIL  \(name)\n      expected code \(expectCode ?? "nil"), got \(code ?? "nil")\n      body was: \(message.body.prefix(200).replacingOccurrences(of: "\n", with: "⏎"))")
    } else if let expectSubject, message.subject != expectSubject {
        failures += 1
        print("FAIL  \(name)\n      expected subject \"\(expectSubject)\", got \"\(message.subject)\"")
    } else {
        passed += 1
    }
}

let base64HTML = Data("""
<html><head><style>.a{font-size:32px;padding:0 24px}</style></head><body>
<p>Hi Robin,</p><div>Your verification code is</div>
<div class="a"><b>735 914</b></div>
<p>It expires in 10 minutes. &copy; 2026 Example</p></body></html>
""".utf8).base64EncodedString()

checkMessage("multipart/alternative, base64 HTML only", raw: """
From: Example Security <no-reply@example.com>
Subject: =?utf-8?B?WW91ciBFeGFtcGxlIHZlcmlmaWNhdGlvbiBjb2Rl?=
Content-Type: multipart/alternative; boundary="XYZ123"

--XYZ123
Content-Type: text/html; charset=UTF-8
Content-Transfer-Encoding: base64

\(base64HTML)
--XYZ123--
""", expectCode: "735914", expectSubject: "Your Example verification code")

checkMessage("quoted-printable with a soft line break inside the code", raw: """
From: "Acme" <security@acme.test>
Subject: Acme sign-in code
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: quoted-printable

Hello,

Your verification code is 12=
3456 and it expires shortly. Don=E2=80=99t share it.
""", expectCode: "123456")

checkMessage("prefers the text/plain part", raw: """
From: Two Part <hi@example.com>
Subject: Your code
Content-Type: multipart/alternative; boundary="bnd"

--bnd
Content-Type: text/plain; charset=UTF-8

Your verification code is 111222.
--bnd
Content-Type: text/html; charset=UTF-8

<p>Your verification code is 111222.</p><p>Promo code SAVE10 inside!</p>
--bnd--
""", expectCode: "111222")

checkMessage("folded subject header and numeric entities", raw: """
From: Long Sender Name <a@b.test>
Subject: Your verification
 code has arrived
Content-Type: text/html

<div>Your verification code is <span>&#52;&#56;&#49;&#50;&#57;&#51;</span></div>
""", expectCode: "481293", expectSubject: "Your verification code has arrived")

checkMessage("attachment part is skipped", raw: """
From: Sender <a@b.test>
Subject: Your verification code
Content-Type: multipart/mixed; boundary="mix"

--mix
Content-Type: text/plain

Your verification code is 606060.
--mix
Content-Type: application/pdf; name="receipt.pdf"
Content-Transfer-Encoding: base64

JVBERi0xLjQK999999
--mix--
""", expectCode: "606060")

print("\n\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
