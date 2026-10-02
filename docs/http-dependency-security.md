# HTTP dependency security update

## Why this update is needed

- **CVE-2026-28980 / [GHSA-rj37-6j9x-74q6](https://github.com/apple/swift-nio/security/advisories/GHSA-rj37-6j9x-74q6):** SwiftNIO's HTTP/1 parser could accumulate an unbounded header block before application middleware ran. WhisperServer uses that parser through Vapor. The default localhost binding limits exposure to local clients. Enabling **Expose on Local Network** also exposes this path to reachable network clients; **Require API Key** does not protect parsing that happens before authentication.
- **CVE-2026-28975 / [GHSA-6ph5-fww6-vfwv](https://github.com/apple/swift-nio-extras/security/advisories/GHSA-6ph5-fww6-vfwv):** a false `Content-Length` could bypass the request decompressor's expansion-ratio limit. Vapor 4.115.0 enables request decompression with `.ratio(25)` by default, and WhisperServer retains that configuration. The fixed implementation counts bytes actually received.

## Reviewed package changes

| Package | Before | After | Reason |
| --- | --- | --- | --- |
| swift-nio | 2.83.0 | 2.103.0 | Stable version containing the HTTP/1 header fix |
| swift-nio-extras | 1.28.0 | 1.35.1 | Stable version containing the decompression fix and subsequent compatibility fixes |
| swift-certificates | 1.10.0 | 1.14.0 | Minimum required by updated swift-nio-extras |
| swift-nio-ssl | 2.31.0 | 2.34.0 | Minimum required by updated swift-nio-extras |

All other package pins are unchanged, including Vapor 4.115.0 and FluidAudio 0.15.5. No beta packages are introduced. Both the minimum fixed extras release (1.34.1) and 1.35.1 require the same certificate/TLS upgrades. Xcode 16.3 / Swift 6.1 or later is required by these SwiftNIO releases; the app's macOS deployment target is unchanged.

The selected SwiftNIO 2.103.0 source defaults limit combined header names/values to **80 KiB** and fields to **65,534**, including trailers. These differ from the original advisory's 2 MiB / 256 defaults for 2.100.0. Ordinary API requests are below these limits; large audio request bodies do not count toward the header limit. Excess headers fail before the application receives the request head.

## Other advisory matches considered

The NIO update also includes fixes for [outbound request-line injection](https://github.com/apple/swift-nio/security/advisories/GHSA-cq87-8r7h-962v) and [ByteBuffer integer overflow](https://github.com/apple/swift-nio/security/advisories/GHSA-r3rc-9hpw-54v9). A practical exploit path for those separate issues was not established in WhisperServer, so they are not the justification for this release.

The unchanged swift-nio-http2 pin matches [HTTP/2 translation smuggling](https://github.com/apple/swift-nio-http2/security/advisories/GHSA-4px2-pw77-vc85) and [MadeYouReset](https://github.com/apple/swift-nio-http2/security/advisories/GHSA-xvr7-p2c6-j83w). The app configures no TLS; Vapor's server defaults to HTTP/1 in that configuration. It is not an HTTP proxy, and its model downloads use Foundation networking. No reachable HTTP/2 server path was found, so an unrelated HTTP/2 upgrade is excluded from this targeted patch.

## Validation and limits

`python3 scripts/test_http_dependencies.py` resolves an isolated test package with the exact versions and revisions from the app lockfile, excluding only FluidAudio. It refuses a changed dependency graph, compiles the real Vapor/NIO stack, tests bounded header rejection before a request-head observer, preserves ordinary multipart data, checks the decompression-ratio regression with a small synthetic fixture, and exercises JSON/SSE transport over loopback with synthetic route responses.

The synthetic route fixtures do not execute WhisperServer's transcription routes or an inference model. They complement, rather than replace, a native app build, the existing XCTest suite, and native API smoke tests. The native CI job builds the macOS SDK from public whisper.cpp revision `1da4dc82fa7996d4edda05890dca65aeceaafd6d`, matching the source version recorded in the 2.9.0 framework. It reuses upstream build helpers and macOS build options, runs the app XCTest target, builds the arm64 Release app, ad-hoc signs it with the existing entitlements, and verifies its version, signature and exact package checkout revisions. The candidate ZIP and package provenance are saved for review; CI does not publish a release. A native API smoke test is still required before publication.

The CI workflow has read-only repository permissions and uses no signing credentials, model files, user audio, or account data. Security review must consider the complete resolved graph and actual reachability again for later dependency updates; a clean advisory lookup alone is not a guarantee that a package is safe.
