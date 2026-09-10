# Necesse Docker Server Documentation

The [README](../README.md) is the short version. This directory holds the rest.

## For operators

- [Reference](reference.md): every environment variable, `docker run` and Compose, tags and
  registries, secrets, the console, data and permissions, updates and troubleshooting,
  contributing.
- [Coming from another image](migration.md): keep your volumes and variable names, the alias
  table, and how to go back.
- [Internals](internals.md): how the graceful stop, the password path, the console helper and the
  Workshop fetch work.
- [CHANGELOG](../CHANGELOG.md): notable changes per release.

## For contributors

- [Git, Branching, and Tagging Guide](GIT_GUIDE.md): workflow overview, branching strategy, and
  release tagging process.
- [Commit Guide](GIT_COMMIT_GUIDE.md): pre-commit checklist, formatting hints, and commit message
  conventions.
- [Release Guide](GIT_RELEASE_GUIDE.md): step-by-step checklist for preparing, tagging, and
  publishing a release.
- [Docker Hub Overview](DOCKER_HUB_OVERVIEW.md): how the Docker Hub page is generated from the
  README on publish.
- Assets: `docs/assets/banner.webp`, the README header image (original artwork; the README links
  it by its absolute raw URL so the Docker Hub overview shows it too).

More docs to add? Open a pull request or update this index to keep the list current.
