# Security

Please report a suspected vulnerability privately through GitHub's
**Security > Report a vulnerability** page for this repository. Do not include
private transcript text, audio, credentials, or full diagnostic logs in a
public issue.

SuperDictate does not require an account or cloud transcription service. The
default installer downloads a version-pinned release bundle and verifies its
SHA-256, version, bundle identifier, architecture, code signature, and required
microphone entitlements. It does not disable Gatekeeper with `xattr`.

The public bundle is currently ad-hoc signed and is not notarized by Apple.
Users who require a locally built binary can run the source-build installer
documented in [README.md](README.md).
