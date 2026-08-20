resource "google_bigquery_dataset" "datastream_dataset" {
  dataset_id                 = local.dataset_id
  location                   = var.gcp_project["region"]
  project                    = var.gcp_project["project"]
  labels                     = {}
  delete_contents_on_destroy = var.big_query_dataset_delete_contents_on_destroy

  dynamic "access" {
    for_each = concat(local.default_access_roles, var.access_roles)
    content {
      role           = access.value.role
      special_group  = try(access.value.special_group, null)
      group_by_email = try(access.value.group_by_email, null)
      user_by_email  = try(access.value.user_by_email, null)
    }
  }

  dynamic "access" {
    for_each = var.authorized_views

    content {
      view {
        dataset_id = access.value.view.dataset_id
        project_id = access.value.view.project_id
        table_id   = access.value.view.table_id
      }
    }
  }

  timeouts {}
}

data "google_sql_database_instance" "database_instance" {
  name = var.cloud_sql_instance_name
}

// I en auto mode VPC har subnettet samme navn som selve VPC-en. For en custom mode VPC må navnet
// angis eksplisitt via nøkkelen `subnetwork_name` i `datastream_vpc_resources`.
data "google_compute_subnetwork" "datastream_subnetwork" {
  name    = coalesce(try(var.datastream_vpc_resources.subnetwork_name, null), var.datastream_vpc_resources.vpc_name)
  project = var.gcp_project["project"]
  region  = var.gcp_project["region"]
}

// Reserverer en fast intern IP for proxy-VM-en. Uten denne får VM-en en ny IP hver gang den
// gjenopprettes, noe som endrer `postgresql_profile.hostname` i connection-profilen og dermed
// tvinger frem en oppdatering av selve Datastreamen.
resource "google_compute_address" "cloud_sql_proxy_internal_ip" {
  name         = "${local.cloud_sql_proxy_vm_name}-ip"
  project      = var.gcp_project["project"]
  region       = var.gcp_project["region"]
  address_type = "INTERNAL"
  subnetwork   = data.google_compute_subnetwork.datastream_subnetwork.id
}

locals {
  cloud_sql_proxy_port = 5432

  // https://github.com/GoogleCloudPlatform/cloud-sql-proxy?tab=readme-ov-file#usage
  cloud_sql_proxy_args = join(" ", compact([
    "--address=0.0.0.0",
    "--port=${local.cloud_sql_proxy_port}",
    // Logger som JSON slik at Cloud Logging får med alvorlighetsgrad og struktur.
    "--structured-logs",
    var.cloud_sql_proxy_use_private_ip ? "--private-ip" : "",
    data.google_sql_database_instance.database_instance.connection_name,
  ]))
}

resource "google_compute_instance" "compute_instance" {
  allow_stopping_for_update = true
  name                      = local.cloud_sql_proxy_vm_name
  machine_type              = var.cloud_sql_proxy_vm_machine_type
  project                   = var.gcp_project["project"]
  zone                      = var.gcp_project["zone"]

  // Container-Optimized OS er bygget for å kjøre containere, og inneholder både Docker og
  // cloud-init. https://cloud.google.com/container-optimized-os/docs/release-notes
  //
  // Det pekes på selve imagefamilien og ikke på et konkret image. Et oppslag med
  // `google_compute_image` ville gitt self_linken til det nyeste imaget i familien, og siden
  // `image` er ForceNew ville VM-en blitt gjenopprettet hver gang Google publiserte et nytt
  // patch-image. Med familie-URL-en velger Compute Engine nyeste image når VM-en faktisk
  // opprettes, uten at planen endrer seg mellom kjøringer.
  boot_disk {
    initialize_params {
      image = "projects/cos-cloud/global/images/family/${var.cloud_sql_proxy_vm_image_family}"
    }
  }

  network_interface {
    network    = var.datastream_vpc_resources.vpc_name
    subnetwork = data.google_compute_subnetwork.datastream_subnetwork.self_link
    network_ip = google_compute_address.cloud_sql_proxy_internal_ip.address

    // Tildeler VM-en en ekstern IP. Dette er kun nødvendig hvis VPC-en mangler Private Google
    // Access eller Cloud NAT, eller hvis proxyen kobler til Cloud SQL over offentlig IP.
    dynamic "access_config" {
      for_each = var.cloud_sql_proxy_vm_external_ip_enabled ? [1] : []
      content {}
    }
  }

  // https://cloud.google.com/compute/docs/access/create-enable-service-accounts-for-instances
  service_account {
    scopes = ["cloud-platform"]
  }

  metadata = {
    // cloud-init erstatter den utfasede metadata-nøkkelen `gce-container-declaration`.
    user-data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
      // https://github.com/GoogleCloudPlatform/cloud-sql-proxy/releases
      image = var.cloud_sql_proxy_image
      args  = local.cloud_sql_proxy_args
      port  = local.cloud_sql_proxy_port
    })
    // https://cloud.google.com/container-optimized-os/docs/how-to/logging
    google-logging-enabled    = tostring(var.cloud_sql_proxy_logging_enabled)
    google-monitoring-enabled = tostring(var.cloud_sql_proxy_monitoring_enabled)
  }
}

