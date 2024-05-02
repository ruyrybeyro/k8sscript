#!/bin/sh

# ----------------
# FQDN definitions

# Can be controlplane or worker
NODE="controlplane"
# NODE="worker"

# FQDN name of node to be installed
KSHOST="k8sm01" # example Control Plane node
#KSHOST="k8sw01" # example Worker node

# Example utilising external variables ${node_name} and ${count}
# NODE=${node_name}
# COUNT=${count}
# KSHOST="k8s-$NODE-$COUNT"

# IP address list of ALL control plane nodes, separated by spaces
# per the k8s RAFT protocol, recommended a minimum of 3, and a even number
# for production
K8S_CP_IPS="192.168.5.130"

# DNS names of ALL control plane nodes, by the same order as K8S_CP_IPS
# separated by spaces
K8S_CP_NAMES="k8sm01"

# k8s control plane virtual IP
K8S_CP_VIP="192.168.5.135"

# k8s control plane DNS name
K8S_CP_VIP_NAME="k8s"

# ----------------
# VARIABLES

# if multiple control planes, for now, next both options should be true
MULTIPLE_CP="true"
KUBE_VIP="true"

# change for false for control plane to run pods or single node cluster
SCHEDULE_TAINT="true"
# if single node, besides SCHEDULE_TAINT="true", change to true
SINGLE_NODE="false"

#ACTOR="ec2-user" # AWS-specific, DO NOT USE IN PRODUCTION

KADM_OPTIONS=""
# uncomment for ignoring warnings if setup not running with recommended specs
KADM_OPTIONS="--ignore-preflight-errors=NumCPU,Mem"

CNI="cilium"
#CNI="calico"

FIREWALL="no"

CONTAINERD_CONFIG="/etc/containerd/config.toml"
KUBEADM_CONFIG="/opt/k8s/kubeadm-config.yaml"

# needed if running as root, or possibly some RedHat variant
PATH="$PATH":/usr/local/bin
export PATH

# ----------------

DontRunAsRoot()
{
    if [ "$(id -u)" -eq 0 ]
    then
        echo "For better security, do not run as root" 2> /dev/null
    fi
}

DisableSELinux()
{
    # Disable SELinux
    sudo setenforce 0
    sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
}

GetIP()
{
    # Get primary IP address
    # Only get the first IP with "NR==1", the second IP by the current script will be the CNI interface
    IPADDR=$(ip -o addr list up primary scope global | awk 'NR==1 { sub(/\/.*/,""); print $4}')
}

SetupNodeName()
{
    # Set hostname
    sudo hostnamectl set-hostname "$KSHOST"
    echo "$IPADDR $KSHOST" | sudo tee -a /etc/hosts
}

# If a VmWare VM, delete firmware, install open-vm-tools
InstallVmWare()
{
    sudo dnf -y install virt-what
    if [ "$(sudo virt-what)" = "vmware" ]
    then
        sudo rpm -e microcode_ctl $(rpm -q -a | grep firmware)
        sudo dnf -y install open-vm-tools
    fi
}

InstallOSPackages()
{
    # Update and upgrade packages
    sudo dnf upgrade -y

    # Install necessary packages
    sudo dnf install -y jq wget curl tar vim yum-utils ca-certificates gnupg ipset ipvsadm iproute-tc git net-tools bind-utils epel-release

    sudo dnf install -y haveged

    # Start the "haveged" service to improve entropy in order to build certificates, just in case
    sudo systemctl --now enable haveged.service

    if [ "$FIREWALL" != "no" ]
    then
        sudo dnf install -y firewalld
    fi
}

KernelRebootWhenPanic()
{
    sudo grubby --update-kernel=ALL --args="panic=60"
}

# Reboot if hanged
SetupWatchdog()
{
    sudo dnf -y install watchdog
    echo softdog | sudo tee /etc/modules-load.d/softdog.conf
    sudo modprobe softdog
    sudo sed -i 's/#watchdog-device/watchdog-device/g' /etc/watchdog.conf
    sudo systemctl --now enable watchdog.service
}

