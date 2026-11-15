# Notification Sender releases

This public repository is the binary release channel for Notification Sender.
The source code and development history remain in a separate private repository.

Only release artifacts, manifests, GitHub Artifact Attestation bundles, and the
minimal release workflow/policy belong here. No Hub token, Sender token, GitHub
credential, local configuration, SQLite data, SSH public key, or private source
history may be published here.

Installed Senders must accept an artifact only after verifying its GitHub
Sigstore attestation against all of these constraints:

- repository `denor81/tg_inform_sender_releases`;
- the pinned release workflow in this repository;
- the expected SemVer tag;
- the artifact digest and every digest in the release manifest.

Checksums downloaded from the same release are integrity metadata, not an
independent authenticity boundary. Release publication is protected by the
`production-release` GitHub Environment and requires explicit approval.

The update format and rollback contract are maintained in the private source
repository at `docs/release-update-architecture.md`.
