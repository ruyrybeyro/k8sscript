#!/bin/bash -x

#hostnamectl set-hostname k8s01

# Update and upgrade packages
sudo dnf update -y

# Install necessary packages
sudo dnf install -y jq wget curl tar vim firewalld yum-utils ca-certificates gnupg ipset ipvsadm iproute-tc git net-tools bind-utils

# make rsyslog a bit less noisy
cat <<EOF | sudo tee /etc/rsyslog.d/01-blocklist.conf
if $msg contains "run-containerd-runc-k8s.io" and $msg contains ".mount: Deactivated successfully." then {
    stop
}
EOF
sudo systemctl restart rsyslog

# Prerequisites for kubeadm
sudo systemctl --now enable firewalld
sudo firewall-cmd --permanent --add-port=6443/tcp
sudo firewall-cmd --permanent --add-port=2379-2380/tcp
sudo firewall-cmd --permanent --add-port=10250/tcp
sudo firewall-cmd --permanent --add-port=10251/tcp
sudo firewall-cmd --permanent --add-port=10252/tcp
sudo firewall-cmd --permanent --add-port=10255/tcp
sudo firewall-cmd --permanent --add-port=10257/tcp
sudo firewall-cmd --permanent --add-port=10259/tcp
sudo firewall-cmd --permanent --add-port=30000-32767/tcp 
sudo firewall-cmd --reload

# overlay, br_netfilter and forwarding for k8s
sudo mkdir -p /etc/modules-load.d/
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

sudo mkdir -p /etc/sysctl.d/
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

#sudo dracut -f


sudo dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y containerd
containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/g;s|"/run/containerd/containerd.sock"|"/var/run/containerd/containerd.sock"|g' | sudo tee /etc/containerd/config.toml
sudo systemctl --now enable containerd

# Install Kubernetes
LATEST_RELEASE=$(curl -sSL https://dl.k8s.io/release/stable.txt | sed 's/\(\.[0-9]*\)\.[0-9]*/\1/')
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${LATEST_RELEASE}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${LATEST_RELEASE}/rpm/repodata/repomd.xml.key
EOF

sudo dnf update

sudo dnf install -y kubernetes-cni

# Install CNI plugins - smash installed ones with the newer, last version
DEST_DIR="/opt/cni/bin"
#sudo mkdir -p $DEST_DIR
LATEST_RELEASE=$(curl -s "https://api.github.com/repos/containernetworking/plugins/releases/latest" | awk -F'"' '/tag_name/{print $4}')
OS="linux"
ARCH="amd64"
URL="https://github.com/containernetworking/plugins/releases/download/$LATEST_RELEASE/cni-plugins-$OS-$ARCH-$LATEST_RELEASE.tgz"
wget -qO- "$URL" | sudo tar -C $DEST_DIR -xzvf -

sudo dnf install -y kubectl kubeadm kubelet
sudo systemctl enable kubelet

## master specific stuff

sudo mkdir -p /opt/k8s
cat <<EOF | sudo tee /opt/k8s/kubeadm-config.yaml
---
apiVersion: "kubeadm.k8s.io/v1beta3"
kind: InitConfiguration
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
failSwapOn: false
featureGates:
  NodeSwap: true
memorySwap:
  swapBehavior: LimitedSwap
EOF

# Temporary command ignoring warnings till I get a complete setup running with recommended specs
sudo kubeadm init --ignore-preflight-errors=NumCPU,Mem --config /opt/k8s/kubeadm-config.yaml

mkdir -p "$HOME"/.kube
sudo cp -f /etc/kubernetes/admin.conf "$HOME"/.kube/config
sudo chown "$(id -u)":"$(id -g)" "$HOME"/.kube/config


kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml

#echo insecure > "$HOME"/.curlrc

kubectl get node -w | grep -m 1 "[^t]Ready"