SetupFirewall()
{
    if [ "$FIREWALL" = "no" ]
    then
        sudo systemctl stop firewalld
        sudo systemctl disable firewalld
        echo "no firewall rules applied"
        return
    else
        # Prerequisites for kubeadm
        sudo systemctl --now enable firewalld

        sudo firewall-cmd --permanent --zone=trusted --add-interface=lo

        # API server
        sudo firewall-cmd --permanent --add-port=6443/tcp
        # etcd server client API
        sudo firewall-cmd --permanent --add-port=2379-2380/tcp
        # Kubelet API
        sudo firewall-cmd --permanent --add-port=10250-10252/tcp
        # kubelet API server for read-only access with no authentication
        sudo firewall-cmd --permanent --add-port=10255/tcp
        # kube-controller-manager
        sudo firewall-cmd --permanent --add-port=10257/tcp
        # kube-scheduler
        sudo firewall-cmd --permanent --add-port=10259/tcp
        # NodePort services
        sudo firewall-cmd --permanent --add-port=30000-32767/tcp

        # https://docs.cilium.io/en/stable/operations/system_requirements/
        # health checks
        sudo firewall-cmd --permanent --add-port=4240/tcp
        # Hubble server
        sudo firewall-cmd --permanent --add-port=4244/tcp
        # Hubble relay
        sudo firewall-cmd --permanent --add-port=4245/tcp
        # Mutual Authentication port
        sudo firewall-cmd --permanent --add-port=4250/tcp
        # VXLAN overlay
        sudo firewall-cmd --permanent --add-port=8472/udp
        # cilium-agent Prometheus
        sudo firewall-cmd --permanent --add-port=9962-9964/tcp
        # WireGuard encryption tunnel endpoint
        sudo firewall-cmd --permanent --add-port=51871/udp

        sudo firewall-cmd --reload
    fi

}

SystemSettings()
{
    # overlay, br_netfilter and forwarding for k8s
    sudo mkdir -p /etc/modules-load.d/
    cat <<EOF1 | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF1

   sudo modprobe overlay
   sudo modprobe br_netfilter

   sudo mkdir -p /etc/sysctl.d/

   cat <<EOF2 | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF2

    sudo sysctl --system
}

InstallContainerd()
{
    # Install containerd
    sudo dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo
    sudo dnf install -y containerd
    containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/g' | sudo tee $CONTAINERD_CONFIG
}

