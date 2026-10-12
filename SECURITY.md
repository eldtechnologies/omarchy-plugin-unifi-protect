# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/eldtechnologies/omarchy-plugin-unifi-protect/security/advisories/new),
not in a public issue.

Include the affected version or commit, what an attacker could do, and the
smallest reproduction you can. Leave out anything private: API keys, console
addresses, camera names or IDs, stream URLs, and camera images.

We aim to acknowledge reports within a week. Fixes go to `main` and ship in
the next release.

## Supported versions

Only the latest release and `main` receive security fixes.

## Trust boundary

Omarchy plugins run as unsandboxed code inside the desktop shell, so review
the source before installing. In short, this plugin:

- talks only to the UniFi consoles you configure, over HTTPS with a pinned
  certificate;
- keeps API keys, and the optional recordings login, out of the shell
  process, in your keyring (or a file only you can read when no keyring is
  available);
- keeps fetched recordings in memory only (the runtime directory, mode
  0700), deleted at logout, when the console is removed, and at reboot;
  only `clip -o` writes one to disk, where you asked;
- carries video over TLS through a local relay that listens on 127.0.0.1 only
  and requires a per-session token;
- keeps camera and console names, stream URLs and secrets out of command
  lines, which other local users can read: mpv gets them on stdin, and
  notifications go to the notification service over D-Bus;
- installs no service, runs no code at install time, and never uses `sudo`.

See "How it works" in the [README](README.md) for the details.