// Terraform anser VM-en som opprettet når Compute Engine melder RUNNING. På det tidspunktet har
// ikke cloud-init rukket å hente containeren og starte proxyen, noe som tar rundt et minutt.
// Datastream validerer tilkoblingen synkront når connection-profilen opprettes eller endres, og
// gir opp etter omtrent 2,5 minutter. Uten denne pausen feiler derfor en andel av kjøringene med
// CONNECTION_TIMEOUT, og må kjøres på nytt. Feilen er forbigående, men oppstår oftere når flere
// VM-er opprettes samtidig og konkurrerer om å hente containeren.
//
// `triggers` sørger for at pausen kjøres på nytt hver gang VM-en byttes ut. Uten den ville
// `time_sleep` bare ventet den aller første gangen den ble opprettet.
resource "time_sleep" "wait_for_cloud_sql_proxy" {
  depends_on      = [google_compute_instance.compute_instance]
  create_duration = var.cloud_sql_proxy_startup_delay

  triggers = {
    compute_instance_id = google_compute_instance.compute_instance.id
  }
}

resource "google_datastream_connection_profile" "postgresql_connection_profile" {
  // Hostnavnet leses fra den reserverte IP-en, og ikke fra VM-en. Den implisitte avhengigheten
  // mot VM-en forsvant derfor da den faste IP-en ble innført, og settes her eksplisitt via
  // pausen over. Uten denne kan Terraform opprette connection-profilen før proxy-VM-en finnes.
  depends_on = [time_sleep.wait_for_cloud_sql_proxy]

  location              = var.gcp_project["region"]
  display_name          = local.postgres_connection_profile_id
  connection_profile_id = local.postgres_connection_profile_id
  postgresql_profile {
    hostname = google_compute_address.cloud_sql_proxy_internal_ip.address
    port     = local.cloud_sql_proxy_port
    username = var.cloud_sql_instance_db_credentials["username"]
    password = var.cloud_sql_instance_db_credentials["password"]
    database = var.cloud_sql_instance_db_name
  }

  private_connectivity {
    private_connection = var.datastream_vpc_resources.private_connection_id
  }

  lifecycle {
    ignore_changes = [create_without_validation]
  }
}

resource "google_datastream_stream" "datastream" {
  stream_id     = local.datastream_id
  display_name  = local.datastream_id
  desired_state = var.datastream_desired_state
  project       = var.gcp_project["project"]
  location      = var.gcp_project["region"]
  backfill_all {}
  timeouts {}

  source_config {
    source_connection_profile = google_datastream_connection_profile.postgresql_connection_profile.id

    postgresql_source_config {
      max_concurrent_backfill_tasks = 0
      publication                   = local.cloud_sql_instance_publication_name
      replication_slot              = local.cloud_sql_instance_replication_name

      exclude_objects {

        dynamic "postgresql_schemas" {
          for_each = var.postgresql_exclude_schemas
          content {
            schema = postgresql_schemas.value.schema

            dynamic "postgresql_tables" {
              for_each = coalesce(postgresql_schemas.value.tables, [])
              content {
                table = postgresql_tables.value.table

                dynamic "postgresql_columns" {
                  for_each = coalesce(postgresql_tables.value.columns, [])
                  content {
                    column = postgresql_columns.value
                  }
                }
              }
            }
          }
        }
      }

      include_objects {

        dynamic "postgresql_schemas" {
          for_each = var.postgresql_include_schemas
          content {
            schema = postgresql_schemas.value.schema

            dynamic "postgresql_tables" {
              for_each = coalesce(postgresql_schemas.value.tables, [])
              content {
                table = postgresql_tables.value.table

                dynamic "postgresql_columns" {
                  for_each = coalesce(postgresql_tables.value.columns, [])
                  content {
                    column = postgresql_columns.value
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  destination_config {
    destination_connection_profile = var.datastream_vpc_resources.bigquery_connection_profile_id

    bigquery_destination_config {
      data_freshness = var.bigquery_table_freshness

      single_target_dataset {
        dataset_id = "${var.gcp_project["project"]}:${google_bigquery_dataset.datastream_dataset.dataset_id}"
      }
    }
  }

  lifecycle {
    ignore_changes = [create_without_validation]
  }
}