# k8sscript

Spin up Kubernetes master and worker node for Red Hat Linux family

control plane+worker node

metrics

Cillium eBPF without kube-proxy as CNI

for k8s > 1.29

Tested with: 
Rocky 9
Alma 9
K8s 1.29.3
containerd 1.6.28
Calico
Cillium+eBPF

For now, edit the script and fill in:

$KSHOST with FQDN of node

$NODE with "controlplane" or "worker" (as examples) \
Note that using upper-case letters in the FQDN (i.e. akin to "ControlPlane" or "Worker") for the machine might not work; currently non-reproducible issue of `etcd` complaining against an FQDN with the aforementioned (upper-case) characters.

Recommend VMs with at least 4GB disk free at /var +3.5GB of RAM

