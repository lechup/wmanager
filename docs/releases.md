# Releases

Computers installed from the internet get the latest release, not whatever is on `main`. To release, after the
changes are merged:

```bash
git tag v0.2.0 && git push origin v0.2.0
```

The `release` workflow checks that the tag is on `main`, builds the files with `tools/build-release.sh` and publishes
them as a GitHub release: `wmanager-v0.2.0.zip` (the repository without `tests/` and `.github/`, plus a `VERSION`
file), `install.ps1` and `SHA256SUMS`. The sums prove a download is complete and intact, not who built it: whoever can
publish releases in the repository decides what computers install, so guard that access (and the main branch). A tag with a suffix, e.g. `v0.2.0-rc1`, becomes a pre-release, which
"latest" skips; install it with `-Tag v0.2.0-rc1`. `tools/build-release.sh v0.2.0 dist` builds the same files
locally, to look at them first.

The logs show the version (`wmanager v0.2.0 provisioning: ...`, also in Loki); a copy run from a git checkout has no
`VERSION` file and logs just `wmanager`. Computers that are already installed don't follow "latest": with a management
source, name the new release in each source (see [Updating wmanager](groups.md#updating-wmanager)).
