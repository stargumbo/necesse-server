# Docker Hub overview

The Docker Hub page of `stargumbo/necesse-server` is not maintained by hand. Whenever `README.md` changes
on `main`, `.github/workflows/hub-readme.yml` copies the top of the repository [README](../README.md), down
to the `docker-hub-overview-ends-here` marker, into the Hub overview and sets the short description. Edit
the README; the Hub page follows within a minute of the merge. The workflow can also be dispatched by hand
from the Actions tab. It builds no image and moves no tag, and the publish workflow does not touch the
overview, so the Hub page always reflects `main`, never the README of whichever tag was last rebuilt.

Relative links in the README (`LICENSE`, `CHANGELOG.md`, `docs/`) are rewritten to absolute GitHub URLs by
the sync; the banner is already referenced by its absolute `raw.githubusercontent.com` URL so it renders on
Hub as-is. The overview must stay under 25,000 bytes; move the marker up if it grows past that.
