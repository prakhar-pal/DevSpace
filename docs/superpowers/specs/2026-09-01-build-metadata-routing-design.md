# Build Metadata Routing Design

## Problem

DevSpace and DevSpaceDev use separate reverse-tunnel ports, but the pod-side
`dide` helper currently reads one generic `DEVSPACE_POD_FORWARD_PORT`
environment variable. Persistent shells retain their launch-time environment,
so attaching the same shell through another build does not refresh that value.
As a result, `dide` can address an absent or unintended desktop listener even
when another DevSpace build has a working tunnel.

## Goals

- Let production and development builds maintain simultaneous reverse tunnels.
- Let `dide` discover a live build at invocation time instead of relying only
  on the persistent shell's launch-time environment.
- Identify the build behind a candidate tunnel before sending the folder-open
  request.
- Provide an API response that can gain additional metadata without breaking
  existing clients.
- Preserve a migration path for shells that still contain the legacy generic
  port variable.

## Non-goals

- Determining which graphical client is currently displaying a persistent
  shell. The shell manager does not expose that identity to the process.
- Adding a user-visible build selector to `dide`.
- Changing notification payloads or notification UI behavior.

## API contract

The existing loopback listener gains an authenticated metadata route:

```http
GET /api/v1/metadata
Authorization: Bearer <notify-token>
```

A successful request returns `200 OK`, `Content-Type: application/json`, and a
compact JSON document:

```json
{
  "schema_version": 1,
  "build": {
    "channel": "dev"
  }
}
```

`build.channel` is either `dev` or `prod` and is derived from the app bundle
identifier using the same build classification that selects the tunnel ports.
Unknown bundle identifiers use the existing production behavior and therefore
report `prod`.

The top-level object is additive. New optional metadata can be added without a
schema-version change, and clients must ignore fields they do not understand.
`schema_version` changes only if an incompatible interpretation is introduced.

The route requires the existing shared notification token. A missing or
incorrect bearer token returns `401 Unauthorized` without metadata. Unsupported
methods and unknown routes continue to have no side effects.

## SSH environment

New SSH processes advertise only the variable belonging to their build:

- Production: `DEVSPACE_PROD_POD_FORWARD_PORT=8765`
- Development: `DEVSPACE_DEV_POD_FORWARD_PORT=8766`

The reverse-tunnel port itself remains unchanged. The generic
`DEVSPACE_POD_FORWARD_PORT` is no longer emitted by new SSH sessions, but the
`dide` resolver recognizes it temporarily as a migration candidate for shells
launched by older builds.

## `dide` routing

Each invocation builds an ordered, de-duplicated candidate list:

1. Populated build-specific environment variables, with development checked
   before production when both are populated.
2. The populated legacy `DEVSPACE_POD_FORWARD_PORT`, if present.
3. The default development and production pod ports (`8766`, then `8765`).

For every candidate, `dide` requests `/api/v1/metadata` with the shared token
and a short timeout. It accepts a candidate only when:

- the endpoint returns a valid metadata response;
- `schema_version` is supported; and
- `build.channel` corresponds to the build-specific port value being used.

For a legacy candidate, the returned channel selects that channel's
build-specific variable when it is populated. That selected port is verified
against metadata before use; when the build-specific variable is absent, the
already-verified legacy port is used. A default candidate is accepted only when
its reported channel matches the default's build. The selected port is then
used for the authenticated `POST /dide` request. The first verified live route
wins; no attempt is made to distinguish which graphical client currently
displays the persistent pane.

The generated shell code must work in both Bash and Zsh and must not depend on
`jq`, Python, or another optional pod package. Because DevSpace controls the
compact metadata encoding, it can recognize the version and channel using
portable shell matching while rejecting missing or contradictory fields.

If no candidate can be verified, `dide` returns nonzero and reports that no
DevSpace build is connected. A failed final `/dide` request retains the current
nonzero `dide: request failed` behavior.

## Existing notification clients

Claude hooks and the optional manual notification helper currently read the
generic port variable too. Removing that variable from new SSH sessions must
not silently redirect development notifications to the production fallback.
They will use the same invocation-time metadata discovery and first-live-route
policy as `dide`, while retaining their existing payloads and best-effort
failure behavior. The resolver shell fragment is generated from one Core
implementation so the three clients cannot drift in candidate order,
authentication, or channel validation.

## Migration behavior

Connecting once updates the managed blocks in `.bashrc` and `.zshrc`. An
already-running persistent shell retains its loaded function definition, so it
must source its rc file once after upgrading. After that one-time refresh,
future build attachments require no shell restart because routing happens on
every `dide` invocation.

## Testing

Core tests will cover:

- build classification, environment-variable names, and SSH arguments for both
  bundle identifiers;
- authenticated metadata success for development and production listeners;
- unauthorized metadata requests and response headers/statuses;
- metadata encoding retaining the required fields when optional fields are added;
- Bash and Zsh `dide` routing through a reachable development-only endpoint;
- routing through a reachable production-only endpoint;
- deterministic first-success behavior when both endpoints are reachable;
- legacy-variable migration and fallback-port discovery;
- rejection of a candidate whose reported channel contradicts its
  build-specific environment variable;
- clear failure when no metadata endpoint is reachable; and
- hook/manual-helper routing without the removed generic SSH variable.

The complete Swift test suite and a development bundle build validate the
change. No release build is required.
