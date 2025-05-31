resource "libvirt_pool" "k8s_pool" {
  name = "k8s-cluster-pool"
  type = "dir"
  path = "/var/lib/libvirt/images/k8s-cluster"
}

resource "libvirt_volume" "base_image" {
  name   = "debian-12-base"
  pool   = libvirt_pool.k8s_pool.name
  source = var.base_image_url
  format = "qcow2"
}