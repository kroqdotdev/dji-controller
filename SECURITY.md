# Security policy

Lavboard installs a system audio driver and asks for administrator rights to do so, so security issues matter here.

Updates are only installed when they carry a valid EdDSA signature from the maintainer's update key and the app inside is signed with the same Developer ID as the installed copy.

## Reporting a vulnerability

Report vulnerabilities privately through [GitHub's private vulnerability reporting](https://github.com/kroqdotdev/lavboard/security/advisories/new). Please don't open a public issue.

Include what you found, how to reproduce it and which version or commit you tested. You'll get a reply as soon as possible, and a fix will be released before the details are made public.

## Supported versions

Only the latest version on `main` receives fixes.
