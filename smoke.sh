#!/usr/bin/env bash
# Boot two machines from the built disk the way CAPK does (q35, config drive on virtio),
# run a control plane on one, and join the other to it as a worker. $CNI is flannel or cilium.
set -euo pipefail
. ./versions.env

disk=image-builder/images/capi/output/$OS-kube-$VERSION/$OS-kube-$VERSION
dir=$(mktemp -d)
net=192.168.77 cp_ip=192.168.77.10

# The CA is made here, so that the worker can be given its hash before the control plane exists
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=kubernetes -addext keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign \
  -keyout "$dir/ca.key" -out "$dir/ca.crt" 2>/dev/null
hash=sha256:$(openssl x509 -in "$dir/ca.crt" -noout -pubkey | openssl pkey -pubin -outform der | sha256sum | cut -d' ' -f1)
token=$(openssl rand -hex 3).$(openssl rand -hex 8)

# Cilium replaces kube-proxy, so it has to reach the API server by itself
case $CNI in
  flannel)
    init_flags=
    curl -fsSL -o "$dir/cni.yaml" "https://github.com/flannel-io/flannel/releases/download/$FLANNEL_VERSION/kube-flannel.yml" ;;
  cilium)
    init_flags=--skip-phases=addon/kube-proxy
    helm template cilium cilium --repo https://helm.cilium.io --version "${CILIUM_VERSION#v}" -n kube-system \
      --set kubeProxyReplacement=true,k8sServiceHost=$cp_ip,k8sServicePort=6443,ipam.mode=kubernetes,operator.replicas=1,hubble.enabled=false \
      > "$dir/cni.yaml" ;;
  *) echo "unknown CNI: $CNI" >&2; exit 1 ;;
esac

prologue() {
  cat <<GUEST
#!/bin/bash
# A getty that starts later hangs up the port and kills this script
systemctl mask --runtime --now serial-getty@ttyS0
exec > /dev/ttyS0 2>&1
set -e
finish() { trap - EXIT; echo "SMOKE_RESULT=\$1"; sleep 2; poweroff -f; }
denied() { { journalctl -k --no-pager; cat /var/log/audit/audit.log; } | grep DENIED; }
trap 'set +e; systemctl --failed --no-pager; journalctl -u kubelet -u containerd --no-pager | tail -60; crictl ps -a; kubectl get nodes,pods -A -o wide; kubectl logs dns; kubectl -n kube-system logs ds/kube-proxy --tail=40; kubectl -n kube-system logs deploy/coredns --tail=40; denied | tail -20; finish NG' EXIT
GUEST
}

{ prologue; cat <<GUEST; } > "$dir/cp"
export KUBECONFIG=/etc/kubernetes/admin.conf
mkdir -p /etc/kubernetes/pki
base64 -d <<< "$(base64 -w0 "$dir/ca.crt")" > /etc/kubernetes/pki/ca.crt
base64 -d <<< "$(base64 -w0 "$dir/ca.key")" > /etc/kubernetes/pki/ca.key
kubeadm init --kubernetes-version $VERSION --pod-network-cidr 10.244.0.0/16 --token $token $init_flags
base64 -d <<< "$(gzip -c "$dir/cni.yaml" | base64 -w0)" | gunzip | kubectl apply --server-side -f -
until kubectl get node worker; do sleep 5; done
kubectl wait --for=condition=Ready node --all --timeout=5m
kubectl -n kube-system rollout status deploy/coredns --timeout=5m
if [[ $CNI == cilium ]]; then
  kubectl -n kube-system rollout status ds/cilium --timeout=5m
  if kubectl -n kube-system get ds kube-proxy; then exit 1; fi
  kubectl run web --image=registry.k8s.io/e2e-test-images/agnhost:2.39 --restart=Never -- netexec --http-port=8080
  kubectl run client --image=registry.k8s.io/e2e-test-images/agnhost:2.39 --restart=Never -- pause
  kubectl wait --for=condition=Ready pod/web pod/client --timeout=3m
  web=\$(kubectl get pod web -o jsonpath='{.status.podIP}'):8080
  kubectl exec client -- /agnhost connect \$web --timeout=5s
  echo '{"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": {"name": "deny"}, "spec": {"podSelector": {"matchLabels": {"run": "web"}}}}' | kubectl apply -f -
  sleep 10
  if kubectl exec client -- /agnhost connect \$web --timeout=5s; then exit 1; fi
fi
# The worker is the only node without a taint. Not Docker Hub, which rate-limits shared runners
kubectl run dns --image=registry.k8s.io/e2e-test-images/agnhost:2.39 --restart=Never --command -- sh -c 'sleep 60 & kill \$! && nslookup kubernetes.default.svc.cluster.local'
kubectl run exec --image=registry.k8s.io/e2e-test-images/agnhost:2.39 --restart=Never -- pause
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/dns --timeout=3m
kubectl logs dns | grep -F kubernetes.default
kubectl wait --for=condition=Ready pod/exec --timeout=3m
[[ \$(kubectl get pod exec -o jsonpath='{.spec.nodeName}') == worker ]]
kubectl exec exec -- cat /etc/hostname | grep -x exec
kubectl get nodes,pods -A -o wide
finish OK
GUEST

