# Repository images

`vault-workspace.png` shows the real `VaultWorkspaceView` with two dummy projects and three environments.
An isolated test host rendered the image with mock Keychain, authentication, and API services.
It did not read production secrets or account credentials.
The values use dummy strings and reserved `.test` domains.

`social-preview.html` composes the existing Vault mark and that screenshot into a GitHub social preview.
`social-preview.jpg` is its 1280 × 640 JPEG render.
The fonts and logo come from this repository.

To render the preview, serve the repository root with a local HTTP server.
Open `docs/assets/social-preview.html` with a 1280 × 640 browser viewport.
Capture the viewport after the images and font load.
Save the capture with an extension that matches its image format.
Upload the JPEG through **Settings → General → Social preview** on GitHub.

If you replace either image, use dummy data and inspect the full image before publication.
Do not capture a production account, real project paths, or real secrets.
