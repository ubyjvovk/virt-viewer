# macOS

## Continuous integration

GitHub Actions workflow `.github/workflows/macos.yml` builds and tests every
push and pull request on `macos-latest` (Homebrew dependencies plus
`bash build-aux/macos/check.sh`). Meson logs are uploaded as artifacts; a
`.app` bundle is uploaded too when one is present under `build/`.
