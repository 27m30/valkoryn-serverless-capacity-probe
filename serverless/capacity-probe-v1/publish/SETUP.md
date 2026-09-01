# First image publication setup

The current `C:\Valkoryn` workspace is not a Git repository. Use a new private
GitHub repository that contains only these paths:

- `.github/workflows/publish-serverless-capacity-probe-v1.yml`
- `serverless/capacity-probe-v1/`

Do not add Valkoryn models, media, character assets, secrets, job directories,
or other production files to that repository.

One-time GitHub steps:

1. Create a private repository, suggested name `valkoryn-capacity-probe-v1`.
2. Commit only the two paths above and push them to the default branch.
3. In repository Settings > Actions > General, allow GitHub Actions and allow
   workflows read/write permissions. The workflow also declares its minimal
   `contents:read`, `packages:write`, `id-token:write`, and
   `attestations:write` job permissions.
4. Run the manual workflow and type the exact confirmation
   `PUBLISH_SERVERLESS_CAPACITY_PROBE_V1`.
5. The workflow uses GitHub's automatic `GITHUB_TOKEN`; do not create or commit
   a GHCR password or personal access token.
6. After the first successful push, open the package settings for
   `valkoryn-serverless-capacity-probe-v1` and change only that package to
   public visibility. This lets RunPod pull the telemetry-only image without a
   registry credential. Keep the source repository private.
7. Download the workflow artifact named
   `serverless-capacity-probe-v1-<git-sha>`. It contains the immutable digest,
   BuildKit provenance metadata, SBOM-enabled build record, SHA-256 sums, and
   digest-bound RunPod template body.

GitHub-hosted provenance attestations for private repositories require GitHub
Enterprise Cloud. On other plans leave the optional attestation input false;
BuildKit `mode=max` provenance and the SBOM remain embedded in the OCI image.

The immutable tag convention is:

```text
ghcr.io/<owner>/valkoryn-serverless-capacity-probe-v1:v1-git-<40-character-commit>
```

RunPod must use the digest reference from `build-metadata.json`, never the tag:

```text
ghcr.io/<owner>/valkoryn-serverless-capacity-probe-v1@sha256:<64-hex-digest>
```
