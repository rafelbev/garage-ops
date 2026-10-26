# Authelia — 2FA gate for `*.garage.neo-tix.com`

Authelia (`auth.garage.neo-tix.com`) fronts every public `*.garage.neo-tix.com`
HTTPRoute via the `envoy-external` gateway. It acts as a **2FA gate** for
internet traffic: its `access_control` rules read the client IP from
`X-Forwarded-For`, which the Envoy gateway stamps with the **real public IP**
(VyOS preserves the source address on its TCP forward, so no L7 proxy is
needed).

## How the rules work

The `access_control` rules in `authelia/app/configmap.yaml` are evaluated in
order — **first match wins**:

1. **`bypass`** for `internal` sources (`172.20.0.0/16` LAN, `100.64.0.0/10`
   headscale) — all hosts, LAN-side.
2. **`bypass`** for the **whitelist** of hosts that already gate themselves
   with their own username/password (or equivalent) authentication — all
   sources. Adding a host here means Authelia's 2FA does not stack on top of
   the app's own login.
3. **`two_factor`** for everything else — public sources must complete 2FA.

## Evaluation when deploying a new HTTPRoute

When you add a new `*.garage.neo-tix.com` HTTPRoute, you **must** evaluate
whether the backend app has its own username/password (or equivalent)
authentication:

- **Yes** (the app has its own login) → add the host to the `bypass`
  whitelist in `authelia/app/configmap.yaml` (escape the dots:
  `'newhost\.garage\.neo-tix\.com'`).
- **No** (the app has no auth of its own) → do nothing; the host is
  automatically 2FA-protected by the catch-all `two_factor` rule.

**Record this evaluation in the PR description** so reviewers can verify the
decision. Include a line such as:

> **Authelia:** `<host>.garage.neo-tix.com` has its own username/password auth
> → added to the bypass whitelist.
> _(or: has no app-level auth → stays 2FA-protected, no whitelist change
> needed.)_

## Current bypass whitelist (own username/password auth)

As of this writing, the following hosts are in the `bypass` whitelist:

`audiobookshelf` · `chat` (Open WebUI) · `esphome` · `file` · `git`
(Forgejo) · `gonic` · `headlamp` · `headscale` · `hermes-dashboard` ·
`home-assistant` · `jellyfin` · `llama-cpp` · `litellm` · `matrix` ·
`music` (Music Assistant) · `n8n` · `photos` (Immich) · `proxmox` ·
`qbittorrent`

## Pitfalls

- **Escaped dots in the whitelist regexes.** The whitelist entries use
  escaped dots (`photos\.garage\.neo-tix\.com`) so they match exactly and do
  not accidentally swallow subdomains or neighbouring hosts the way the loose
  catch-all `'(.*).garage\.neo-tix\.com'` does.
- **Rule order matters.** Authelia evaluates `access_control.rules` in order;
  the first match wins. The whitelist `bypass` rule must come **before** the
  `two_factor` rule, otherwise it is never reached.
- **Token / API-key auth also qualifies for the whitelist.** Apps like
  `headscale` (token), `litellm` (API key), and `llama-cpp` (API key) gate
  themselves with their own auth mechanism and are included in the bypass
  whitelist — Authelia's 2FA does not stack on top of them.
- **The `internal` network list is precise, not broad.** It is
  `172.20.0.0/16` + `100.64.0.0/10`. Do not revert it to the old broad
  private ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/18`) — that
  would let any private-range source (including the VyOS hop) bypass auth.