InstallK8s()
{
    # Install Kubernetes

    LATEST_RELEASE=$(curl -sSL https://dl.k8s.io/release/stable.txt | sed "s/\(\.[0-9]*\)\.[0-9]*/\1/")

    cat <<EOF3 | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/$LATEST_RELEASE/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/$LATEST_RELEASE/rpm/repodata/repomd.xml.key
EOF3

    sudo dnf update -y

    sudo dnf install -y kubectl kubeadm kubelet kubernetes-cni
    sudo systemctl enable kubelet
}

LogLevelError()
{
    # make systemd only log warning level or greater
    # it will have less logs
    sudo mkdir -p /etc/systemd/system.conf.d/

    cat <<EOF4 | sudo tee /etc/systemd/system.conf.d/10-supress-loginfo.conf
[Manager]
LogLevel=warning
EOF4

    sudo kill -HUP 1

    # fixing annoying RH 9 issue giving a lot of console error messages
    sudo chmod a+x /etc/rc.d/rc.local 2> /dev/null
}

InterfaceWithcontainerd()
{
    # Replace default pause image version in containerd with kubeadm suggested version
    # However, the default containerd pause image version is supposed to be able to overwrite what kubeadm suggests
    LATEST_PAUSE_VERSION=$(kubeadm config images list --kubernetes-version="$(kubeadm version -o short)" | grep pause | cut -d ':' -f 2)

    # Construct the full image name with registry prefix
    sudo sed -i "s/\(sandbox_image = .*\:\)\(.*\)\"/\1$LATEST_PAUSE_VERSION\"/" $CONTAINERD_CONFIG
    sudo systemctl --now enable containerd

    # get address of default containerd sock
    SOCK='unix://'$(containerd config default | grep -Pzo '(?m)((^\[grpc\]\n)( +.+\n*)+)' | awk -F'"' '/ address/ { print $2 } ')
}

# https://pkg.go.dev/k8s.io/kubernetes/cmd/kubeadm/app/apis/kubeadm/v1beta3
KubeadmConfig()
{
    sudo mkdir -p /opt/k8s
    cat <<EOF5 | sudo tee $KUBEADM_CONFIG
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  criSocket: "$SOCK"
  name: "$KSHOST"
  taints:
EOF5

    if [ $SCHEDULE_TAINT = "true" ]
    then
        cat <<EOF6 | sudo tee -a $KUBEADM_CONFIG
    - effect: NoSchedule
      key: node-role.kubernetes.io/master
EOF6
    fi

    if [ $CNI = "cilium" ]
    then
        cat <<EOF7 | sudo tee -a $KUBEADM_CONFIG
    - effect: NoExecute
      key: node.cilium.io/agent-not-ready
skipPhases:
  - addon/kube-proxy
EOF7
    fi

    cat <<EOF8 | sudo tee -a $KUBEADM_CONFIG
localAPIEndpoint:
  advertiseAddress: "$IPADDR"
  bindPort: 6443

---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
etcd:
  local:
    serverCertSANs:
      - "$KSHOST"
    peerCertSANs:
      - "$IPADDR"
controlPlaneEndpoint: "$IPADDR:6443"
apiServer:
  extraArgs:
    authorization-mode: "Node,RBAC"
  certSANs:
    - "$IPADDR"
    - "$KSHOST"
  timeoutForControlPlane: 4m0s

---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
authentication:
  anonymous:
    enabled: false
  webhook:
    cacheTTL: 0s
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 0s
    cacheUnauthorizedTTL: 0s
failSwapOn: false
featureGates:
  NodeSwap: true
memorySwap:
  swapBehavior: LimitedSwap
EOF8
}

KubeVipSetup()
{
    sudo sysctl -w net.ipv4.ip_nonlocal_bind=1
    #sudo setenforce 0

    mkdir -p /etc/kubernetes/manifests

    sudo ctr -n k8s.io image pull ghcr.io/kube-vip/kube-vip:latest
    sudo ctr -n k8s.io run --rm --net-host ghcr.io/kube-vip/kube-vip:latest vip \
/kube-vip manifest pod \
    --address $K8S_CP_VIP \
    --controlplane \
    --enableLoadBalancer \
    --arp \
    --leaderElection | sudo tee /etc/kubernetes/manifests/kube-vip.yaml

    #sudo wget -O /etc/kubernetes/manifests/rbac.yaml https://kube-vip.io/manifests/rbac.yaml
}


KubeConfig()
{
    HOME_DIR=$(getent passwd "$1" | awk -F ':' '{print $6}')
    mkdir -p "$HOME_DIR"/.kube/
    sudo cp -f /etc/kubernetes/admin.conf "$HOME_DIR"/.kube/config
    sudo chown "$(id -u $1)":"$(id -g $1)" "$HOME_DIR"/.kube
    sudo chown "$(id -u $1)":"$(id -g $1)" "$HOME_DIR"/.kube/config

#   https://kubernetes.io/docs/tasks/access-application-cluster/configure-access-multiple-clusters/#append-home-kube-config-to-your-kubeconfig-environment-variable
    # echo "$KUBECONFIG" | grep -q ".*$HOME_DIR\/.kube\/config.*" || export KUBECONFIG="$KUBECONFIG":"$HOME_DIR"/.kube/config
}

LaunchMaster()
{
    if ! sudo kubeadm init "$KADM_OPTIONS" --config "$KUBEADM_CONFIG"
    then
        echo "failed to init k8s cluster"
        exit 1
    fi

    # Run as a normal, non-root user/actor before configuring cluster

#     mkdir -p "$HOME"/.kube
#     sudo cp -f /etc/kubernetes/admin.conf "$HOME"/.kube/config
#     sudo chown "$(id -u $ACTOR)":"$(id -g $ACTOR)" "$HOME"/.kube/config


    if [ -n "$ACTOR" ]
    then
        KubeConfig "$ACTOR"
    fi

    KubeConfig $(id -un) # Get user/actor running the script

}

DeployCNI()
{
    case "$CNI" in
        "calico")
            kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
        ;;

        "cilium")
            # install Cilium CLI
            sudo dnf -y install go
            CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
            GOOS=$(go env GOOS)
            GOARCH=$(go env GOARCH)
            curl -qL --remote-name-all https://github.com/cilium/cilium-cli/releases/download/"$CILIUM_CLI_VERSION/cilium-$GOOS-$GOARCH".tar.gz
            sudo tar -C /usr/local/bin -xzvf cilium-"$GOOS-$GOARCH".tar.gz
            rm cilium-"$GOOS-$GOARCH".tar.gz

            # add the cilium repository
            helm repo add cilium https://helm.cilium.io/
            # get last cilium version
            VERSION=$(helm search repo cilium/cilium | awk 'END {print $2}')
            helm install cilium cilium/cilium --version "$VERSION" --namespace kube-system --set kubeProxyReplacement=true  --set k8sServiceHost="$IPADDR" --set k8sServicePort=6443

            if [ "$SINGLE_NODE" = "true" ]
            then
                kubectl patch deployment  cilium-operator -n kube-system -p '{"spec":{"replicas":1}}'
            fi

            cilium status
        ;;

    esac
}

