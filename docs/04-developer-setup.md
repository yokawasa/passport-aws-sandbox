# 04. Developer Setup

> **Audience**: developers (the people who call the APIs)
> **Time required**: 10-15 minutes
> **Prerequisites**: an administrator has completed [01](01-infrastructure.md) through
> [03](03-dns-and-exposure.md)

Install the Passport CLI and get to the point where you can call APIs using secret
references.

## What you need beforehand

There are only two things you need.

- A Postman account (invited to the team in Passport Cloud)
- Permission to install the Passport CLI (on macOS, the administrator password)

---

## Step 1. Install the Passport CLI

### macOS or Linux

Run the install command in your terminal:

```sh
curl -fsSL "https://dl-passport.pstmn.io/install/enterprise/unix.sh" | sh
```

### Windows (PowerShell)

Run the install command in PowerShell:

```powershell
irm "https://dl-passport.pstmn.io/install/enterprise/win64.ps1" | iex
```

> The Windows path is unverified (this repository has only been exercised on macOS arm64).

### Verify the installation

```bash
passport --version
```

## Step 2. Check the current state (optional)

Nothing is configured right after installation.

```bash
passport auth status      # → not logged in — run `passport login`
passport daemon status    # → Passport daemon: not running
passport ca status        # → no Passport CA certificate at ~/.passport/ca.pem
```

Each of these commands is also useful later for troubleshooting.

## Step 3. Log in

```bash
passport login
```

> **`passport login` runs setup automatically by default.**
> Add `--no-setup` if you want to stop the automatic setup.

| Option | Purpose |
| --- | --- |
| `--with-api-key <apikey>` | Authenticate with an API key instead of a browser (for CI) |
| `--region eu` | Authenticate against the EU region |
| `--no-setup` | Skip the automatic setup that follows login |
| `--verbose` | Show error details |

```bash
passport auth status
```

## Step 4. Verify the permissions landed

Permission to use secret references is baked into the client certificate. **`login`
succeeds even when it did not land**, so always check.

```bash
passport whoami
```

Example output

```text
Passport identity:
  userId       user_01EXAMPLE...
  teamId       org_01EXAMPLE...
  allowedApiRefs
    GET httpbin.org/anything/*
      - httpbin-token  (aws)  →  {{vault:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}}

  notBefore    2026-01-01T00:00:00.000Z
  notAfter     2026-01-01T00:05:00.000Z  (valid for 85s)
```

**If a resource appears under `allowedApiRefs`, you are done.** Move on to Step 5.

> **The `{{vault:...}}` shown is ready to use as-is.** You can copy the reference you need
> for Step 5 straight from here, so there is no need to look up the UUID separately.

