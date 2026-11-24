# AGENTS.md

This file gives instructions to agents that work with code in this repository.

## Overview

This repository is a Terraform module for internal use in `navikt`. The module
creates a Google Datastream pipeline. The pipeline streams data from a
PostgreSQL database on Cloud SQL into BigQuery. The `README.md` is in Norwegian.

The module has no build step, no package manager and no test suite. It has
five files:

- `main.tf`: Resources and `locals`.
- `variables.tf`: Input variables and default values.
- `outputs.tf`: Outputs.
- `versions.tf`: Terraform and provider version constraints.
- `cloud-init.yaml.tftpl`: The cloud-init config that starts the Cloud SQL Auth
  Proxy on the proxy VM.

## Commands

```sh
terraform init               # Download providers and modules.
terraform fmt -recursive     # Format all files.
terraform validate           # Validate syntax and types. Run `terraform init` first.
```

The module has no unit tests. To test a change, use the module from a consumer
repository (for example `flex-bigquery-terraform`) and run `terraform plan`.

## Architecture

Each module instance creates one Datastream pipeline from four GCP resources:

1. `google_bigquery_dataset.datastream_dataset`: The BigQuery destination
   dataset.
2. `google_compute_instance.compute_instance`: The proxy VM. Datastream connects
   to PostgreSQL through this VM.
3. `google_datastream_connection_profile.postgresql_connection_profile`: The
   connection profile. It points to the internal IP of the proxy VM on port
   5432.
4. `google_datastream_stream.datastream`: The stream. It replicates data from
   the PostgreSQL connection profile to BigQuery.

### Naming conventions

The `locals` block in `main.tf` derives most resource names from
`var.application_name`. Variables can override the defaults through
`coalesce()`.

- `datastream_id` is `"${application_name}-datastream"`.
- `dataset_id` is `datastream_id` with `-` replaced by `_`.
- The publication name defaults to
  `"${cloud_sql_instance_name_with_underscores}_publication"`.
- The replication slot name defaults to
  `"${cloud_sql_instance_name_with_underscores}_replication"`.
- The proxy VM name defaults to `"${application_name}-cloud-sql-auth-proxy"`.
- The connection profile ID defaults to
  `"${application_name}-postgresql-connection-profile"`.

## Rules

- When you change variable names or default values, update `README.md` in the
  same change. Consumers read the defaults there.
- Do not create the database user, the publication or the replication slot in
  this module. The database owner creates them before the module runs.

## References

Read these sources only when the task requires it:

- `README.md`: Norwegian usage documentation, with a minimal example and
  prerequisites.
- [navikt/flex-bigquery-terraform](https://github.com/navikt/flex-bigquery-terraform):
  The main consumer of this module.
- [hashicorp/google](https://registry.terraform.io/providers/hashicorp/google/latest):
  The Google Cloud provider for Terraform. The provider version in this module
  can be different from the version in `flex-bigquery-terraform`.

## Glossary

- **Proxy VM**: The GCE VM that runs the Cloud SQL Auth Proxy in a container.
  It is the PostgreSQL endpoint for Datastream.
- **Publication**: The PostgreSQL publication that lists the tables to stream.
- **Replication slot**: The PostgreSQL logical replication slot (`pgoutput`)
  that Datastream reads changes from.
- **Consumer repository**: A repository that uses this module through a Git
  `source` with a `ref` tag.
