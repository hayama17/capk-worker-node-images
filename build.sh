#!/usr/bin/env bash
# Build the container disk for $OS (e.g. ubuntu-2404-minimal) and $VERSION (e.g. v1.37.2) with image-builder.
set -euo pipefail

[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "invalid version: $VERSION" >&2; exit 1; }
semver=${VERSION#v}
series=${VERSION%.*}
deb=$(curl -fsSL "https://pkgs.k8s.io/core:/stable:/$series/deb/Packages" |
  awk -v v="$semver" '/^Package: /{p=$2} /^Version: /{if (p=="kubelet" && index($2, v "-")==1) d=$2} END{print d}')
[[ -n "$deb" ]] || { echo "no kubelet package for $VERSION" >&2; exit 1; }

sudo apt-get update -q
sudo apt-get install -y -q qemu-system-x86 qemu-utils xorriso
sudo chmod 666 /dev/kvm

cp "qemu-$OS.json" image-builder/images/capi/packer/qemu/
cp -r roles/containerd_apparmor image-builder/images/capi/ansible/roles/
cd image-builder/images/capi
export PATH="$HOME/.local/bin:$PATH"
export QEMU_BUILD_NAMES=qemu-$OS
export PACKER_FLAGS="--var kubernetes_semver=$VERSION --var kubernetes_series=$series --var kubernetes_deb_version=$deb"
# kubeadm v1.37 no longer reads v1beta3
sed -i s/v1beta3/v1beta4/ ansible/roles/kubernetes/templates/etc/kubeadm.yml
# Workers of a hosted control plane only run these
pull=ansible/roles/kubernetes/tasks/kubeadmpull.yml
sed -i "s#command: kubeadm config images pull --config /etc/kubeadm.yml --cri-socket \(.*\)#shell: kubeadm config images list --config /etc/kubeadm.yml | grep -E '/(kube-proxy|coredns|pause):' | xargs -n1 crictl --runtime-endpoint unix://\1 pull#" $pull
grep -q 'crictl .* pull$' $pull
sed -i 's/"etcd", "kube-apiserver", "kube-controller-manager", "kube-proxy", "kube-scheduler", "pause"/"kube-proxy", "pause"/' packer/goss/goss-command.yaml
# Packer looks up plugins anonymously, which shared runners often exhaust
make deps-qemu || { sleep 300; make deps-qemu; }
make "build-kubevirt-qemu-$OS"
ls -lh output/*/
docker image ls
