# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Terraform module (Norwegian docs, developed for internal use at `nav/navikt`) that provisions a Google Datastream
pipeline streaming data from a PostgreSQL database on Cloud SQL into BigQuery. There is no build step, package manager,
or test suite; the entire module is five files: `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, and
`cloud-init.yaml.tftpl` (the cloud-init config that starts the Cloud SQL Auth Proxy on the VM).

## Commands

```
terraform init               # download providers/modules
terraform fmt -recursive     # format
terraform validate           # validate syntax/types (needs `terraform init` first)
```

There are no unit tests. Validation of behavior happens by consuming the module from a downstream repo (e.g.
`flex-bigquery-terraform`) by running `terraform plan`.`

## Architecture

The module wires together four GCP resources for one Datastream pipeline per module instantiation:

1. `google_bigquery_dataset.datastream_dataset`: The BigQuery destination dataset.
2. `google_compute_instance.compute_instance`: A GCE VM running the Cloud SQL Auth Proxy in a container. This VM is the
   actual PostgreSQL endpoint the Datastream connects to.
3. `google_datastream_connection_profile.postgresql_connection_profile`: Points at the proxy VM's internal IP on port
    5432.
4. `google_datastream_stream.datastream`: The actual replication stream from the PostgreSQL connection profile to
   BigQuery.

### Naming conventions (in `locals`)

Most resource names derive from `var.application_name`, with overridable defaults via `coalesce()`:

- `datastream_id` = `"${application_name}-datastream"`; `dataset_id` replaces `-` with `_`
- publication/replication slot names default to `"${cloud_sql_instance_name_with_underscores}_publication"` /
  `"..._replication"`
- proxy VM name defaults to `"${application_name}-cloud-sql-auth-proxy"`
- connection profile ID defaults to `"${application_name}-postgresql-connection-profile"`

When changing variable names or defaults, keep `README.md` in sync.

### Resources

Useful references for understanding the usage of this module and the underlying GCP resources:

- The `README.md` The Norwegian usage docs, including the minimal example and default-value tables)in this repo.  
- [navikt/flex-bigquery-terraform](https://github.com/navikt/flex-bigquery-terraform) The main consumer of this module.
- [hashicorp/google](https://registry.terraform.io/providers/hashicorp/google/latest) The official
  Google Cloud provider for Terraform. Note that the version **may** be out of synce with the version uses in
  `navikt/flex-bigquery-terraform`.

Access only when required.