If `allowedApiRefs` stays `(none)`, or you cannot connect, see
[troubleshooting](troubleshooting.md#developer-setup).

To see it as JSON (CLI 0.7.0 and later):

```bash
passport whoami --json
```

```json
{"mode":"user","userId":"user_01EXAMPLE...","teamId":"org_01EXAMPLE...",
 "email":"you@example.com","allowedApiRefs":{"GET httpbin.org/anything/*":[
   {"secretReference":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    "name":"httpbin-token","vaultType":"aws"}]},
 "notBefore":"...","notAfter":"...","validity":"VALID"}
```

**If `validity` is `EXPIRED`,** reissue the certificate with `passport refresh`
(the TTL is 300 seconds at most).

## Step 5. Verify traffic through Passport

### 5-1. Start with a plain request to confirm connectivity

```bash
passport request https://httpbin.org/get --show-headers
```

If the `origin` in the response is **the outbound IP of the network the Proxy runs in**
(on AWS, the NAT Gateway's IP), the traffic really did go through the Proxy.

```bash
# For an administrator cross-checking this
aws ec2 describe-nat-gateways --region ap-northeast-1 \
  --filter Name=state,Values=available \
  --query 'NatGateways[].NatGatewayAddresses[].PublicIp'
```

### 5-2. Use a secret reference

**What you write in `{{vault:...}}` is the UUID Passport issued.**
It is not the Secrets Manager key name.

| Where it goes | Value |
| --- | --- |
| The Namespace's **vault key** field (set by the administrator) | `passport/demo/httpbin-token` (the Secrets Manager key name) |
| **`{{vault:...}}`** (written by the developer) | `aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee` (the UUID Passport issued) |

The references available to you appear verbatim in the `passport whoami` output from
Step 4.

```text
  allowedApiRefs
    GET httpbin.org/anything/*
      - httpbin-token  (aws)  →  {{vault:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}}
```

Putting the secret in a header is the practical choice.

```bash
passport request https://httpbin.org/anything/test \
  --show-headers \
  -H 'Authorization: Bearer {{vault:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}}'
```

On success, **the resolved real value, not the reference you sent**, arrives at the
other end.

```json
{
  "headers": {
    "Authorization": "Bearer passport-demo-token-not-a-real-credential"
  },
  "origin": "16.76.114.120",
  "url": "https://httpbin.org/anything/test"
}
```

> **Put the URL in the first argument.**
> Writing it after the options gives you `error: missing required argument 'url'`.
>
> **`{{vault:...}}` can go in the header, the body, the URL, or a query parameter**
> (the CLI help states this explicitly). Note, however, that when you embed one in the
> path, **the resolved path has to match the resource definition**. If the secret value
> itself ends up in the path, it can only be matched by a wildcard (such as
> `/anything/*`). Putting it in a header is the most reliable option.

### 5-3. Narrowing down errors

| Response | `x-passport-proxy-error` | Cause |
| --- | --- | --- |
| **403** | `unauthorized` | The reference is not permitted. Check whether you passed `--namespace-id`, and whether the administrator linked the resource and the secret in the Namespace |
| **502** | `decrypt-failed` | The public key registered with the Access Proxy is **not the reference key**. A misconfiguration on the administrator's side |
| **200** | — | Success |

### Main options for `passport request`

| Option | Purpose |
| --- | --- |
| `-X, --method <method>` | HTTP method (default `GET`) |
| `-H, --header <header...>` | Additional headers. Can be given more than once |
| `-d, --data <body>` | Request body |
| `--show-headers` | Also show the response status and headers |
| `--insecure-proxy-hostname` | Skip hostname verification for the outer TLS (certificate chain verification continues) |

---

## Step 6. Request access

Sign in to Passport Cloud and request access to the endpoints you need. Once an
administrator approves, the secret references become usable.

---

## Day-to-day operation

### Managing the daemon

```bash
passport daemon status      # check the state
passport daemon start       # start
passport daemon stop        # stop
passport daemon restart     # restart
passport daemon logs -f     # follow the logs
```

**To have it come up automatically after a Mac restart**, install the LaunchAgent.

```bash
passport daemon install
```

> With this in place you no longer have to type `export HTTPS_PROXY=...` every time.
> **For developers it is effectively mandatory.**
>
> **⚠️ Right after `daemon install`, `HTTPS_PROXY` does not take effect in terminals that
> are already open.** Open a new terminal.

### Reissuing the certificate

The certificate TTL is 300 seconds at most. You can tell it expired from `validity` in
`whoami`.

```bash
passport refresh          # reissue the certificate (leaves the daemon alone)
passport refresh --ttl 300
```

> `passport request` renews automatically, so you normally do not need this command.
> Use it when `whoami` says `EXPIRED`, or right after an administrator changes the
> resources in a Namespace.

### Checking the logs

```bash
passport logs                          # merge all logs chronologically
passport logs --source connections     # connection records only
passport logs --source events          # daemon lifecycle events only
passport logs -f --level warn          # stream warn and above
passport logs --json                   # output as JSON
passport logs:clear                    # rotate
```

### The OS trust store

If you send traffic through Passport from tools that use the OS trust store (browsers,
some language runtimes), you have to make them trust the CA.

```bash
passport ca install      # register in the system keychain (requires administrator privileges)
passport ca status       # check the registration state
passport ca uninstall    # remove
```

> `passport ca install` is unverified (everything here was exercised with `trusted no`).

### The TUI dashboard

```bash
passport
```

| Option | Purpose |
| --- | --- |
| `--theme <name>` | `passport` / `matrix` / `nord` / `mocha` |
| `--no-animation` | Disable motion effects |
| `--ascii` | Render with ASCII only |
| `--color <value>` | `auto` / `on` / `off` |

## Confirming you are done

- [ ] `passport --version` prints a version
- [ ] `passport auth status` shows you are logged in
- [ ] A resource appears under `allowedApiRefs` in `passport whoami`
- [ ] `passport request` shows the Proxy's outbound IP as `origin`
- [ ] `{{vault:...}}` resolves to the real value

## Uninstalling

```bash
passport daemon uninstall    # remove the daemon's auto-start and managed environment
passport ca uninstall        # remove the CA from the trust store
passport logout              # delete the stored Postman API key
```

After that, remove the CLI itself with the uninstall script that ships with it.

---

If you run into trouble, see [troubleshooting](troubleshooting.md).
