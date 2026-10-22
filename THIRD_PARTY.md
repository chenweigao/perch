# Third-party components

- [libghostty-spm](https://github.com/Lakr233/libghostty-spm), MIT;
  revision `121c8e286d24e21ea1a379da3eaa3556d3a1b8f5`.
  Includes Ghostty, MIT, Copyright Mitchell Hashimoto and Ghostty contributors.
  See the dependency's LICENSE and bundled notices for its terminal resources.
- [MSDisplayLink](https://github.com/Lakr233/MSDisplayLink), MIT; resolved at 2.2.0.
- [Herdr](https://github.com/herdrdev/herdr), Apache-2.0. Invoked on the remote
  machine and used through its public API; no Herdr binary is bundled.
- [Swift Markdown](https://github.com/swiftlang/swift-markdown), 0.8.0,
  Apache-2.0 with Swift Runtime Library Exception; parses native conversation replies.
- [Mermaid](https://github.com/mermaid-js/mermaid), 11.12.1, MIT; renders
  ```` ```mermaid ```` reply blocks offscreen. The minified upstream build is not
  committed: `scripts/build.sh` fetches
  `https://cdn.jsdelivr.net/npm/mermaid@11.12.1/dist/mermaid.min.js`
  (sha256 `198b19442f86f0b46a17e56d3abf744c3a28a3427e66fa8dada3b589a77babcc`)
  into `Resources/Mermaid/` on demand and verifies the digest.
- [highlight.js](https://github.com/highlightjs/highlight.js), 11.11.1, BSD-3-Clause;
  bundled common-language build, used through JavaScriptCore for native code colors.
  `scripts/prepare-highlight.sh` downloads the pinned upstream build and verifies
  SHA-256 `c4a399dd6f488bc97a3546e3476747b3e714c99c57b9473154c6fb8d259b9381`.
  Source text is passed as data, never evaluated as JavaScript.
- [swift-cmark](https://github.com/swiftlang/swift-cmark), 0.8.0, BSD-2-Clause
  and upstream notices in COPYING; Swift Markdown's CommonMark/GFM parser.
- The system OpenSSH client and Apple frameworks are used from macOS.

herdrm is a product reference only. None of its PolyForm Noncommercial code or
assets are included. License copies for bundled dependencies are packaged by
scripts/build.sh.

## Local resource lookup patch

The pinned GhosttyKit checkout receives `patches/ghostty-app-resources.patch` during
`scripts/build.sh`. This small patch resolves the packaged SwiftPM resource bundle
under `Contents/Resources` before using SwiftPM's CLI/build-directory lookup.
It does not change the terminal engine or consult user Ghostty configuration.
The patch is checked before applying, is idempotent, and stays under the upstream MIT license.

## Remote native agents

OMP 18.1.16 and Qoder CN CLI 1.1.58 are invoked on the remote machine; neither is bundled in the Mac app. The remote installer installs the official `@qodercn-ai/qodercn-agent-sdk` 1.0.45 into a dedicated npm directory, under the vendor license included in that package. The bridge code is original; SDK/runtime code is not copied into this repository.
