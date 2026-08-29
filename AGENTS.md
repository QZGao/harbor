# Harbor repository instructions

## Local builds

- Keep only one local Harbor build.
- Use `/Users/tahseen/Developer/Harbor/build/HarborDerivedData` as the DerivedData path.
- Before you make a new local build, delete old Harbor build and release outputs. Delete duplicate Harbor-specific Xcode DerivedData. Do not delete source files or files in Downloads.
- Use `script/build_and_run.sh` for an interactive build. Use its `build/HarborDerivedData` settings for noninteractive builds.
- After the build, verify the app version and build number in `Harbor.app/Contents/Info.plist`.
