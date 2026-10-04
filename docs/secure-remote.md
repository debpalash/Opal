# Secure remote access

Web Remote is off until enabled and binds to `127.0.0.1` by default. Missing or
invalid bind settings also select loopback. Existing profiles that explicitly
saved `web_bind=lan` keep that setting; plain LAN HTTP does not encrypt passwords
or session cookies. Use HTTPS for phones and other network clients.

## HTTPS with a local reverse proxy

Run the TLS proxy on the same host as Opal. Set `OPAL_HTTPS_PROXY=1` in Opal's
service environment before starting it. This mode:

- forces the HTTP listener to `127.0.0.1`, including profiles previously set to LAN;
- marks login cookies `Secure`, `HttpOnly`, and `SameSite=Strict`;
- refuses API requests to change the listener to LAN;
- ignores `Forwarded` and `X-Forwarded-Proto` for transport trust.

Only the proxy should accept network connections. Do not publish Opal's HTTP
port through Docker, a tunnel, or a second proxy that accepts plain HTTP.
Other local processes are within the host trust boundary and can reach the
loopback listener. HTTPS mode is a deployment setting, not TLS inside Opal.

For Caddy on the same host, use a name resolving to that host:

```caddyfile
opal.home.arpa {
    tls internal
    reverse_proxy 127.0.0.1:41595
}
```

Trust Caddy's local CA on each client before opening `https://opal.home.arpa`.
For a publicly resolvable domain with a valid certificate, use that hostname and
your proxy's normal certificate provisioning instead of `tls internal`. Keep the
upstream on loopback. This example assumes both processes share the host network;
containers must share the proxy's network namespace for this mode. The bundled
Docker image instead explicitly sets `OPAL_WEB_BIND=lan` inside its container;
Compose publishes that port only on host loopback. For Secure cookies with a
container, run Opal and the TLS proxy in a shared network namespace and set
`OPAL_HTTPS_PROXY=1`; it overrides the image's LAN setting.

Create the first administrator from the trusted host before using the DNS name.
First-admin registration deliberately accepts only an IP literal or localhost
Host header, plus the owner-only `setup.token`; it does not accept DNS hostnames.
Use the desktop setup flow before enabling HTTPS proxy mode, or a local native
client submitting that token to `http://127.0.0.1:41595/api/auth/register`.
Then sign in through HTTPS. Do not open the direct HTTP UI in proxy mode: browser
sessions are intended for the HTTPS origin.

## Account authority

Ordinary accounts can browse and control playback. Host settings, integration
credentials, source management, and library-root changes require an administrator
or the machine credential. Media state remains shared between accounts.

Executable plugin approval is stronger authority: browser accounts, including
administrators, cannot grant or revoke it. Review the exact plugin files on the
host, then use the owner-only machine credential with the local plugin approval
API, or create the exact content-approval marker shown in the native Logs view.
Every executable, including Lua scripts, requires this approval. Updates invalidate
it. Restricted Lua execution is defense in depth; it is not an OS sandbox.
