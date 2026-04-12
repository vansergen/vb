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

**Restore:**

- Restore a single volume from a local file or from S3
- Restore all volumes from a backup directory
- Restore only selected volumes
- Filter by a specific timestamp
- Clear a volume before restoring (`-C`)
- Run restores for multiple volumes in parallel

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

For local backups, a `.sha256` checksum file is written alongside each archive.

### Restore

```
local file or S3 → [GPG decryption] → [gzip decompression] → Docker volume
```

The format is detected automatically from the file extension.

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
| `-j <N>`      | Parallel jobs in `-a` mode (default: `1`)                                 |
| `-c`          | Compress with `pigz` if available, otherwise `gzip`                       |
| `-e`          | Asymmetric GPG encryption (public key)                                    |
| `-s`          | Symmetric GPG encryption (passphrase)                                     |
| `-b <bucket>` | Upload to S3 bucket                                                       |
| `-f <path>`   | Folder / prefix inside the S3 bucket                                      |
| `-k <file>`   | Public key file inside `/gpg` (default: `public.gpg`)                     |
| `-n`          | Dry run: validate and print what would be done without creating any files |
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

> **Note:** The `-a` mode only works with local files in `BACKUP_ROOT`. To restore from S3, use single mode with `-i s3://...`.

### Options

| Option        | Description                                                             |
| ------------- | ----------------------------------------------------------------------- |
| `-i <source>` | Source: filename in `BACKUP_ROOT`, a file path, or `s3://bucket/key`    |
| `-t <name>`   | Target volume name (directory in `/volumes`)                            |
| `-a`          | Restore all volumes from files in `BACKUP_ROOT`                         |
| `-d <dir>`    | Backup directory override (default: `/backups`)                         |
| `-T <ts>`     | In `-a` mode: restore only backups with this exact timestamp            |
| `-v <name>`   | In `-a` mode: filter by volume name (repeatable)                        |
| `-j <N>`      | Parallel jobs in `-a` mode (default: `1`)                               |
| `-C`          | Clear the target volume before restoring                                |
| `-s`          | Symmetric GPG decryption (passphrase)                                   |
| `-k <file>`   | Private key file for asymmetric GPG decryption (default: `private.gpg`) |
| `-n`          | Dry run: validate and print what would be done without restoring        |
| `-h`          | Show help                                                               |

> **Note on `-C`:** Without `-C`, restore will fail if the target volume is not empty. This protects against accidental data loss.

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

| Variable                | Default     | Description                                                          |
| ----------------------- | ----------- | -------------------------------------------------------------------- |
| `AWS_ACCESS_KEY_ID`     | —           | S3 access key                                                        |
| `AWS_SECRET_ACCESS_KEY` | —           | S3 secret key                                                        |
| `AWS_SESSION_TOKEN`     | —           | Session token for temporary IAM credentials                          |
| `AWS_REGION`            | `us-east-1` | S3 region                                                            |
| `AWS_ENDPOINT_URL`      | —           | Custom S3-compatible endpoint (MinIO, Yandex Cloud, DO Spaces, etc.) |

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

S3 uploads and downloads use the MinIO client (`mc`).
This works with AWS S3, MinIO, Yandex Cloud Object Storage, DigitalOcean Spaces, and other S3-compatible endpoints.

> **Compatible storage:** AWS S3, Yandex Cloud Object Storage, MinIO, DigitalOcean Spaces, and any S3-compatible endpoint.

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

### S3 uploads use the MinIO client (`mc`)

`mc pipe` handles upload from a stream and uses multipart upload internally when needed. It works with AWS S3, MinIO, Yandex Cloud Object Storage, DigitalOcean Spaces, and other S3-compatible endpoints.

---

## Troubleshooting

### `Volume 'xxx' is not mounted into /volumes`

The volume is not mounted into the container. Add `--volume <vol-name>:/volumes/<vol-name>` to your `docker run` command.

### `Backup file already exists`

A file with that name already exists in `BACKUP_ROOT`. Use a different timestamp (`-T`) or remove the existing file.

### `Target volume is not empty`

The target volume already contains data. Add `-C` to clear it before restoring.

### `Failed to configure S3 client`

The `mc` client could not connect to the S3 endpoint. Check that `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_ENDPOINT_URL` (if using a custom store) are set correctly and that the endpoint is reachable from inside the container.

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
