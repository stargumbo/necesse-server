# Docker Hub overview

The Docker Hub page of `stargumbo/necesse-server` is not maintained by hand. On every publish,
`.github/workflows/publish.yml` copies the top of the repository [README](../README.md), down to the
`docker-hub-overview-ends-here` marker, into the Hub overview and sets the short description. Edit the
README; the Hub page follows on the next release or weekly rebuild.
