resource "proxmox_download_file" "talos" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = local.pve_node
  url          = "https://factory.talos.dev/image/${var.talos_schematic_id}/v${var.talos_version}/nocloud-amd64.raw.xz"
  file_name    = "talos-v${var.talos_version}-nocloud-amd64.img"
  overwrite    = false

  # Yes, "zst" against a .raw.xz URL -- this is what the provider expects
  # in practice. If the download errors out, try "xz".
  decompression_algorithm = "zst"
}

resource "proxmox_virtual_environment_vm" "talos" {
  name            = "talos-lab"
  node_name       = local.pve_node
  vm_id           = local.talos.vmid
  description     = "Managed by Terraform"
  tags            = ["terraform", "talos"]
  on_boot         = true
  stop_on_destroy = true

  agent {
    enabled = true # requires the qemu-guest-agent schematic extension
  }

  machine = "q35"

  cpu {
    cores = local.talos.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = local.talos.memory
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_download_file.talos.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = local.talos.disk
  }

  # Addressing comes from nocloud. Nameservers come from the machine config
  # patch below -- setting them in both places invites a conflict.
  initialization {
    datastore_id = "local-lvm"
    ip_config {
      ipv4 {
        address = "${local.talos.ip}/${local.net.cidr}"
        gateway = local.net.gateway
      }
    }
  }

  network_device {
    bridge = local.net.bridge
  }

  operating_system {
    type = "l26"
  }

  serial_device {} # talosctl diagnostics when the network is the problem
}

resource "talos_machine_secrets" "this" {
  talos_version = "v${var.talos_version}"
}

data "talos_client_configuration" "this" {
  cluster_name         = local.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [local.talos.ip]
  nodes                = [local.talos.ip]
}

data "talos_machine_configuration" "this" {
  cluster_name       = local.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = "v${var.talos_version}"
  kubernetes_version = "v${var.kubernetes_version}"

  config_patches = [
    yamlencode({
      cluster = {
        # Single node: without this, nothing schedules.
        allowSchedulingOnControlPlanes = true
      }
      machine = {
        install = {
          disk = "/dev/vda"
        }
        network = {
          # Must point OUTSIDE the cluster. Point this at anything you are
          # hosting and bootstrap deadlocks pulling images, with no useful error.
          nameservers = local.net.upstream
        }
        kubelet = {
          # local-path-provisioner's default /opt path is not writable on
          # Talos, and kubelet cannot see host paths it has not been given.
          # Without this, PVCs silently never bind.
          extraMounts = [{
            destination = "/var/local-path-provisioner"
            type        = "bind"
            source      = "/var/local-path-provisioner"
            options     = ["bind", "rshared", "rw"]
          }]
        }
      }
    }),
  ]
}

resource "talos_machine_configuration_apply" "this" {
  depends_on                  = [proxmox_virtual_environment_vm.talos]
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.this.machine_configuration
  node                        = local.talos.ip
}

resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine_configuration_apply.this]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.talos.ip
  endpoint             = local.talos.ip
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_machine_bootstrap.this]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.talos.ip
  endpoint             = local.talos.ip
}

data "talos_cluster_health" "this" {
  depends_on           = [talos_cluster_kubeconfig.this]
  client_configuration = talos_machine_secrets.this.client_configuration
  control_plane_nodes  = [local.talos.ip]
  endpoints            = [local.talos.ip]
}
