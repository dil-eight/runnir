# DigitalOcean Static Next.js Landing Deployment

Status: reviewable template design; not deployed or end-to-end verified. Apply only to a separately selected user repository. Runnir itself has no Node/Next.js dependency.

## Compatibility Gate

Verify the selected project's pinned Next.js version, lockfile and build script; inspect routes, server-only features, dynamic paths and image handling. A static landing must build to `out/` and serve directly with no application server. Dynamic APIs/auth/payment backends need separate services and are outside the free static template.

Proposed configuration diff for the user's project:

```javascript
const nextConfig = {
  output: 'export',
  trailingSlash: true,
  images: { unoptimized: true },
};

export default nextConfig;
```

Merge with existing configuration after review. Do not overwrite unrelated settings. Build in a controlled environment only after execution consent, using the project's lockfile and trusted/pinned toolchain. Test root/nested routes, 404, assets and forms. External form/analytics integrations are separate opt-ins.

## App Spec Draft

Replace example name/repository/branch with user-reviewed values. This example assumes an npm lockfile and a `build` script; select the actual package manager instead of blindly applying it.

```yaml
name: startup-landing
static_sites:
  - name: landing
    github:
      repo: example-org/example-landing
      branch: main
      deploy_on_push: false
    source_dir: /
    build_command: npm ci && npm run build
    output_dir: out
    index_document: index.html
    error_document: 404.html
```

Validate against the current DigitalOcean App Spec before offering execution. Show the diff, repository disclosure, selected account and conditional free-tier limits. Then require explicit authorization to apply the local files and a separate approval to create/update the cloud app. The future adapter may call the official App Platform API; doctl can be installed through vendor guidance, but token persistence must satisfy Keychain policy.

This GitHub-connected template builds at the provider. It is not yet a Build Once artifact deployment integration; do not label it artifact reuse. A later adapter must verify a supported artifact delivery path and provenance.

Sources: [Next.js export guide](https://nextjs.org/docs/app/guides/static-exports), [DigitalOcean static sites](https://docs.digitalocean.com/products/app-platform/how-to/manage-static-sites/), [App Platform pricing](https://docs.digitalocean.com/products/app-platform/details/pricing/).
