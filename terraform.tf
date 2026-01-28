terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "linode" {
  token = var.linode_token
}

# Variables
variable "linode_token" {
  description = "Linode API Token"
  type        = string
  sensitive   = true
}

variable "cluster_label" {
  description = "Label for the LKE cluster"
  type        = string
  default     = "springboot-cluster"
}

variable "region" {
  description = "Linode region"
  type        = string
  default     = "gb-lon" # Change as needed: us-west, eu-west, ap-south, etc.
}

variable "k8s_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.34" # Update to desired version
}

variable "node_type" {
  description = "Linode node type"
  type        = string
  default     = "g6-standard-2" # 2 CPU, 4GB RAM
}

variable "node_count" {
  description = "Number of nodes in the pool"
  type        = number
  default     = 3
}

variable "spring_boot_image" {
  description = "Docker image for Spring Boot application"
  type        = string
  default     = "cmilsted/spring-boot-app:latest"
}

variable "app_name" {
  description = "Name of the Spring Boot application"
  type        = string
  default     = "springboot-app"
}

# Create LKE Cluster
resource "linode_lke_cluster" "main" {
  label       = var.cluster_label
  k8s_version = var.k8s_version
  region      = var.region

  pool {
    type  = var.node_type
    count = var.node_count
  }

  tags = ["terraform", "springboot"]
}


resource "local_file" "kube-config" {
  depends_on = [linode_lke_cluster.main]
  filename   = "kube-config"
  content    = base64decode(linode_lke_cluster.main.kubeconfig)
}

#NOPE you need to forget this resource so it exists when running terrafrm destroy
# Run the following command `terraform state rm local_file.kube-config`

# Configure Kubernetes provider with LKE cluster credentials
provider "kubernetes" {
  host                   = linode_lke_cluster.main.api_endpoints[0]
  config_path = "./kube-config"
}

# This resource will destroy (potentially immediately) after null_resource.next
resource "null_resource" "previous" {}

resource "time_sleep" "wait_30_seconds" {
  depends_on = [null_resource.previous]

  create_duration = "30s"
}

# This resource will create (at least) 30 seconds after null_resource.previous
resource "null_resource" "next" {
  depends_on = [time_sleep.wait_30_seconds]
}

# Create namespace for Spring Boot app
resource "kubernetes_namespace" "springboot" {
  metadata {
    name = "springboot"
  }

  depends_on = [linode_lke_cluster.main]
}

# Create deployment for Spring Boot application
resource "kubernetes_deployment" "springboot_app" {
  metadata {
    name      = var.app_name
    namespace = kubernetes_namespace.springboot.metadata[0].name
    labels = {
      app = var.app_name
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = var.app_name
      }
    }

    template {
      metadata {
        labels = {
          app = var.app_name
        }
      }

      spec {
        container {
          name  = var.app_name
          image = var.spring_boot_image

          port {
            container_port = 8080
            name           = "http"
          }

          resources {
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
            requests = {
              cpu    = "250m"
              memory = "256Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/actuator/health"
              port = 8080
            }
            initial_delay_seconds = 60
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path = "/actuator/health"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 5
          }
        }
      }
    }
  }

  depends_on = [kubernetes_namespace.springboot]
}

# Create service to expose Spring Boot app
resource "kubernetes_service" "springboot_service" {
  metadata {
    name      = "${var.app_name}-service"
    namespace = kubernetes_namespace.springboot.metadata[0].name
  }

  spec {
    selector = {
      app = var.app_name
    }

    port {
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }

    type = "LoadBalancer"
  }

  depends_on = [kubernetes_deployment.springboot_app]
}

# Outputs
output "cluster_id" {
  description = "LKE Cluster ID"
  value       = linode_lke_cluster.main.id
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = linode_lke_cluster.main.api_endpoints[0]
}

output "kubeconfig" {
  description = "Kubeconfig for cluster access"
  value       = linode_lke_cluster.main.kubeconfig
  sensitive   = true
}

output "load_balancer_ip" {
  description = "Load Balancer IP for Spring Boot service"
  value       = kubernetes_service.springboot_service.status[0].load_balancer[0].ingress[0].ip
}

output "spring_boot_url" {
  description = "URL to access Spring Boot application"
  value       = "http://${kubernetes_service.springboot_service.status[0].load_balancer[0].ingress[0].ip}"
}
