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

Before sharing a source release:

1. Run the build and scoped checks described in CONTRIBUTING.md.
2. Run `python3 scripts/check-public-source.py` and the tests under Tests/Publication.
3. Review new images and their metadata. The pattern scanner cannot read screenshots.
4. Check README links and describe supported versions and known limitations.
5. Tag the reviewed commit and publish source release notes. Do not claim notarized
   binaries or performance improvements without the corresponding evidence.

The offline [public demo](../Tests/PublicDemo/README.md) produces reproducible
screenshots using production UI components and synthetic data. Native UI previews,
unit checks, live agent acceptance and end-to-end performance are separate checks.
