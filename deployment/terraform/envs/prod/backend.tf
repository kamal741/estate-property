terraform {
  backend "gcs" {
    # bucket is supplied at init time, e.g. deployment/scripts/deploy-platform.sh:
    #   terraform init -backend-config="bucket=YOUR_BUCKET"
    prefix = "prod"
  }
}
