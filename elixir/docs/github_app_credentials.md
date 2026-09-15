# GitHub App credentials on the controller

Symphony can authenticate GitHub repository reads/tools and finite GitHub Projects inspection
with a GitHub App. The controller signs a short-lived App JWT, checks the installation's
identity, and requests a repository-scoped installation token. Tokens remain in controller
memory and are renewed on demand before expiration.

## Configure the App

Create and install a GitHub App on the account owning the intended repository. Select only
needed repositories when installing it. Organization Projects permission is organization-wide;
repository selection does not restrict it to one board. The Projects reader separately
checks the configured organization, Project number and repository.

The inspection profile requests these permissions: organization Projects **read**, Contents
**read**, Issues **read** and Metadata **read**. The App installation may grant broader permissions
for later features, but inspection tokens must still be narrowed to this read profile.

The existing `github` tracker uses a separate profile: Contents and Metadata **read**, Issues
and Pull requests **write**, with no organization Projects permission. In App mode its REST
tool is restricted to paths in the bound repository. This is not a Projects execution profile.

Webhook delivery, OAuth user authorization, a callback URL and a client secret are not needed
for this polling/authentication flow.

## Store credentials outside workspaces

Keep the PEM private key in a controller-owned directory outside the checkout and all agent
workspaces. On Linux use directory mode `0700` and key-file mode `0600`. The worker must not
be able to read that directory. Use the owner-supplied public-key fingerprint to verify the
key before installation; it is the SHA-256 fingerprint of the DER-encoded public key, not a
hash of the PEM file.

Set these environment variables in the controller's launch environment:

```bash
export SYMPHONY_GITHUB_APP_ID=123456
export SYMPHONY_GITHUB_APP_CLIENT_ID=Iv_REPLACE_WITH_CLIENT_ID
export SYMPHONY_GITHUB_INSTALLATION_ID=789012
export SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH=/home/controller/.config/symphony/github-app/private-key.pem
```

Values above are synthetic. The environment contains the key's **path**, never the PEM or a
minted token. Keep local launch configuration outside version control. The `client_id` field
is optional; when omitted, Symphony uses the App ID as the JWT issuer. Supplying a Client ID
is recommended by GitHub. App ID and installation ID remain required.

Use this authentication block under `tracker.provider`, alongside the adapter's scope settings:

```yaml
tracker:
  kind: github_projects
  provider:
    organization: example-org
    project_number: 1
    repo: example-org/example-repo
    github_app:
      app_id: $SYMPHONY_GITHUB_APP_ID
      client_id: $SYMPHONY_GITHUB_APP_CLIENT_ID
      installation_id: $SYMPHONY_GITHUB_INSTALLATION_ID
      private_key_path: $SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH
```

This fragment omits the required board/state settings; start from the complete
[inspection example](examples/github_projects.WORKFLOW.md). App fields accept explicit values
or `$ENV_NAME` references. Do not also set `provider.token`: mixed authentication is rejected.
An invalid App configuration or failed refresh never falls back to `GITHUB_TOKEN`, a personal
token or another installation. App authentication supports only `api.github.com`.

The older `provider.token` configuration remains available when `github_app` is absent. Its
caller owns token issuance and renewal; it is not the App credential flow described here.

## Inspect without starting agents

```bash
mise exec -- mix build
mise exec -- ./bin/symphony --dry-run /absolute/path/to/private-projects.WORKFLOW.md
```

Run these commands from the Elixir checkout on the controller. Configuration validation does
not read the PEM, request a token or start a cache. A finite App inspection owns a temporary
cache and closes it when the inspection returns. It starts no scheduler, workspaces, hooks or
Codex process. The token-issuance POST and GraphQL query POSTs authenticate and read data;
they do not modify Project items, repository content or pull requests.

## Refresh and failure behavior

Each HTTP request, including each page of a long read, obtains its token from the cache.
Bound tools hold an immutable credential reference and repository scope instead of a token
string. Changing environment variables or reloading a workflow cannot redirect an existing
App-bound session to another installation, repository or Project.

The cache refreshes when a token is within 60 seconds of its API-reported `expires_at`.
Concurrent callers share one refresh. Failed refreshes return a safe error and briefly retain
that failure to avoid a retry storm; they do not return an old token. Runtime restart discards
the in-memory cache and the next request authenticates again. No periodic refresh timer runs
while the controller is idle.

Installation tokens are opaque strings. Their length, prefix and internal representation do
not determine expiry or scope. The issuer checks installation identity and the returned
repository/permission scope before a token enters the cache. Different permission profiles
cannot share a cached token.

GitHub authentication and App-authenticated API requests do not follow redirects or
transparently retry. A `401` invalidates only the token used by that request; a subsequent
request may obtain a new token. The failed operation is not replayed. In particular, an
ambiguous mutation must be reconciled before a caller decides whether to submit it again.
Authentication errors and OTP cache diagnostics omit JWTs, PEM data and installation tokens.

## Worker boundary and rotation

The App key and controller API tokens are never supplied to Codex tools as arguments, prompts
or environment variables. Adapter-declared App environment references are removed by the
Codex launch path. This does not itself provide filesystem or hook isolation: those require
an independently configured worker boundary, and are prerequisites for unattended execution.
Do not export token or PEM contents into an environment inherited by hooks.

Git push needs a separate capability. The credentials API defines an isolated Contents-write
profile with only Contents **write** and Metadata **read** for one repository. This PR does
not distribute that token to a worker or implement a push broker. A later launch/push stage
must choose and validate that boundary. No profile bypasses GitHub branch protections.

For key rotation, install a new key securely and validate it before revoking the old key.
The issuer reads the key file again on refresh. Replacing the file at the same protected path
supports subsequent refreshes; using a different path or App identity requires a new binding.
A still-valid cached token may be used until refresh. Restart the controller to discard its
cache when immediate local invalidation is required. Revoke compromised keys/tokens in GitHub
as well; deleting a local file does not revoke an already issued token.

References: [App JWTs](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app),
[installation tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app),
[private-key verification and rotation](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps).
