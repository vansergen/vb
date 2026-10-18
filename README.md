# Docker Volume Backup [![code style: prettier](https://img.shields.io/badge/code_style-prettier-ff69b4.svg)](https://github.com/prettier/prettier) [![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-2.1-4baaaa.svg)](CODE_OF_CONDUCT.md) [![semantic-release](https://img.shields.io/badge/%20%20%F0%9F%93%A6%F0%9F%9A%80-semantic--release-e10079.svg)](https://github.com/semantic-release/semantic-release) [![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-yellow.svg)](https://conventionalcommits.org)

A utility for backing up and restoring Docker volumes.  
Runs as a Docker/Podman container. Provides two scripts: `backup` and `restore`.

---

## Table of Contents

- [Features](#features)
- [How It Works](#how-it-works)
- [Quick Start](#quick-start)
- [Mounting Volumes](#mounting-volumes)
- [backup script](#backup-script)
- [restore script](#restore-script)
- [Environment Variables](#environment-variables)
- [Backup File Formats](#backup-file-formats)
- [Examples: Compression and Encryption](#examples-compression-and-encryption)
- [Examples: S3](#examples-s3)
- [Examples: All Volumes](#examples-all-volumes)
- [Backing up every Docker volume on the host](#backing-up-every-docker-volume-on-the-host)
- [Dry Run](#dry-run)
- [Automation with cron](#automation-with-cron)
- [Production Recommendations](#production-recommendations)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)

---

## Features

**Backup:**

- Back up a single volume to an archive
- Back up all volumes from `/volumes`
- Save archives locally or upload to S3
- Compress with `pigz` / `gzip`
- Encrypt with GPG (symmetric passphrase or asymmetric public key)
- Run backups for multiple volumes in parallel
- Assign a shared timestamp to a group of backups
- Write a SHA256 checksum alongside every archive (local and S3)
- Preserve sparse files, POSIX ACLs, and extended attributes when GNU `tar` is available
- Back up live volumes: files that change while they are read only produce a warning (`-S` makes it an error)

**Restore:**

- Restore a single volume from a local file or from S3
- Restore all volumes from a backup directory
- Restore only selected volumes
- Filter by a specific timestamp
- Clear a volume before restoring (`-C`)
- Run restores for multiple volumes in parallel
- Verify every archive against its SHA256 checksum (local and S3); archives without one are refused unless `-U` is given
- Transactional restore: all selected volumes switch to the new data together or all keep their original data, even after a crash or power loss (see [Transactional restore](#transactional-restore))
- Restore the owner, mode, ACLs, extended attributes, and mtime of the volume root itself

---

## How It Works

### Backup

```
Docker volume → tar archive → [gzip compression] → [GPG encryption] → local file or S3
```

The filename is generated automatically:

```
<VOLUME>_<YYYYMMDD_HHMMSS>.tar
<VOLUME>_<YYYYMMDD_HHMMSS>.tar.gz
<VOLUME>_<YYYYMMDD_HHMMSS>.tar.gpg
<VOLUME>_<YYYYMMDD_HHMMSS>.tar.gz.gpg
```

A `.sha256` checksum file is written alongside each archive — for both local backups and uploads to S3.

### Restore

```
local file or S3 → [SHA256 verification] → [GPG decryption] → [gzip decompression] → Docker volume
```

The format is detected automatically from the file extension.

The archive is verified against its `.sha256` companion file while it is extracted. A missing or unreadable checksum file aborts the restore before anything is changed (pass `-U` to restore an archive that has none, such as a backup whose upload was interrupted), and a mismatch leaves the target volume untouched.

### Transactional restore

A restore of one volume and a restore of many volumes with `-a` both work as one transaction:

1. **Stage.** Each archive is extracted and verified into a journal directory, `.vb-restore`, inside its target volume. Nothing outside the journal changes yet, so a wrong passphrase, a corrupt archive, or a network error in any of the volumes leaves **all** of them untouched.
2. **Switch.** The current top-level entries of every volume are renamed into the journal and the new ones are renamed into place. Renames are quick and need no extra space.
3. **Commit.** Once every volume has switched, the commit decision is written durably to the journal of the first volume.
4. **Finalize.** The old data is deleted and the owner, mode, ACLs, extended attributes, and mtime of each volume root are restored.

Every step is written ahead to the journal and synced to disk before it starts. If the restore is interrupted (`SIGKILL`, a crash, power loss) before the commit, the volumes are rolled back to their original data; after the commit, the new data is kept and the cleanup is completed. This happens automatically the next time a restore touches those volumes, or explicitly with `restore -X`. Recovery needs every volume of the interrupted restore mounted and refuses to change anything otherwise.

Things to keep in mind:

- **Disk space.** Until a restore finishes, a target volume holds both the old and the new data, so it needs free space for the extracted archive.
- **Locking.** A restore holds an exclusive lock (`flock`) on each target volume, and a backup holds a shared lock on its source volume. A backup and a restore of the same volume, or two restores, never run at the same time; the second one fails immediately with `Another backup or restore is using …`. The lock is taken on the volume directory itself, so the filesystem must support `flock` (some NFS setups do not, and the tool then refuses to run).
- **Reserved names.** Top-level names starting with `.vb-restore` belong to the tool. A backup refuses a volume that holds such an entry, and a restore refuses an archive that contains one. Entries that the tool cannot identify as its own journal (by their name and signature) are never deleted; the tool stops and asks you to inspect them. Directories named `.restore-in-progress.*`, left by an interrupted restore of version 1, are treated the same way, because they may hold the only copy of data.
- **Nested mounts.** A target volume that contains another mount point (for example a bind mount inside the volume) is refused, because its contents cannot be switched by renames.
- **Root mtime.** The final mtime of a volume root is kept in the `user.vb-restore.mtime` extended attribute until the restore completes. On filesystems without user extended attributes, a crash during the very last cleanup step can leave the mtime of the volume root (and nothing else) different.
- **Stopping.** `docker stop` before the commit rolls back immediately. After the commit, the restore exits and the next restore (or `restore -X`) finishes it. For large volumes, give the container time to roll back (`docker stop -t 60`).

---

## Quick Start

### Back up a single volume locally

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb backup -v postgres_data
```

The archive will appear at `./backups/postgres_data_<timestamp>.tar`.

### Restore a volume from a file

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb restore -i postgres_data_20250411_120000.tar -t postgres_data -C
```

### Back up all volumes

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume redis_data:/volumes/redis_data \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb backup -a -c
```

### Restore all volumes

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume redis_data:/volumes/redis_data \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb restore -a -T 20250411_120000 -C
```

---

## Mounting Volumes

The container reads and writes volumes from `/volumes` inside itself.  
Mount each volume you want to work with using `--volume <name>:/volumes/<name>`.

Volume names follow Docker's naming rule: they must start with a letter or digit and may contain only letters, digits, `.`, `_`, and `-`. Each volume must be a directory directly inside `/volumes`; symlinks that point elsewhere are refused.

### Named Docker volumes

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume redis_data:/volumes/redis_data \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb backup -a -c
```

### GPG key files

If you use file-based encryption (rather than environment variables):

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume ./backups:/backups \
  --volume ./gpg:/gpg \
  ghcr.io/vansergen/vb backup -v postgres_data -c -e -k public.asc
```

The key file must be present at `./gpg/public.asc` (or another path specified with `-k`).

---

## backup script

### Modes

| Mode                      | Command                                         |
| ------------------------- | ----------------------------------------------- |
| Single volume             | `backup -v <name> [options]`                    |
| All volumes               | `backup -a [options]`                           |
| Selected volumes from all | `backup -a -v <name> [-v <name> ...] [options]` |

### Options

| Option        | Description                                                               |
| ------------- | ------------------------------------------------------------------------- |
| `-v <name>`   | Volume name (directory inside `/volumes`)                                 |
| `-a`          | Back up all volumes found in `/volumes`                                   |
| `-d <dir>`    | Backup directory override (default: `/backups`)                           |
| `-T <ts>`     | Set timestamp manually (format: `YYYYMMDD_HHMMSS`)                        |
| `-j <N>`      | Parallel jobs in `-a` mode (`1`–`99`, default: `1`)                       |
| `-c`          | Compress with `pigz` if available, otherwise `gzip`                       |
| `-e`          | Asymmetric GPG encryption (public key)                                    |
| `-s`          | Symmetric GPG encryption (passphrase)                                     |
| `-b <bucket>` | Upload to S3 bucket                                                       |
| `-f <path>`   | Folder / prefix inside the S3 bucket                                      |
| `-k <file>`   | Public key file inside `/gpg` (default: `public.gpg`)                     |
| `-n`          | Dry run: validate and print what would be done without creating any files |
| `-S`          | Strict: fail when files change while they are archived (default: warning) |
| `-h`          | Show help                                                                 |

### Examples

#### Simple backup of a single volume

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb backup -v postgres_data
```

#### Backup with compression

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb backup -v postgres_data -c
```

#### Backup to a custom directory

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume /mnt/nas/backups:/custom-backups \
  ghcr.io/vansergen/vb backup -v postgres_data -c -d /custom-backups
```

#### Back up specific volumes from several mounted ones

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume redis_data:/volumes/redis_data \
  --volume uploads:/volumes/uploads \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb backup -a -v postgres_data -v redis_data -c
```

Only `postgres_data` and `redis_data` are backed up, even though `uploads` is also mounted.

#### Backup with a shared timestamp across the group

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume redis_data:/volumes/redis_data \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb backup -a -c -T 20250411_120000
```

Or via environment variable:

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume redis_data:/volumes/redis_data \
  --volume ./backups:/backups \
  --env BACKUP_TIMESTAMP=20250411_120000 \
  ghcr.io/vansergen/vb backup -a -c
```

A shared timestamp lets you restore the entire group in one command later:

```bash
docker run --rm ... ghcr.io/vansergen/vb restore -a -T 20250411_120000 -C
```

#### Parallel backup of all volumes

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume redis_data:/volumes/redis_data \
  --volume uploads:/volumes/uploads \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb backup -a -c -j 3
```

Runs up to 3 backups concurrently.

---

## restore script

### Modes

| Mode                      | Command                                           |
| ------------------------- | ------------------------------------------------- |
| Single volume             | `restore -i <file\|s3://...> -t <name> [options]` |
| All volumes               | `restore -a [options]`                            |
| Selected volumes from all | `restore -a -v <name> [-v <name> ...] [options]`  |
| Recovery only             | `restore -X`                                      |

> **Note:** The `-a` mode only works with local files in `BACKUP_ROOT`. To restore from S3, use single mode with `-i s3://...`.
>
> Without `-v`, `-a` restores the latest backup of every **mounted** volume and skips backups of volumes that are not mounted, with a warning. With `-v`, every requested volume must be mounted and have a backup.

### Options

| Option        | Description                                                             |
| ------------- | ----------------------------------------------------------------------- |
| `-i <source>` | Source: filename in `BACKUP_ROOT`, a file path, or `s3://bucket/key`    |
| `-t <name>`   | Target volume name (directory in `/volumes`)                            |
| `-a`          | Restore all volumes from files in `BACKUP_ROOT`                         |
| `-d <dir>`    | Backup directory override (default: `/backups`)                         |
| `-T <ts>`     | In `-a` mode: restore only backups with this exact timestamp            |
| `-v <name>`   | In `-a` mode: filter by volume name (repeatable)                        |
| `-j <N>`      | Parallel jobs in `-a` mode (`1`–`99`, default: `1`)                     |
| `-C`          | Replace the existing contents of the target volume                      |
| `-U`          | Allow restoring an archive without a `.sha256` checksum file            |
| `-X`          | Only complete or roll back interrupted restores, then exit              |
| `-s`          | Symmetric GPG decryption (passphrase)                                   |
| `-k <file>`   | Private key file for asymmetric GPG decryption (default: `private.gpg`) |
| `-n`          | Dry run: validate and print what would be done without restoring        |
| `-h`          | Show help                                                               |

> **Note on `-C`:** Without `-C`, restore will fail if the target volume is not empty. This protects against accidental data loss. With `-C`, the existing contents are replaced as described in [Transactional restore](#transactional-restore): a failure or interruption at any point leaves either the original or the restored data, never a mix.

### Specifying the source (`-i`)

```bash
# Filename only — looked up inside BACKUP_ROOT (/backups)
restore -i postgres_data_20250411_120000.tar.gz -t postgres_data

# Absolute path
restore -i /mnt/nas/postgres_data_20250411_120000.tar.gz -t postgres_data

# S3
restore -i s3://my-bucket/daily/postgres_data_20250411_120000.tar.gz -t postgres_data
```

### Examples

#### Simple restore of a single volume

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb restore -i postgres_data_20250411_120000.tar -t postgres_data -C
```

#### Restore from a compressed archive

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb restore -i postgres_data_20250411_120000.tar.gz -t postgres_data -C
```

The format (`.gz`) is detected automatically from the file extension.

#### Restore all volumes (latest available backup per volume)

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume redis_data:/volumes/redis_data \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb restore -a -C
```

The **latest** backup found for each volume is selected. If backups were created at different times, a warning about possible inconsistency will appear in the logs.

#### Restore all volumes at a specific timestamp

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume redis_data:/volumes/redis_data \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb restore -a -T 20250411_120000 -C
```

Only backups with exactly this timestamp are restored. Volumes with no matching backup at that timestamp are silently skipped. If you explicitly filter with `-v` and a backup is missing for that volume, the command will fail.

#### Restore only selected volumes

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume redis_data:/volumes/redis_data \
  --volume uploads:/volumes/uploads \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb restore -a -v postgres_data -v redis_data -T 20250411_120000 -C
```

#### Parallel restore of all volumes

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume redis_data:/volumes/redis_data \
  --volume uploads:/volumes/uploads \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb restore -a -j 3 -T 20250411_120000 -C
```

---

## Environment Variables

### General

| Variable       | Default    | Description                                    |
| -------------- | ---------- | ---------------------------------------------- |
| `BACKUP_ROOT`  | `/backups` | Directory for backup files                     |
| `VOLUMES_ROOT` | `/volumes` | Directory with mounted volumes                 |
| `GPG_ROOT`     | `/gpg`     | Directory with GPG key files                   |
| `NO_COLOR`     | —          | Set to any value to disable colored log output |

### For backup

| Variable           | Description                                               |
| ------------------ | --------------------------------------------------------- |
| `BACKUP_TIMESTAMP` | Override the backup timestamp (format: `YYYYMMDD_HHMMSS`) |
| `GPG_PUBLIC_KEY`   | Public key content for asymmetric encryption              |
| `GPG_PASSPHRASE`   | Passphrase for symmetric encryption                       |

### For restore

| Variable          | Description                                                               |
| ----------------- | ------------------------------------------------------------------------- |
| `GPG_PRIVATE_KEY` | Private key content for asymmetric decryption                             |
| `GPG_PASSPHRASE`  | Passphrase for symmetric decryption or a passphrase-protected private key |

### AWS / S3

| Variable                        | Default | Description                                                                                                        |
| ------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------ |
| `AWS_ACCESS_KEY_ID`             | —       | S3 access key                                                                                                      |
| `AWS_SECRET_ACCESS_KEY`         | —       | S3 secret key                                                                                                      |
| `AWS_SESSION_TOKEN`             | —       | Session token for temporary IAM credentials                                                                        |
| `AWS_REGION`                    | —       | S3 region. On AWS it is detected from the bucket when unset; for custom endpoints the default is `us-east-1`       |
| `AWS_DEFAULT_REGION`            | —       | Fallback for `AWS_REGION`                                                                                          |
| `AWS_ENDPOINT_URL`              | —       | Custom S3-compatible endpoint as `scheme://host[:port]` (Yandex Cloud, MinIO, DO Spaces, etc.)                     |
| `S3_ADDRESSING_STYLE`           | `auto`  | `path`, `virtual`, or `auto` (virtual-hosted on AWS unless the bucket name contains dots, path style elsewhere)    |
| `S3_PART_SIZE`                  | `64`    | Multipart part size in MiB (`5`–`5120`). A stream may have at most 10000 parts, so the default allows ~625 GiB     |
| `S3_ALLOW_UNCONDITIONAL_WRITES` | —       | Set to `1` to publish on providers without conditional writes; this gives up protection against concurrent writers |

---

## Backup File Formats

| Extension     | Compression | Encryption |
| ------------- | ----------- | ---------- |
| `.tar`        | none        | none       |
| `.tar.gz`     | gzip        | none       |
| `.tar.gpg`    | none        | GPG        |
| `.tar.gz.gpg` | gzip        | GPG        |

The format during backup is determined by the `-c`, `-e`, `-s` flags.  
During restore, the format is detected automatically from the file extension.

---

## Examples: Compression and Encryption

### Compression only

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb backup -v postgres_data -c
```

Result: `postgres_data_20250411_120000.tar.gz`

### Symmetric encryption (passphrase)

The simplest option: one passphrase for both encryption and decryption.

**Backup:**

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume ./backups:/backups \
  --env GPG_PASSPHRASE=my-secret-password \
  ghcr.io/vansergen/vb backup -v postgres_data -c -s
```

Result: `postgres_data_20250411_120000.tar.gz.gpg`

**Restore:**

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume ./backups:/backups \
  --env GPG_PASSPHRASE=my-secret-password \
  ghcr.io/vansergen/vb restore -i postgres_data_20250411_120000.tar.gz.gpg -t postgres_data -s -C
```

### Asymmetric encryption (public/private key pair)

Best for separating roles: backups are created with the public key; only the private key owner can decrypt.

#### Using key files

**Backup** — only the public key is needed:

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume ./backups:/backups \
  --volume ./gpg:/gpg \
  ghcr.io/vansergen/vb backup -v postgres_data -c -e -k public.asc
```

`./gpg/public.asc` must contain the GPG public key.

**Restore** — private key is required:

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume ./backups:/backups \
  --volume ./gpg:/gpg \
  ghcr.io/vansergen/vb restore \
    -i postgres_data_20250411_120000.tar.gz.gpg \
    -t postgres_data \
    -k private.asc \
    -C
```

If the private key is passphrase-protected:

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume ./backups:/backups \
  --volume ./gpg:/gpg \
  --env GPG_PASSPHRASE=key-passphrase \
  ghcr.io/vansergen/vb restore \
    -i postgres_data_20250411_120000.tar.gz.gpg \
    -t postgres_data \
    -k private.asc \
    -C
```

#### Using environment variables

Convenient for CI/CD pipelines.

**Backup:**

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume ./backups:/backups \
  --env GPG_PUBLIC_KEY="$(cat ./gpg/public.asc)" \
  ghcr.io/vansergen/vb backup -v postgres_data -c -e
```

**Restore:**

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume ./backups:/backups \
  --env GPG_PRIVATE_KEY="$(cat ./gpg/private.asc)" \
  --env GPG_PASSPHRASE=key-passphrase \
  ghcr.io/vansergen/vb restore \
    -i postgres_data_20250411_120000.tar.gz.gpg \
    -t postgres_data \
    -C
```

---

## Examples: S3

S3 uploads and downloads are done with `curl` and AWS Signature Version 4 — no extra S3 client is bundled.
This works with AWS S3, Yandex Cloud Object Storage, MinIO, DigitalOcean Spaces, and other S3-compatible endpoints.

### How uploads work

- The backup stream is uploaded as a **multipart upload** in parts of `S3_PART_SIZE` MiB (default 64), so the size never has to be known in advance. Each part is buffered in a temporary file, so `TMPDIR` needs `S3_PART_SIZE` of free space per running backup.
- The object only becomes visible once every stage (tar, compression, encryption, upload) has succeeded. If anything fails, the upload is aborted and nothing is published.
- Objects are published with `If-None-Match: *`, so an existing recovery point is **never overwritten**, even by a concurrent backup with the same timestamp. A provider that rejects conditional writes (`501 Not Implemented`) makes the backup fail; set `S3_ALLOW_UNCONDITIONAL_WRITES=1` only if you accept losing that protection.
- The `.sha256` sidecar is published last and carries the same token (`x-amz-meta-vb-token`) as the archive. An archive without its sidecar counts as incomplete.
- Credentials are written to a private curl configuration file and never appear on a command line.

### Required permissions

`s3:PutObject`, `s3:GetObject`, `s3:ListBucket`, and `s3:AbortMultipartUpload` on the bucket (or prefix). Without `s3:ListBucket`, S3 answers `403` instead of `404` for missing keys, and the backup refuses to continue.

### Recommended bucket settings

- A lifecycle rule **AbortIncompleteMultipartUpload** (for example after 1 day) cleans up parts left behind by a killed container.
- Object versioning, and ideally object lock, keep previous recovery points even if credentials leak.

### Back up to AWS S3

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --env AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
  --env AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \
  --env AWS_REGION=eu-central-1 \
  ghcr.io/vansergen/vb backup -v postgres_data -c -b my-bucket -f daily/app1
```

The object will be stored at:  
`https://s3.eu-central-1.amazonaws.com/my-bucket/daily/app1/postgres_data_20250411_120000.tar.gz`

### Back up to Yandex Cloud Object Storage

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --env AWS_ACCESS_KEY_ID=<KEY_ID> \
  --env AWS_SECRET_ACCESS_KEY=<SECRET_KEY> \
  --env AWS_REGION=ru-central1 \
  --env AWS_ENDPOINT_URL=https://storage.yandexcloud.net \
  ghcr.io/vansergen/vb backup -v postgres_data -c -b my-bucket -f daily/prod
```

### Back up to MinIO

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --env AWS_ACCESS_KEY_ID=minioadmin \
  --env AWS_SECRET_ACCESS_KEY=minioadmin \
  --env AWS_REGION=us-east-1 \
  --env AWS_ENDPOINT_URL=http://minio:9000 \
  ghcr.io/vansergen/vb backup -v postgres_data -c -b my-bucket
```

### Back up to S3 with encryption

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --env AWS_ACCESS_KEY_ID=<KEY_ID> \
  --env AWS_SECRET_ACCESS_KEY=<SECRET_KEY> \
  --env AWS_REGION=eu-central-1 \
  --env GPG_PASSPHRASE=my-secret \
  ghcr.io/vansergen/vb backup -v postgres_data -c -s -b my-bucket -f daily/app1
```

### Restore from S3

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --env AWS_ACCESS_KEY_ID=<KEY_ID> \
  --env AWS_SECRET_ACCESS_KEY=<SECRET_KEY> \
  --env AWS_REGION=eu-central-1 \
  ghcr.io/vansergen/vb restore \
    -i s3://my-bucket/daily/app1/postgres_data_20250411_120000.tar.gz \
    -t postgres_data \
    -C
```

### Restore an encrypted archive from S3

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --env AWS_ACCESS_KEY_ID=<KEY_ID> \
  --env AWS_SECRET_ACCESS_KEY=<SECRET_KEY> \
  --env AWS_REGION=eu-central-1 \
  --env GPG_PASSPHRASE=my-secret \
  ghcr.io/vansergen/vb restore \
    -i s3://my-bucket/daily/app1/postgres_data_20250411_120000.tar.gz.gpg \
    -t postgres_data \
    -s \
    -C
```

---

## Examples: All Volumes

### Full backup of all volumes with a shared timestamp

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume redis_data:/volumes/redis_data \
  --volume uploads:/volumes/uploads \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb backup -a -c -T 20250411_120000
```

Files created in `./backups`:

```
postgres_data_20250411_120000.tar.gz
postgres_data_20250411_120000.tar.gz.sha256
redis_data_20250411_120000.tar.gz
redis_data_20250411_120000.tar.gz.sha256
uploads_20250411_120000.tar.gz
uploads_20250411_120000.tar.gz.sha256
```

### Restore the entire snapshot by timestamp

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume redis_data:/volumes/redis_data \
  --volume uploads:/volumes/uploads \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb restore -a -T 20250411_120000 -C
```

### Back up all volumes to S3 with encryption

```bash
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume redis_data:/volumes/redis_data \
  --volume uploads:/volumes/uploads \
  --env AWS_ACCESS_KEY_ID=<KEY_ID> \
  --env AWS_SECRET_ACCESS_KEY=<SECRET_KEY> \
  --env AWS_REGION=eu-central-1 \
  --env GPG_PASSPHRASE=my-secret \
  ghcr.io/vansergen/vb backup -a -c -s -b my-bucket -f daily/prod -j 2
```

---

## Backing up every Docker volume on the host

The `-a` mode backs up everything mounted under `/volumes`, but the container only sees what you mount in. The patterns below build the mount list dynamically from `docker volume ls`.

### One-liner

```bash
docker run --rm \
  $(docker volume ls -q | sed 's|.*|--volume &:/volumes/&|') \
  --volume "$(pwd)/backups:/backups" \
  ghcr.io/vansergen/vb backup -a -c
```

`docker volume ls -q` lists every named volume on the host; `sed` expands each name into a `--volume <name>:/volumes/<name>` pair.

### Safer wrapper script

Better suited for cron and scripts: skips anonymous volumes (64-char hex names), handles names with special characters, and accepts a shared timestamp for atomic per-snapshot restore.

```bash
#!/usr/bin/env bash
set -euo pipefail

mounts=()
while IFS= read -r vol; do
  # skip anonymous volumes (Docker autogenerates 64-char hex names)
  [[ "$vol" =~ ^[a-f0-9]{64}$ ]] && continue
  mounts+=(--volume "$vol:/volumes/$vol")
done < <(docker volume ls -q)

docker run --rm \
  "${mounts[@]}" \
  --volume "$(pwd)/backups:/backups" \
  ghcr.io/vansergen/vb backup -a -c -j 2 -T "$(date -u +%Y%m%d_%H%M%S)"
```

Use Docker labels to opt volumes in explicitly — recommended for production so the script never picks up volumes you didn't intend to back up:

```bash
docker volume ls -q --filter label=backup=true
```

```yaml
# in your application's compose.yaml
volumes:
  postgres_data:
    labels:
      backup: "true"
```

### Docker Compose

Declare a one-shot `backup` service alongside your application and reuse the same named volumes. The `profiles: [backup]` line keeps the service out of regular `docker compose up`.

```yaml
services:
  postgres:
    image: postgres:17
    volumes:
      - postgres_data:/var/lib/postgresql/data

  redis:
    image: redis:7
    volumes:
      - redis_data:/data

  backup:
    image: ghcr.io/vansergen/vb
    profiles: [backup]
    command: backup -a -c -s -j 2
    environment:
      GPG_PASSPHRASE: ${GPG_PASSPHRASE}
    volumes:
      - postgres_data:/volumes/postgres_data
      - redis_data:/volumes/redis_data
      - ./backups:/backups

volumes:
  postgres_data:
  redis_data:
```

Run it on demand:

```bash
GPG_PASSPHRASE=secret docker compose run --rm backup
```

To restore the same snapshot, replace `command:` with `restore -a -T <timestamp> -C` (or run a sibling `restore` service the same way).

---

## Dry Run

Dry run validates parameters and prints what would be done, without creating files or modifying volumes.

```bash
# Check a single volume backup
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb backup -v postgres_data -c -n

# Check all volumes backup
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume redis_data:/volumes/redis_data \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb backup -a -c -n

# Check a single volume restore
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb restore -i postgres_data_20250411_120000.tar.gz -t postgres_data -n

# Check all volumes restore
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume redis_data:/volumes/redis_data \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb restore -a -T 20250411_120000 -n
```

---

## Automation with cron

### Daily backup script

Create a `run-backup.sh` wrapper:

```bash
#!/usr/bin/env bash
set -euo pipefail

docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume redis_data:/volumes/redis_data \
  --volume /opt/backups:/backups \
  --env AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
  --env AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
  --env AWS_REGION=eu-central-1 \
  --env GPG_PASSPHRASE="${GPG_PASSPHRASE}" \
  ghcr.io/vansergen/vb backup -a -c -s -b my-bucket -f "daily/$(hostname)"
```

Add to `crontab -e`:

```cron
0 3 * * * /opt/scripts/run-backup.sh >> /var/log/docker-volume-backup.log 2>&1
```

### Local-only daily backup

```cron
0 3 * * * docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume /opt/backups:/backups \
  ghcr.io/vansergen/vb backup -v postgres_data -c \
  >> /var/log/docker-volume-backup.log 2>&1
```

---

## Production Recommendations

### Supported platforms

The published image supports `linux/amd64`, `linux/arm64/v8`, and `linux/ppc64le`. 32-bit ARM platforms (`linux/arm/v6`, `linux/arm/v7`, e.g. Raspberry Pi Zero / 1 / 2 / 3 running a 32-bit OS) are no longer published, because the MinIO client (`mc`) bundled in the image no longer ships 32-bit ARM builds. Use a 64-bit OS on supported ARM boards.

### Stop stateful services before restore

Before restoring data for databases or other stateful services, stop their containers first:

```bash
docker stop my-postgres
docker run --rm \
  --volume postgres_data:/volumes/postgres_data \
  --volume ./backups:/backups \
  ghcr.io/vansergen/vb restore -i postgres_data_20250411_120000.tar.gz -t postgres_data -C
docker start my-postgres
```

### Prefer app-aware dumps for databases

File-level volume backups work well for static files, uploads, and general state directories.  
For PostgreSQL, MySQL, MongoDB, and Redis, logical dumps (`pg_dump`, `mysqldump`, `mongodump`) are more reliable — they produce a consistent snapshot without stopping the service.

### Use a shared timestamp for grouped backups

When you need to restore several volumes as a coherent set, ensure they are all backed up with the same timestamp:

```bash
docker run --rm ... ghcr.io/vansergen/vb backup -a -c -T 20250411_120000
```

This guarantees that restore picks exactly those files:

```bash
docker run --rm ... ghcr.io/vansergen/vb restore -a -T 20250411_120000 -C
```

### Encrypt sensitive data

If your volumes contain personal data, credentials, tokens, or business-critical data, use `-s` (symmetric GPG) or `-e` (asymmetric GPG).

### Test your restores periodically

Having a backup file does not guarantee a successful restore. Periodically restore to a separate test volume and verify that the application starts correctly.

### Do not rely on a single local copy

A good strategy: keep a local copy **and** an offsite copy in S3 or another object storage.

### Be careful with parallelism (`-j`)

High `-j` with compression can saturate CPU, disk, and network simultaneously. Start with `-j 1` and increase gradually.

### Protect recovery points with bucket-side versioning

Before uploading, the backup script checks that neither the archive nor its sidecar exists (any answer other than a confirmed `404` is fatal), and it publishes with conditional writes, so a same-key upload cannot replace an existing recovery point. Still, enable bucket-side **object versioning** (and ideally retention / object lock): it protects recovery points against deletion with leaked credentials and against providers that silently ignore conditional writes. AWS S3, Yandex Cloud Object Storage, MinIO, and most S3-compatible stores expose this as a bucket-level setting.

---

## Troubleshooting

### `Volume 'xxx' is not mounted into /volumes`

The volume is not mounted into the container. Add `--volume <vol-name>:/volumes/<vol-name>` to your `docker run` command.

### `Invalid volume name` / `does not resolve to a directory directly inside /volumes`

The name passed to `-v` or `-t` must start with a letter or digit and contain only letters, digits, `.`, `_`, and `-` — names such as `.` or `..` are rejected. The volume must also be a real directory directly inside `/volumes`, not a symlink to another location.

### `Skipping backup with unsafe volume name`

In `restore -a` mode, files in `BACKUP_ROOT` whose names do not map to a valid volume name (for example macOS `._*` AppleDouble files on a NAS share) are ignored.

### `Backup file already exists`

A file with that name already exists in `BACKUP_ROOT`. Use a different timestamp (`-T`) or remove the existing file.

### `A checksum file without its archive already exists`

A `.sha256` file with the name of the new backup exists, but its archive does not (for example, left behind by version 1 or created by hand). The backup refuses to publish next to it, so that a checksum is never attributed to the wrong archive. Inspect and remove it, or use another timestamp.

### `Target volume is not empty`

The target volume already contains data. Add `-C` to clear it before restoring.

### `Access denied while checking s3://…` / `Failed to check s3://…`

The existence check before an upload got an answer other than `200`/`404`. Check `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, and `AWS_ENDPOINT_URL` (if using a custom store), make sure the endpoint is reachable from inside the container, and grant `s3:ListBucket` (without it S3 answers `403` for missing keys).

### `The S3 provider does not support conditional writes`

The provider answered `501` to `If-None-Match: *`. Nothing was published. If you accept that a concurrent backup with the same timestamp could overwrite this one, set `S3_ALLOW_UNCONDITIONAL_WRITES=1`.

### `Publication incomplete`

The archive was uploaded, but another object already occupied its `.sha256` name. The archive is kept, but counts as incomplete: restore refuses it unless its checksum matches. Inspect both objects before reusing the timestamp.

### `GPG_PASSPHRASE environment variable is not set`

You are using `-s` (symmetric encryption/decryption) but did not provide the passphrase. Add `--env GPG_PASSPHRASE=<passphrase>`.

### `Private key file not found`

For asymmetric decryption, the script looks for a private key at `/gpg/private.gpg` by default. Either mount `--volume ./gpg:/gpg` with the key file present, specify the path with `-k`, or pass the key content via `GPG_PRIVATE_KEY`.

### `No backup files found in /backups`

The directory is empty or the files do not match the expected naming pattern:  
`<VOLUME>_<YYYYMMDD_HHMMSS>.tar[.gz][.gpg]`

### `No backup found for requested volume`

In `restore -a -v <name>` mode, the specified volume has no matching backup file in `BACKUP_ROOT`. Check the available files and the volume name.

### `Selected backups span multiple timestamps`

This is a warning, not an error: backups for different volumes have different timestamps. For a consistent set, use `-T <timestamp>` to pin all volumes to the same snapshot.

### GPG errors inside the container

The scripts create a temporary `GNUPGHOME` with correct permissions automatically. If GPG still fails, pull the latest image: `docker pull ghcr.io/vansergen/vb`.

### `Checksum file not found`

The archive has no `.sha256` file next to it, so it may be incomplete (for example, a backup that was interrupted while it was published). If you trust the archive, restore it with `-U`.

### `Another backup or restore is using …`

Another backup or restore holds the lock on that volume. Wait until it finishes. A stale lock cannot remain: it is released when the process that holds it exits.

### `Unable to lock … the filesystem may not support locking`

The directory that holds the volume does not support `flock` (some NFS mounts). Backups and restores refuse to run without it.

### `holds reserved entries` / `Reserved name in use`

The volume contains a top-level entry whose name starts with `.vb-restore` (or `.restore-in-progress.`, used by version 1):

- If a restore was interrupted, run `restore -X` to complete or roll it back.
- If the tool cannot identify the entry as its own, it never deletes it. Inspect it and move it out of the volume (a `.restore-in-progress.*` directory may hold the only copy of data from an interrupted version 1 restore).

### `takes part in an unfinished restore but is not mounted`

An interrupted `restore -a` involved several volumes, and recovery needs all of them. Mount every listed volume and run `restore -X`.

### `Some files changed while they were archived`

Files changed while the backup read them, so their copies may be inconsistent. The backup is still published. Stop the writing service during the backup, or use `-S` to make this an error.

---

## FAQ

**Can I use bind mounts instead of Docker volumes?**  
Yes. The scripts work with any directory mounted under `VOLUMES_ROOT`. Bind mounts are treated identically to named Docker volumes.

**Do I need to stop containers to take a backup?**  
Not for static files. For actively writing databases (PostgreSQL, MySQL, Redis), it depends on your consistency requirements. A file-level backup of a running database may be file-intact but logically inconsistent.

**Why does `-a` restore only work with local files, not S3?**  
The `-a` mode automatically scans `BACKUP_ROOT` and matches filenames to volume names. S3 does not provide local file scanning. To restore from S3, use single mode with an explicit source: `restore -i s3://...`.

**Symmetric (`-s`) vs. asymmetric (`-e`) encryption — which should I use?**  
Symmetric (`-s`) is simpler: one passphrase, easy to automate.  
Asymmetric (`-e`) is better for role separation: backups can be created with only the public key; only the private key owner can decrypt.

**Can I use Podman instead of Docker?**  
Yes. Replace `docker run` with `podman run` — the syntax is identical.

**What if I need a true crash-consistent snapshot of all volumes?**  
These scripts operate at the file-archive level. For a crash-consistent snapshot, consider:

- Filesystem snapshots (LVM, ZFS, btrfs)
- Storage-level snapshots (cloud disks)
- App-aware backup tools for stateful services (`pg_dump`, etc.)
