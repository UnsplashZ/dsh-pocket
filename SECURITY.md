# Security Policy

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private reporting instead:

> [**Report a vulnerability**](https://github.com/UnsplashZ/dsh-pocket/security/advisories/new)
> (repository → Security → Advisories → Report a vulnerability)

Please include: what you did, what you expected, what happened, and the app version
(`设置 → 诊断` shows it) plus your iOS version and how the app was signed.

This is a spare-time project, so expect a first reply within about a week, not within hours.

## Supported versions

Only the latest release gets fixes. There are no long-term branches.

## Design limits — please read before reporting

These are **known and deliberate**, documented in
[docs/TRANSPORT.md](docs/TRANSPORT.md) §8 and the README's security section. They are
consequences of the architecture, not bugs:

1. **Anyone who can already run code on your computer can pair as a phone.** Host-side access is
   the trust boundary; the tether plugin cannot defend against a local attacker, and does not try.
2. **Other apps on your phone can reach the app's local proxy.** It binds `127.0.0.1` only, but
   iOS does not isolate loopback between apps, and the port is derivable from the host ID.
3. **The relay sees ciphertext only** when hole-punching fails. That is a property of iroh, not
   something this app adds.
4. **The unsigned IPA is not sandboxed by us.** You re-sign it with your own identity; whatever
   the signing tool does to it afterwards (bundle ID changes, injected libraries) is outside our
   control. Verify the `.sha256` of the file you download.

**Do not use this app on a computer where you also run untrusted code.** That is stated in the
README on purpose: it is the honest scope of the threat model.

## What is genuinely in scope

- Anything that lets someone who has **never** paired read or write sessions.
- Anything that lets a paired phone **escalate beyond what the host user could already do**.
- A leak of secrets the app handles: the DSH session cookie, iroh private keys in the Keychain,
  or the provider API keys the settings screen stores.
- Release-artifact tampering: a `sha256` mismatch, or a release build that turns out to be signed
  with someone else's identity (the packaging script is supposed to make that impossible).
