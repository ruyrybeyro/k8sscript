#!/bin/bash -x

KSHOST="k8s01"

CONTAINERD_CONFIG="/etc/containerd/config.toml"

GetIP()
{
    # try to get primary IP address
    IPADD=$(ip -o addr show up primary scope global |
      while read -r num dev fam addr rest; do echo ${addr%/*}; done | head -1)
}

SetupNodeName()
{
    sudo hostnamectl set-hostname $KSHOST
    echo "$IPADD $KSHOST" | sudo tee -a /etc/hosts
}


InstallOSPackages()
{
    # Update and upgrade packages
    sudo dnf upgrade -y

    # Install necessary packages
    sudo dnf install -y jq wget curl tar vim firewalld yum-utils ca-certificates gnupg ipset ipvsadm iproute-tc git net-tools bind-utils
}

SetupFirewall()
{
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
}

SystemSettings()
{
    # overlay, br_netfilter and forwarding for k8s
    sudo mkdir -p /etc/modules-load.d/
    cat <<-EOF | sudo tee /etc/modules-load.d/k8s.conf
	overlay
	br_netfilter
	EOF

   sudo modprobe overlay
   sudo modprobe br_netfilter

   sudo mkdir -p /etc/sysctl.d/
   cat <<-EOF | sudo tee /etc/sysctl.d/k8s.conf
	net.bridge.bridge-nf-call-iptables  = 1
	net.bridge.bridge-nf-call-ip6tables = 1
	net.ipv4.ip_forward                 = 1
	EOF
    sudo sysctl --system
}

InstallContainerd()
{
    # Install containerd
    sudo dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo
    sudo dnf install -y containerd
    echo "log_level = error" > $CONTAINERD_CONFIG
    containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/g' | sudo tee -a $CONTAINERD_CONFIG 
}

InstallK8s()
{
    # Install Kubernetes
    LATEST_RELEASE=$(curl -sSL https://dl.k8s.io/release/stable.txt | sed 's/\(\.[0-9]*\)\.[0-9]*/\1/')
    cat <<-EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
	[kubernetes]
	name=Kubernetes
	baseurl=https://pkgs.k8s.io/core:/stable:/$LATEST_RELEASE/rpm/
	enabled=1
	gpgcheck=1
	gpgkey=https://pkgs.k8s.io/core:/stable:/$LATEST_RELEASE/rpm/repodata/repomd.xml.key
EOF

    sudo dnf update -y

    sudo dnf install -y kubectl kubeadm kubelet kubernetes-cni
    sudo systemctl enable kubelet
}

InterfaceWithcontainerd()
{
    # Replace default pause image version in containerd with kubeadm suggested version
    # However, the default containerd pause image version is supposed to be able to overwrite what kubeadm suggests
    LATEST_PAUSE_VERSION=$(kubeadm config images list --kubernetes-version=$(kubeadm version -o short) | grep pause | cut -d ':' -f 2)

    # Construct the full image name with registry prefix
    sudo sed -i "s/\(sandbox_image = .*\:\)\(.*\)\"/\1$LATEST_PAUSE_VERSION\"/" $CONTAINERD_CONFIG
    sudo systemctl --now enable containerd

    # get address of default containerd sock
    SOCK='unix://'$(containerd config default | grep -Pzo '(?m)((^\[grpc\]\n)( +.+\n*)+)' | awk -F'"' '/ address/ { print $2 } ')
}

KubedamConfig()
{
    sudo mkdir -p /opt/k8s
    cat <<EOF | sudo tee /opt/k8s/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: abcdef.0123456789abcdef
  ttl: 24h0m0s
  usages:
  - signing
  - authentication
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: $IPADD
  bindPort: 6443
nodeRegistration:
  criSocket: $SOCK
  name: $KHOST
  taints:
  - effect: NoSchedule
    key: node-role.kubernetes.io/master
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
failSwapOn: false
featureGates:
  NodeSwap: true
memorySwap:
  swapBehavior: LimitedSwap
EOF
}

LaunchMaster()
{
    # Temporary command ignoring warnings till I get a complete setup running with recommended specs
    sudo kubeadm init --ignore-preflight-errors=NumCPU,Mem --config /opt/k8s/kubeadm-config.yaml

    mkdir -p "$HOME"/.kube
    sudo cp -f /etc/kubernetes/admin.conf "$HOME"/.kube/config
    sudo chown "$(id -u)":"$(id -g)" "$HOME"/.kube/config
}

CNI()
{
    kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
}

WaitForNodeUP()
{
    kubectl get node -w | grep -m 1 "[^t]Ready"
}

main()
{
    GetIP
    SetupNodeName
    InstallOSPackages
    SetupFirewall
    SystemSettings
    InstallContainerd
    InstallK8s
    InterfaceWithcontainerd
    KubedamConfig
    LaunchMaster
    CNI
    WaitForNodeUP
}

# main stub will full arguments passing
main "$@"

