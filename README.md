# terraform-google-bigquery-datastream

Modul for for provisjonering av [Google Datastream](https://cloud.google.com/datastream/docs/overview) for streaming av data fra en PostgreSQL-database eid av en [nais-applikasjon](https://nais.io/).

Modulen er utviklet for bruk internt i Nav, men kan antakelig brukes utenfor med noen endringe, men det er ikke testet på noen som helst måte.

# Forberedelser

Modulen forventer at det finnes en [VPC](https://cloud.google.com/vpc/docs/overview) konfiguret med [IP-range](https://cloud.google.com/vpc/docs/ip-addresses) og [brannveggregler](https://cloud.google.com/firewall/docs/firewalls) sånn at det kan gjøres [VPC Peering](https://cloud.google.com/datastream/docs/create-a-private-connectivity-configuration).

Se [flex-bigquery-terraform/datastream-vpc](https://github.com/navikt/flex-bigquery-terraform/blob/main/prod/datastream-vpc.tf) for eksempel.

## Bruk

Modulen er ikke lagt til i [Terraform registry](https://registry.terraform.io/), men kan brukes direkte fra GitHub. Tags angir versjon:

```tf
module "module_name" {
  source = "git::https://github.com/navikt/terraform-google-bigquery-datastream.git?ref=v1.0.0"
}
```
Minimalt eksempel:

```tf
module "spinnsyn_datastream" {
  source                            = "git::https://github.com/navikt/terraform-google-bigquery-datastream.git?ref=v1.0.0"
  gcp_project                       = var.gcp_project
  application_name                  = "spinnsyn"
  cloud_sql_instance_name           = "spinnsyn-backend"
  cloud_sql_instance_db_name        = "spinnsyn-db"
  cloud_sql_instance_db_credentials = local.spinnsyn_datastream_credentials
  datastream_vpc_resources          = local.datastream_vpc_resources
}
```

Se [variables.tf](./variables.tf) for en oversikt over alle input-variabler og standardverdier.

## Eksempler

For komplette eksempler, inkludert hvordan modulen støtter konfigurering av tilgangskontroll og filtrering av tabeller se [flex-bigquery-terraform](https://github.com/navikt/flex-bigquery-terraform/blob/main/prod/datastreams.tf) eller [amt-bigquery-terraform/](https://github.com/navikt/amt-bigquery-terraform/blob/main/prod/datastreams.tf).

## Resultat

Når en Datastream er ferdig provisjonert er følgende GCP-ressurser provisjonert:

- `google_bigquery_dataset`
- `google_compute_instance`
- `google_datastream_connection_profile`
- `google_datastream_stream`

## Teardown

Hvis man fjerner modulen vil Terraform forsøke å fjerne ressursene modulen har opprettet. Det vil i utgangspunktet feile siden BigQuery-tabeller ikke kan slettes uten at variablen `big_query_dataset_delete_contents_on_destroy` settes til `true`.

## Standardverdier

Modulen er konfigurert med følgende standardverdier:

### Tilgangskontroll

Følgende verdier settes på [datasettet](https://cloud.google.com/bigquery/docs/datasets-intro) som opprettes:

```tf
 default_access_roles = [
    {
      role          = "OWNER"
      special_group = "projectOwners"
    },
    {
      role          = "READER"
      special_group = "projectReaders"
    },
    {
      role          = "WRITER"
      special_group = "projectWriters"
    },
  ]
  ```

Tilgangskontrollverdiene slås sammen med det som måtte legges til ved bruk av modulen: `concat(local.default_access_roles, var.access_roles)`.

### Tabellfiltrering

En Datastreamn kan konfigurerers med ekskludering og/eller inkludering av av `schema`, `tabell` eller `kolonne`.

Modulen angir følgende standardverdi for `exclude_objects`: `default = [{ schema = "public", tables = [{ table = "flyway_schema_history" }] }]`.

`exclude_objects` og `include_objects` som angis som input til moduelen erstatter standardverdier fullt og helt.
