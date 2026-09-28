# Source releases and ongoing development

The first public repository starts from a reviewed source snapshot. Existing
private development history, branches, tags and bundles must not be pushed to it.
Internal source links are preserved so tests continue to exercise the production
source after future edits. Links outside the exported source are rejected.
Use an explicit public Git identity (for example, your GitHub noreply address)
for the initial commit. Do not inherit a work email from global Git settings.

After that one-time migration, the public repository is the canonical source.
Develop in normal feature branches and worktrees, review pull requests, and merge
into main. Keep commit history; do not repeatedly replace the repository with
new ZIP snapshots. Retain the old repository as a local archive. Migrate any
unfinished changes individually, checking their content and commit metadata.
Keep private reports, real conversations and release staging outside tracked files.

## Version numbers

`CFBundleShortVersionString` in `Resources/Info.plist` is the only place the release
version is written by hand, as `MAJOR.MINOR.PATCH`. Bump it, commit, then tag that
commit `v<version>`; `scripts/check-version.py` fails when a tagged commit declares a
different version, and runs as part of the functional checks.

Choose the increment by what changed:

- Patch: fixes and internal work with no new behaviour.
- Minor: new or changed UI and behaviour.
- Minor at least, together with a `SERVICE_VERSION` bump in
  `remote/native-agent-service.py`, whenever the bridge protocol changes in a way an
  older broker or an older app cannot serve.

`scripts/build.sh` stamps the rest of the identity into the bundle, never into the
source tree: `CFBundleVersion` is the commit count and `PerchSourceRevision` is
`git describe --tags --dirty --always`. Settings shows both, so a screenshot or a
shared bundle can be traced back to its commit. A `-dirty` suffix marks a build with
uncommitted changes and must not be shared as a release.

Before sharing a source release:

1. Bump the version as described above, and run the build and scoped checks described
   in CONTRIBUTING.md.
2. Run `python3 scripts/check-public-source.py` and the tests under Tests/Publication.
3. Review new images and their metadata. The pattern scanner cannot read screenshots.
4. Check README links and describe supported versions and known limitations.
5. Tag the reviewed commit and publish source release notes. Do not claim notarized
   binaries or performance improvements without the corresponding evidence.

The offline [public demo](../Tests/PublicDemo/README.md) produces reproducible
screenshots using production UI components and synthetic data. Native UI previews,
unit checks, live agent acceptance and end-to-end performance are separate checks.
