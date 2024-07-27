# How to release a new version of Wasmex

1. Make sure CI is green and `CHANGELOG.md` is up to date
1. Increase the package version in `mix.exs`, `README.md` and `Cargo.toml` - best grep for the current version and replace it
1. Commit the version bump and push it
1. Tag the commit with the new version number `git tag -a v0.8.0` - copy the changelog into the tag message
1. Push the tag `git push --tags`
1. Wait for the CI to create the github release and precompied binaries
1. Edit the GitHub release with the `CHANGELOG.md` content
1. Download the precompiled binaries with `mix rustler_precompiled.download Wasmex.Native --all --ignore-unavailable --print`
1. Inspect the output and the checksum-Elixir.Wasmex.Native.exs file
1. Continue with `mix hex.publish`