{ prologue; cat <<GUEST; } > "$dir/worker"
uname -r
systemctl is-active qemu-guest-agent
# Nothing from the build may let anyone log in
if getent passwd builder; then exit 1; fi
if grep -qE '^[^:]+:[\$]' /etc/shadow; then exit 1; fi
mkdir -p /run/sshd
sshd -T | grep -x 'passwordauthentication no'
if ls -d /usr/lib/snapd /usr/lib/linux-tools-*; then exit 1; fi
containerd --version; runc --version; crictl --version; /opt/cni/bin/bridge --version
until curl -ksf https://$cp_ip:6443/healthz; do sleep 5; done
# A control plane with another CA must be refused, and for that reason
if timeout 2m kubeadm join $cp_ip:6443 --token $token --discovery-token-ca-cert-hash sha256:$(printf '0%.0s' {1..64}) > /tmp/join 2>&1; then exit 1; fi
cat /tmp/join; grep -i pinned /tmp/join
kubeadm join $cp_ip:6443 --token $token --discovery-token-ca-cert-hash $hash
until crictl ps -a --name '^dns\$' --state Exited -q | grep .; do sleep 5; done
crictl images
if crictl images | grep -E '/(kube-(apiserver|controller-manager|scheduler)|etcd) '; then exit 1; fi
# containerd/containerd#14485; auditd takes the denials away from the kernel log
if denied | grep -E '$([[ $CNI == cilium ]] && echo DENIED || echo operation=.signal)'; then exit 1; fi
trap - EXIT
# Stay up, the control plane is still using this node
echo SMOKE_RESULT=OK
GUEST

cleanup() {
  sudo pkill qemu-system || true
  sudo pkill dnsmasq || true
  for i in smoke-cp smoke-worker smoke; do sudo ip link del "$i" 2>/dev/null || true; done
}
trap cleanup EXIT
sudo apt-get install -y -q dnsmasq-base
sudo ip link add smoke type bridge
sudo ip addr add "$net.1/24" dev smoke
sudo ip link set smoke up
sudo sysctl -qw net.ipv4.ip_forward=1
sudo iptables -t nat -A POSTROUTING -s "$net.0/24" ! -o smoke -j MASQUERADE
sudo iptables -I FORWARD -i smoke -j ACCEPT
sudo iptables -I FORWARD -o smoke -j ACCEPT
sudo dnsmasq --interface=smoke --bind-interfaces --except-interface=lo --dhcp-range="$net.10,$net.20" \
  --dhcp-host="52:54:00:00:00:10,$cp_ip" --dhcp-host="52:54:00:00:00:11,$net.11" --pid-file="$dir/dnsmasq.pid"

boot() { # name, last byte of the MAC
  local cfg=$dir/$1-config
  mkdir -p "$cfg/openstack/latest"
  echo "{\"uuid\": \"smoke-$1\", \"hostname\": \"$1\"}" > "$cfg/openstack/latest/meta_data.json"
  cp "$dir/$1" "$cfg/openstack/latest/user_data"
  xorriso -as mkisofs -quiet -V config-2 -J -r -o "$dir/$1.iso" -graft-points "openstack=$cfg/openstack"
  sudo ip tuntap add "smoke-$1" mode tap user "$(id -un)"
  sudo ip link set "smoke-$1" master smoke up
  timeout 25m qemu-system-x86_64 -M q35 -accel kvm -cpu host -smp 2 -m 4096 -display none -no-reboot -snapshot -uuid "$(uuidgen)" \
    -serial "file:serial-$CNI-$1.log" \
    -drive "file=$disk,if=virtio,format=qcow2" \
    -drive "file=$dir/$1.iso,if=virtio,format=raw,readonly=on" \
    -device pcie-root-port,id=rp1,slot=1 -netdev "tap,id=n0,ifname=smoke-$1,script=no,downscript=no" \
    -device "virtio-net-pci,bus=rp1,netdev=n0,mac=52:54:00:00:00:$2" \
    -device virtio-serial -chardev null,id=ga -device virtserialport,chardev=ga,name=org.qemu.guest_agent.0
}

touch "serial-$CNI"-{cp,worker}.log
tail -f "serial-$CNI"-{cp,worker}.log &
tail=$!
boot cp 10 &
cp=$!
boot worker 11 &
# The worker only exits first when it fails
wait -n "$cp" $! || true
# Its last checks may still be running
timeout 1m sh -c "until grep -q SMOKE_RESULT serial-$CNI-worker.log; do sleep 1; done" || true
sleep 2
kill "$tail"

grep -q 'SMOKE_RESULT=OK' "serial-$CNI-cp.log"
grep -q 'SMOKE_RESULT=OK' "serial-$CNI-worker.log"
