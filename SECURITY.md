# Security policy

## Supported versions

Security fixes are made on the `main` branch and go into the next release.
Only the latest version of normet is supported.

## Reporting a vulnerability

Please do **not** report security vulnerabilities in public GitHub issues.

1. **Preferred:** report it privately through GitHub's private vulnerability
   reporting. Use the **Report a vulnerability** button in the repository's
   [Security tab](https://github.com/apai-sys/normet-r/security).
2. **If that button is not available:** email the maintainer, Congbo Song
   (<congbo.song@manchester.ac.uk>), with "normet security" in the subject.

Please include:

- the normet version (`packageVersion("normet")`) and your R version;
- what the vulnerability is and what an attacker could do with it;
- the steps or a minimal example that reproduces it.

## Scope

normet downloads data from public services (UK-AIR, EEA, OpenAQ, the Copernicus
CDS, Open-Meteo, NOAA ARL), runs HYSPLIT as a subprocess, serves tools to
AI agents through `nm_mcp_server()`, and ships a desktop GUI (`gui/`) that runs
R through `Rscript` subprocesses. Problems in any of these code paths are in
scope. Vulnerabilities in those external services, or in R packages normet
depends on, should be reported to their own maintainers.
