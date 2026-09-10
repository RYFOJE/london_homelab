# Gate between "Talos bootstrapped" and "Kubernetes is actually serving".
#
# talos_cluster_kubeconfig completes in 0s -- it only asks the Talos API to
# mint a kubeconfig, which it can do long before kube-apiserver accepts
# connections. Without a wait here, the helm and kubernetes providers race
# the control plane and fail with "i/o timeout" on a clean build.
#
# data.talos_cluster_health would be the natural gate, but provider v0.11.0
# cannot deserialize Talos 1.14's VolumeStatus and hangs (see talos.tf).
#
# A 401 is success: it means the API server is up and rejecting us for lack
# of credentials, which is exactly the readiness signal we want. Anything
# that is not an HTTP response means it is not listening yet.
resource "terraform_data" "wait_for_apiserver" {
  depends_on = [talos_cluster_kubeconfig.this]

  # Re-run the wait after anything that takes the apiserver down mid-apply,
  # not only on first bootstrap. A memory/cores change reboots the VM and the
  # Proxmox provider reports "Modifications complete" as soon as it is
  # powered on -- long before kubelet is serving -- so every Secret and
  # namespace below would otherwise fail with "i/o timeout" or "connection
  # refused" (seen on the 8 -> 12 GiB change). Machine-config changes can
  # reboot too, depending on what changed.
  triggers_replace = [
    talos_machine_bootstrap.this.id,
    proxmox_virtual_environment_vm.talos.memory[0].dedicated,
    proxmox_virtual_environment_vm.talos.cpu[0].cores,
    talos_machine_configuration_apply.this.machine_configuration_hash,
  ]

  provisioner "local-exec" {
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = 'SilentlyContinue'
      $deadline = (Get-Date).AddMinutes(10)
      $n = 0
      while ((Get-Date) -lt $deadline) {
        $n++
        try {
          $r = Invoke-WebRequest -Uri 'https://${local.talos.ip}:6443/version' `
                 -SkipCertificateCheck -SkipHttpErrorCheck -TimeoutSec 5
          if ($r.StatusCode -in 200,401,403) {
            Write-Host "kube-apiserver responding after $n attempts (HTTP $($r.StatusCode))"
            exit 0
          }
        } catch { }
        Start-Sleep -Seconds 5
      }
      Write-Error 'kube-apiserver did not come up within 10 minutes'
      exit 1
    EOT
  }
}
