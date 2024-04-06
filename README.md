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

$NODE with ControlPlane or Worker

