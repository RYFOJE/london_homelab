locals {
  pve_node = "boston"

  net = {
    gateway  = "192.168.18.1"
    bridge   = "vmbr0"
    cidr     = 24
    upstream = ["1.1.1.1", "8.8.8.8"]
  }

  domain = "lab.ryfoje.com"

  # for_each over a map even at one entry: adding host #2 is three lines
  # here instead of a copy-pasted resource block. Never use count for
  # machines -- it keys by index, so an insert renumbers and recreates.
  containers = {
    dns = {
      vmid   = 110
      ip     = "192.168.18.70"
      cores  = 1
      memory = 256
      disk   = 4
    }
  }

  talos = {
    vmid   = 120
    ip     = "192.168.18.80"
    cores  = 4
    memory = 12288
    disk   = 200
  }

  cluster_name     = "lab"
  cluster_endpoint = "https://${local.talos.ip}:6443"
}