WaitForNodeUP()
{
    kubectl get node -w | grep -m 1 "[^t]Ready"
}

DisplayMasterJoin()
{
    echo
    echo "Run as root/sudo to add another control plane server"
    #kubeadm token create --print-join-command --certificate-key $(kubeadm certs certificate-key)
    CERTKEY=$(sudo kubeadm init phase upload-certs --upload-certs | tail -1)
    PRINT_JOIN=$(kubeadm token create --print-join-command)
    echo "sudo $PRINT_JOIN --control-plane --certificate-key $CERTKEY --cri-socket $SOCK"
}

DisplaySlaveJoin()
{
    echo
    echo "Run as root/sudo to add another worker node"
    #echo $(kubeadm token create --print-join-command) --cri-socket $SOCK
    echo "sudo $PRINT_JOIN --cri-socket $SOCK"
}

# kube-scheduler: fix access to cluster certificates ConfigMap
# fix multiple periodic log errors "User "system:kube-scheduler" cannot list resource..."
FixRole()
{
    cat <<EOF9 | sudo tee /opt/k8s/kube-scheduler-role-binding.yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-scheduler
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-scheduler
subjects:
  - kind: ServiceAccount
    name: kube-scheduler
    namespace: kube-system

---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kube-scheduler-extension-apiserver-authentication-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: extension-apiserver-authentication-reader
subjects:
  - kind: ServiceAccount
    name: kube-scheduler
    namespace: kube-system
EOF9
    kubectl apply -f /opt/k8s/kube-scheduler-role-binding.yaml
}

HostsMessage()
{
    echo
    echo "Add to /etc/hosts of all other nodes"
    echo "$IPADDR $KSHOST"
    echo
    return 0
}

InstallHelm()
{
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash -s
}

Installk9s()
{
    sudo dnf -y copr enable luminoso/k9s
    sudo dnf -y install k9s
}

Metrics()
{
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    kubectl patch deployment metrics-server -n kube-system --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
}

main()
{
    if [ -z "$NODE" ] || [ -z "$KSHOST" ]
    then
        echo 'Edit script and fill in $NODE and $KSHOST'
        exit 1
    fi

    DontRunAsRoot

#     DisableSELinux

    GetIP
    SetupNodeName
    InstallVmWare
    InstallOSPackages
    KernelRebootWhenPanic
    SetupWatchdog
    SetupFirewall
    SystemSettings
    LogLevelError
    InstallContainerd
    InstallK8s
    InterfaceWithcontainerd

    if [ "$NODE" = "worker" ]
    then
        HostsMessage
        exit 0
    fi

    InstallHelm
    Installk9s

    if [ $KUBE_VIP = "true" ]
    then
        KubeVipSetup
    fi
    exit 1
    KubeadmConfig
    LaunchMaster
    FixRole
    DeployCNI
    WaitForNodeUP

    Metrics

    DisplayMasterJoin
    DisplaySlaveJoin

    HostsMessage
}

# main stub will full arguments passing
main "$@"
