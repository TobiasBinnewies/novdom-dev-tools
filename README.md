# novdom dev tools

This is a fork of the [lustre-dev-tools](https://github.com/lustre-labs/dev-tools) so most of the tooling is the same. \
Adapted to work with the [novdom](https://github.com/TobiasBinnewies/novdom).

## Features added

- [x] Added `init` command to create the inital project structure. \
  - Adding relevant js packages needed by novdom using `bun`.
  -❌ Adding Typescript support for the project.
  - Adding TailwindCSS support for the project.
- [ ] Changed the `build` command a bit.
  -❌ Added `tsc` to compile the typescript files.
  - Added `--prod` flag to minify the output and move it to the `dist` folder (can be changed by `--outdir={new/dir}`).
  - When building for development, the output will be in the `build` folder (can be changed by `--outdir={new/dir}`). --> Is there a way to not bundle into one file using esbuild?