# Project: MS_PKI

## Overview
MS_PKI is a PowerShell-based automation toolkit for auditing, validating, and safely aligning Microsoft AD CS PKI infrastructure with strict backward compatibility and security-first controls.

## Core Features
- Automated PKI audit for Root and Issuing CA roles with evidence artifacts
- Baseline validation against expected PKI configuration and publication paths
- Controlled alignment workflow with explicit apply mode, backup, and rollback plan generation
- Dedicated rollback execution for selective or full restoration of aligned changes
- Security validation for file paths, URLs, and input data before state-changing operations

## Tech Stack
- **Language:** PowerShell 5.1+
- **Framework:** Native PowerShell scripting/modules
- **Database:** None
- **ORM:** None
- **Integrations:** Microsoft AD CS, IIS, certutil, Windows Server APIs

## Architecture Notes
- Scenario entry scripts are isolated by operational phase (`audit`, `validate`, `align`, `rollback`)
- Shared reusable logic is centralized in `src/lib/*.psm1`
- Change operations are guarded with `ShouldProcess` and safe defaults (`-WhatIf` path first)
- Alignment output artifacts are used as rollback inputs to preserve operational traceability

## Non-Functional Requirements
- Logging: Structured log levels (`Info`, `Warning`, `Error`) via `Logging.psm1`
- Error handling: Fail-fast behavior for top-level scripts with explicit exception handling
- Security: No implicit infrastructure changes without `-Apply`; preserve legacy namespace and CRL availability

## Architecture
See `.ai-factory/ARCHITECTURE.md` for detailed architecture guidelines.
Pattern: Modular Monolith
