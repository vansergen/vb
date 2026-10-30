# Changelog

## [3.0.1](https://github.com/vansergen/vb/compare/v3.0.0...v3.0.1) (2026-10-30)

### Build System

- bump alpine from 3.24.2 to 3.24.3 ([026c267](https://github.com/vansergen/vb/commit/026c267da77c5d52aff6801d0048dd90a0fe3285))

## [3.0.0](https://github.com/vansergen/vb/compare/v2.0.0...v3.0.0) (2026-10-18)

### ⚠ BREAKING CHANGES

- vb is now licensed under MIT instead of AGPL-3.0-only.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011nRLfyq4VM6qJ5tq7RzAqC

### Build System

- ship the license text and label in the image ([bd227dc](https://github.com/vansergen/vb/commit/bd227dc82334cfe6e09f5e06a174ac1643f2324b))

### Metadata

- relicense under MIT ([bd8fa17](https://github.com/vansergen/vb/commit/bd8fa173f1f2ce41b31cef13736de4a0e7bd6b3e))

## [2.0.0](https://github.com/vansergen/vb/compare/v1.1.1...v2.0.0) (2026-10-18)

### ⚠ BREAKING CHANGES

- restore requires the .sha256 checksum file of an archive
  (pass -U to restore one without it). `restore -a` without -v restores only
  mounted volumes. Top-level names starting with .vb-restore are reserved,
  and volumes holding `.restore-in-progress.*` directories from version 1
  are refused instead of cleaned up. Backups and restores need flock support
  on the volume filesystem.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011nRLfyq4VM6qJ5tq7RzAqC

- the image no longer contains `mc` and uses tini as its
  entrypoint. AWS_ENDPOINT_URL must be scheme://host[:port]. Without
  AWS_REGION, the bucket region is detected on AWS and us-east-1 is used
  for custom endpoints. Providers that reject conditional writes are
  refused unless S3_ALLOW_UNCONDITIONAL_WRITES=1. S3 folders and keys are
  limited to path segments of letters, digits, '.', '_' and '-'.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011nRLfyq4VM6qJ5tq7RzAqC

### Features

- add zstd, rotation, listing, verification and S3 restore -a ([0dd7634](https://github.com/vansergen/vb/commit/0dd7634ff4efc74f74535a83b44bfbe4b5edeb43))
- make restores transactional and crash-safe ([0473959](https://github.com/vansergen/vb/commit/04739596805afa8aad3f2e10cc3f70fe670d2961))
- replace the MinIO client with a curl-based S3 client ([134deba](https://github.com/vansergen/vb/commit/134deba9b0482717789dd2394ade038ca59af1a7))

### Bug Fixes

- check the status of every sort that feeds a list ([cdce41b](https://github.com/vansergen/vb/commit/cdce41bafbe7afe8a48d538cff4571725c008bfe))
- detect GNU tar without piping its version into grep -q ([8ce0c07](https://github.com/vansergen/vb/commit/8ce0c07068509dbe683157b97efd4ebc016fa9c8))
- do not combine --path-as-is with sigv4 ([f43f0f1](https://github.com/vansergen/vb/commit/f43f0f1bf7e2b9b1f198dd95d83f5dcebe80e9bc))
- harden signal handling, child reaping, GPG use and path guards ([630adc5](https://github.com/vansergen/vb/commit/630adc510efd9c598fe48cb31fa1185b4b272a16))
- keep creation directories that do not match what the tool writes ([f7d24af](https://github.com/vansergen/vb/commit/f7d24af66641ba236cb049bf09c7669723fb9171))
- keep the restore journal when a rollback step fails ([efbe28a](https://github.com/vansergen/vb/commit/efbe28ab5dfb7378ee7ab8c311aa7a165c1a412c))
- never act on an incomplete listing or directory scan ([f8d4c92](https://github.com/vansergen/vb/commit/f8d4c9209015549e58e0d82ab7e1bac6b360c561))
- never roll back a restore whose commit decision is on disk ([0257602](https://github.com/vansergen/vb/commit/0257602816343af0632cf7c8b7b4b5681f3fc739))
- refuse restore -X together with -n, -C or -j ([5599d98](https://github.com/vansergen/vb/commit/5599d98a168870619321f0f5a23c50103e36faed))
- refuse S3 rotation when an object to delete has no ETag ([175ac21](https://github.com/vansergen/vb/commit/175ac21ed9d146b899a4d98e9f76a97dcb9cbeee))
- reject the whole S3 listing when reading it fails ([4f4622f](https://github.com/vansergen/vb/commit/4f4622f0f6d40dbdc8519687552078e4be02dc99))
- reject unsafe volume names and unblock image build ([587d873](https://github.com/vansergen/vb/commit/587d873ab83744ce8fdbf652f333b69fdf010995))
- treat unreadable checksum files, tokens and mount tables as errors ([d0fe306](https://github.com/vansergen/vb/commit/d0fe3064245061488f2e58f06b34a7a483a6b20e))

### Build System

- bump alpine from 3.23.3 to 3.24.2 ([6ba164d](https://github.com/vansergen/vb/commit/6ba164d88ca054755123b030b0d155607b22c2bc))

## [1.1.1](https://github.com/vansergen/vb/compare/v1.1.0...v1.1.1) (2026-06-12)

### Bug Fixes

- harden backup and restore safety checks ([f3aafc7](https://github.com/vansergen/vb/commit/f3aafc72a971467330775072e12e2b3182e527b4))

## [1.1.0](https://github.com/vansergen/vb/compare/v1.0.1...v1.1.0) (2026-05-22)

### Features

- harden backup/restore reliability and metadata handling ([14d6ca6](https://github.com/vansergen/vb/commit/14d6ca66797d1aeec19b37e52a1a6b24540be15c))

## <small>1.0.1 (2026-04-13)</small>

- fix: dummy commit to trigger a release ([537d296](https://github.com/vansergen/vb/commit/537d296))
- Merge pull request #10 from vansergen/dependabot/github_actions/actions/upload-artifact-7 ([7783373](https://github.com/vansergen/vb/commit/7783373)), closes [#10](https://github.com/vansergen/vb/issues/10)
- ci: bump actions/upload-artifact from 6 to 7 ([8cefc3d](https://github.com/vansergen/vb/commit/8cefc3d))

## 1.0.0 (2026-04-12)

- devDependencies: update semantic-release ([c881f89](https://github.com/vansergen/vb/commit/c881f89))
- Initial commit ([f896971](https://github.com/vansergen/vb/commit/f896971))
- Merge pull request #9 from vansergen/v1 ([a6a518c](https://github.com/vansergen/vb/commit/a6a518c)), closes [#9](https://github.com/vansergen/vb/issues/9)
- feat: add backup/restore scripts ([78b5fcf](https://github.com/vansergen/vb/commit/78b5fcf))
