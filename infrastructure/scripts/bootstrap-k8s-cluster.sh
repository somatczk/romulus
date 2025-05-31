#!/bin/bash
# Kubernetes Cluster Bootstrap Script
# Run this script on the first master node (k8s-master-1)

set -e

echo "🚀 Starting Kubernetes cluster initialization..."

# Initialize the first master node
echo "📋 Initializing kubeadm on master node..."
sudo kubeadm init \
  --apiserver-advertise-address=10.10.10.11 \
  --pod-network-cidr=192.168.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --apiserver-cert-extra-sans=10.10.10.11,k8s-master-1,k8s-master-1.k8s.local

# Set up kubectl for the current user
echo "🔧 Setting up kubectl for debian user..."
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Install Calico CNI
echo "🌐 Installing Calico CNI..."
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/tigera-operator.yaml
wget https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/custom-resources.yaml
kubectl create -f custom-resources.yaml

# Wait for nodes to be ready
echo "⏳ Waiting for node to be ready..."
kubectl wait --for=condition=Ready node/k8s-master-1 --timeout=300s

# Show cluster status
echo "✅ Cluster initialization complete!"
echo ""
echo "📊 Cluster Status:"
kubectl get nodes -o wide
echo ""
echo "📋 To join other nodes to this cluster:"
echo "1. SSH to each node (master and worker)"
echo "2. Run the kubeadm join command that was displayed above"
echo ""
echo "🔐 Join commands for additional masters:"
echo "sudo kubeadm join 10.10.10.11:6443 --token <token> --discovery-token-ca-cert-hash <hash> --control-plane"
echo ""
echo "🔐 Join commands for workers:"
echo "sudo kubeadm join 10.10.10.11:6443 --token <token> --discovery-token-ca-cert-hash <hash>"
echo ""
echo "💡 Get new tokens with: kubeadm token create --print-join-command" 