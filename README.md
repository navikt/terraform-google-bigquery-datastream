# terraform-google-bigquery-datastream

Modul for for provisjonering av [Google Datastream](https://cloud.google.com/datastream/docs/overview) for streaming av data fra en PostgreSQL-database eid av en [nais-applikasjon](https://nais.io/).

Modulen er utviklet for bruk internt i Nav, men kan antakelig brukes utenfor med noen endringer. Det er ikke testet på noen som helst måte..

# Forberedelser

Modulen forventer at det finnes en [VPC](https://cloud.google.com/vpc/docs/overview) konfiguret med [IP-range](https://cloud.google.com/vpc/docs/ip-addresses) og [brannveggregler](https://cloud.google.com/firewall/docs/firewalls) sånn at det kan gjøres [VPC Peering](https://cloud.google.com/datastream/docs/create-a-private-connectivity-configuration).

Se [flex-bigquery-terraform/datastream-vpc](https://github.com/navikt/flex-bigquery-terraform/blob/main/prod/datastream-vpc.tf) for eksempel.

Modulen oppretter *ikke* selve databasebrukeren, publikasjonen eller replikeringsslotten i PostgreSQL-databasen — disse må finnes fra før:

- En databasebruker (angitt via `cloud_sql_instance_db_credentials`) med `REPLICATION`-rolle og leserettigheter på tabellene som skal streames.
- En [publikasjon](https://www.postgresql.org/docs/current/sql-createpublication.html) med navnet angitt i `cloud_sql_instance_publication_name` (default: `<cloud_sql_instance_name>_publication`).
- En [replikeringsslot](https://www.postgresql.org/docs/current/logicaldecoding-explanation.html#LOGICALDECODING-REPLICATION-SLOTS) med navnet angitt i `cloud_sql_instance_replication_name` (default: `<cloud_sql_instance_name>_replication`), opprettet med `pgoutput`-pluginet.
- `wal_level` satt til `logical` på Cloud SQL-instansen.

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
- `google_compute_address`
- `google_compute_instance`
- `google_datastream_connection_profile`
- `google_datastream_stream`

### Cloud SQL Auth Proxy

Proxy-VM-en kjører [Container-Optimized OS](https://cloud.google.com/container-optimized-os/docs), og starter Cloud SQL Auth Proxy som en `systemd`-tjeneste via [cloud-init](https://cloud.google.com/container-optimized-os/docs/how-to/run-container-instance) (metadata-nøkkelen `user-data`). Konfigurasjonen ligger i [cloud-init.yaml.tftpl](./cloud-init.yaml.tftpl).

Tidligere ble containeren startet av «container startup agent» (konlet) via metadata-nøkkelen `gce-container-declaration`, konfigurert med modulen `terraform-google-modules/container-vm`. Denne mekanismen er [utfaset av Google](https://cloud.google.com/compute/docs/containers/migrate-containers), og modulen er derfor fjernet.

Container-Optimized OS har en host-brannmur der `INPUT` har policy `DROP`. Den utfasede container startup agenten åpnet all TCP-, UDP- og ICMP-trafikk automatisk, noe som ikke er dokumentert av Google. `systemd`-tjenesten åpner derfor kun porten proxyen lytter på, ved hver oppstart. Uten denne regelen blir pakkene fra Datastream forkastet av VM-en, og valideringen av connection-profilen feiler med `CONNECTION_TIMEOUT`.

### Oppstartsrekkefølge

Terraform anser proxy-VM-en som opprettet når Compute Engine melder `RUNNING`. På det tidspunktet har ikke cloud-init rukket å hente containeren og starte proxyen, noe som tar rundt et minutt. Datastream validerer tilkoblingen synkront når connection-profilen opprettes eller endres, og gir opp etter omtrent 2,5 minutter.

Modulen venter derfor i `cloud_sql_proxy_startup_delay` mellom opprettelsen av VM-en og connection-profilen. Uten denne pausen feiler en andel av kjøringene med `CONNECTION_TIMEOUT` og må kjøres på nytt.

Venting er implementert med [`time_sleep`](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep), og modulen krever derfor provideren `hashicorp/time`.

VM-en får en fast intern IP fra `google_compute_address`. Det gjør at Datastreamens connection-profile ikke må oppdateres hver gang VM-en gjenopprettes, for eksempel ved bytte av maskintype eller OS-image.

### OS-image

Boot-disken peker på imagefamilien `cloud_sql_proxy_vm_image_family` og ikke på et konkret image. Compute Engine velger dermed det nyeste imaget i familien når VM-en opprettes, mens Terraform-planen holder seg uendret mellom kjøringer.

Konsekvensen er at en VM som allerede finnes ikke får nye OS-patcher av seg selv. For å hente inn et nyere image må VM-en gjenopprettes, enten ved å bytte imagefamilie eller ved `terraform apply -replace`:

```
terraform apply -replace='module.<modulnavn>.google_compute_instance.compute_instance'
```

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

Modulen angir følgende standardverdi for `postgresql_exclude_schemas`: `[{ schema = "public", tables = [{ table = "flyway_schema_history" }] }]`.

`postgresql_exclude_schemas ` og ` postgresql_include_schemas` som angis som input til modulen erstatter standardverdier fullt og helt.

### Andre standardverdier

| Variabel                                 | Default                                              | Beskrivelse                                                                                              |
|------------------------------------------|------------------------------------------------------|----------------------------------------------------------------------------------------------------------|
| `datastream_desired_state`               | `RUNNING`                                            | Sett til `PAUSED` for å opprette Datastream uten å starte den.                                           |
| `bigquery_table_freshness`               | `3600s`                                              | Hvor ofte data gjøres tilgjengelig i BigQuery. Kortere tid øker kostnaden.                               |
| `cloud_sql_proxy_vm_machine_type`        | `e2-small`                                           | Maskintype for VM-en som kjører Cloud SQL Auth Proxy.                                                    |
| `cloud_sql_proxy_vm_image_family`        | `cos-129-lts`                                        | Container-Optimized OS-imagefamilien VM-en bruker.                                                       |
| `cloud_sql_proxy_image`                  | `gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.25.0` | Container-imaget for Cloud SQL Auth Proxy.                                                               |
| `cloud_sql_proxy_use_private_ip`         | `false`                                              | Sett til `true` for at proxyen skal koble til Cloud SQL over privat IP i stedet for offentlig IP.        |
| `cloud_sql_proxy_startup_delay`          | `60s`                                                | Ventetid fra proxy-VM-en er opprettet til Datastream validerer tilkoblingen.                             |
| `cloud_sql_proxy_vm_external_ip_enabled` | `true`                                               | Sett til `false` for å fjerne den eksterne IP-en fra VM-en. Krever Private Google Access eller Cloud NAT.|
| `cloud_sql_proxy_logging_enabled`        | `false`                                              | Aktiverer Cloud Logging-agenten på VM-en, slik at proxy-loggene havner i Cloud Logging.                  |
| `cloud_sql_proxy_monitoring_enabled`     | `false`                                              | Aktiverer Cloud Monitoring-agenten på VM-en.                                                             |

### Nettverk uten ekstern IP

Som standard får proxy-VM-en en ekstern IP, fordi proxyen kobler til Cloud SQL-instansen over dens offentlige IP. For å kjøre VM-en uten ekstern IP må VPC-en først settes opp slik at proxyen fortsatt når Cloud SQL Admin API:

1. Slå på [Private Google Access](https://cloud.google.com/vpc/docs/private-google-access) på subnettet (eller sett opp [Cloud NAT](https://cloud.google.com/nat/docs/overview)).
2. Sørg for at Cloud SQL-instansen har privat IP i den samme VPC-en, og sett `cloud_sql_proxy_use_private_ip = true`.
3. Sett `cloud_sql_proxy_vm_external_ip_enabled = false`.

Bruker man en custom mode VPC må subnettets navn angis med nøkkelen `subnetwork_name` i `datastream_vpc_resources`. I en auto mode VPC utledes navnet fra `vpc_name`.