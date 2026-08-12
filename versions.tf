terraform {
  required_providers {
    // Brukes av `time_sleep` i main.tf, som gir Cloud SQL Auth Proxy tid til å starte før
    // Datastream validerer tilkoblingen.
    // https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
}

// Merk: `google` er bevisst ikke deklarert her. Provideren arves fra prosjektet som bruker
// modulen, slik at modulen ikke låser hvilken versjon av `hashicorp/google` som kan brukes.
