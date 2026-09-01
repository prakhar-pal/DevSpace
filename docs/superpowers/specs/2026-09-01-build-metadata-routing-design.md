# Build-Aware Best-Effort Pod Routing Design

## Problem

DevSpace and DevSpaceDev use separate reverse-tunnel ports, but pod-side
clients currently read one generic `DEVSPACE_POD_FORWARD_PORT` environment
variable. Persistent shells retain their launch-time environment, so attaching
the same shell through another build does not refresh that value. A stale value
can therefore make `dide` target an absent tunnel while the other DevSpace
build has a live one.

## Goals

- Let production and development builds maintain simultaneous reverse tunnels.
- Use separate environment variables for the two builds.
- Route pod-side requests using live tunnel availability at invocation time.
- Prefer production whenever both tunnels are live and use development as the
  fallback.
- Avoid adding an API or persistent routing registry.

## Non-goals

- Identifying which graphical client is currently displaying a persistent
  shell.
- Adding a build selector or metadata endpoint.
- Changing notification payloads or desktop notification behavior.

## SSH environment

New SSH processes advertise only the variable belonging to their build:

- Production: `DEVSPACE_PROD_POD_FORWARD_PORT=8765`
- Development: `DEVSPACE_DEV_POD_FORWARD_PORT=8766`

The reverse-tunnel ports remain unchanged. New sessions no longer emit the
generic `DEVSPACE_POD_FORWARD_PORT` variable.

Pod-side routing uses the build-specific variables when they exist and the
stable build-specific port as its fallback:

```sh
prod_port="${DEVSPACE_PROD_POD_FORWARD_PORT:-8765}"
dev_port="${DEVSPACE_DEV_POD_FORWARD_PORT:-8766}"
```

These defaults are important for persistent shells launched before either
build-specific variable existed.

## Availability resolution

At invocation time, a portable shell resolver performs a short,
side-effect-free HTTP connection check against the production tunnel. The
existing listener already responds successfully to a bodyless request without
invoking a route, so this requires no new endpoint. If production responds,
its port is selected. Otherwise the resolver checks and selects the development
port. If neither responds, resolution fails.

The policy is therefore deterministic:

1. Live production tunnel.
2. Live development tunnel.
3. No route.

The check uses `curl`, which is already required by the pod-side clients. It
uses a short timeout and discards the response body. The resolver validates
that candidate values are decimal TCP port numbers before interpolating them
into a URL. This prevents inherited or user-supplied environment values from
altering curl arguments or the URL structure.

This is intentionally best effort. A listener may disappear between the
availability check and the request; in that case the request reports its normal
failure rather than attempting a second build and risking duplicate actions.

## Client behavior

`dide` resolves the port immediately before its authenticated `POST /dide`.
When neither tunnel is available it returns nonzero with a clear
`dide: no DevSpace connection available` message. A failure after selecting a
port retains the existing `dide: request failed` behavior.

Claude hooks and the optional manual notification helper currently depend on
the generic variable too. Removing it from SSH must not redirect development
notifications to the production default, so these clients use the same
production-first resolver. Their payloads and best-effort/silent failure
behavior remain unchanged.

The resolver shell fragment is generated from one Core implementation so
`dide`, hooks, and the manual helper cannot drift in variable names, defaults,
validation, candidate order, or timeout behavior. It must work in Bash, Zsh,
and POSIX `/bin/sh` without `jq`, Python, `nc`, or other optional pod packages.

## Migration behavior

Connecting once updates the managed blocks in `.bashrc` and `.zshrc` and
refreshes the generated hook commands. An already-running persistent shell
retains its loaded `dide` function, so it must source its rc file once after
upgrading. After that one-time refresh, routing is decided on every invocation
and later dev/prod attachments require no restart.

## Testing

Core tests will cover:

- build classification and the correct build-specific SSH environment variable
  for both bundle identifiers;
- omission of the generic SSH variable;
- validation of candidate port values;
- production selection when only production is live;
- development fallback when production is unavailable;
- production precedence when both are live;
- clear failure when neither tunnel is live;
- Bash and Zsh `dide` requests using the resolved port; and
- hook/manual-helper routing without the generic variable.

The complete Swift test suite and a development bundle build validate the
change. No release build is required.
