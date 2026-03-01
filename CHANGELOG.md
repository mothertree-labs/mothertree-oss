# Changelog

All notable changes to Mothertree will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.8.0] - 2026-03-01

Baseline release — platform release versioning introduced.

### Added
- Platform-level `VERSION` file and release version string (`0.8.0-<commit>[-M]`)
- `/version` endpoint on admin and account portals
- `scripts/lib/release.sh` for deploy-time version computation
