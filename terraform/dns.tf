resource "proxmox_download_file" "debian_lxc" {
  content_type = "vztmpl"
  datastore_id = "local"
  node_name    = local.pve_node
  url          = var.lxc_template_url
}

resource "proxmox_virtual_environment_container" "this" {
  for_each = local.containers

  node_name     = local.pve_node
  vm_id         = each.value.vmid
  description   = "Managed by Terraform"
  unprivileged  = true
  start_on_boot = true

  initialization {
    hostname = each.key

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${local.net.cidr}"
        gateway = local.net.gateway
      }
    }

    # The container's OWN resolver. Must not be itself: apt needs
    # resolution before dnsmasq exists, so self-reference hangs provisioning.
    dns {
      servers = local.net.upstream
    }

    user_account {
      keys = [trimspace(file(pathexpand(var.ssh_public_key_path)))]
    }
  }

  network_interface {
    name   = "veth0"
    bridge = local.net.bridge
  }

  disk {
    datastore_id = "local-lvm"
    size         = each.value.disk
  }

  memory {
    dedicated = each.value.memory
    swap      = 0
  }

  cpu {
    cores = each.value.cores
  }

  operating_system {
    template_file_id = proxmox_download_file.debian_lxc.id
    # Debian, not Ubuntu: Ubuntu templates ship systemd-resolved, which
    # holds :53 and fights dnsmasq.
    type = "debian"
  }
}

locals {
  dnsmasq_conf = templatefile("${path.module}/files/dnsmasq.conf.tftpl", {
    domain   = local.domain
    target   = local.talos.ip # derived, so the record can never drift from the node
    upstream = local.net.upstream
  })
}

resource "terraform_data" "dnsmasq" {
  depends_on = [proxmox_virtual_environment_container.this]

  # Re-runs when the rendered config changes. Without this you would be
  # tainting the resource by hand after every edit.
  triggers_replace = [sha256(local.dnsmasq_conf)]

  connection {
    type = "ssh"
    host = local.containers.dns.ip
    user = "root"
    # Use the SSH agent rather than a key file. On Windows this avoids the
    # OpenSSH-vs-PEM key format problem, and it is the same mechanism the
    # proxmox provider uses, so there is one thing to get working, not two.
    agent = true
  }

  provisioner "file" {
    content     = local.dnsmasq_conf
    destination = "/etc/dnsmasq.conf"
  }

  provisioner "remote-exec" {
    inline = [
      "apt-get update",
      "DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq",
      "systemctl enable dnsmasq",
      "systemctl restart dnsmasq",
    ]
  }
}
