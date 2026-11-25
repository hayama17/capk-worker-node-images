# capk-worker-node-images

**Worker-only node images for [Cluster API Provider KubeVirt](https://github.com/kubernetes-sigs/cluster-api-provider-kubevirt) (CAPK), at less than half the size.**

With [Kamaji](https://kamaji.clastix.io), control planes run as pods, so every VM is a worker. These images leave the control plane out.

| v1.34.1 | Pull (compressed) | Disk |
|---|---:|---:|
| `quay.io/capk/ubuntu-2404-container-disk` | 2,167 MB | 4.38 GB |
| Ubuntu minimal as the base | 1,239 MB | 2.72 GB |
| **+ no control plane images (this repository)** | **964 MB (-56%)** | **2.18 GB (-50%)** |

```
ghcr.io/hayama17/capk-worker-node-images/ubuntu-2404-minimal:<kubernetes version>
```

[Published versions](https://github.com/hayama17/capk-worker-node-images/pkgs/container/capk-worker-node-images%2Fubuntu-2404-minimal). Pulling needs no login, and the build refuses to overwrite a published tag.

## What makes it small

- **Minimal base.** The Ubuntu minimal cloud image, plus the packages image-builder expects and `qemu-guest-agent`.
- **No control plane images.** `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` and `etcd` are never pulled during the build. Only `kube-proxy`, CoreDNS and `pause` are preloaded.

CI fails if `kube-apiserver` or `etcd` ends up on the disk.

The price:

- These images are not meant for control plane nodes, which would have to pull everything first.
- `open-iscsi` and `nfs-common`, which some storage drivers expect on the node, are not included.

## Use

Point the `KubevirtMachineTemplate` of your workers at the tag that matches the Kubernetes version of the cluster:

```yaml
volumes:
  - name: containervolume
    containerDisk:
      image: ghcr.io/hayama17/capk-worker-node-images/ubuntu-2404-minimal:v1.37.2
```

## What is inside

- Ubuntu 24.04, amd64
- kubelet, kubeadm and kubectl of the tagged version
- containerd
- `qemu-guest-agent`

## What is tested

Nothing is pushed before it passes [`smoke.sh`](smoke.sh). It boots the disk the way CAPK does, with q35 and a virtio config drive. The script then checks kubeadm, Flannel, CoreDNS, the guest agent, and signals inside a container.

It does not run Kamaji, CAPK, Cilium or storage drivers.

## Build your own

Fork the repository, enable Actions, and run the [`build`](.github/workflows/build.yml) workflow. Set `publish` to push to the GHCR of the fork.

```bash
gh workflow run build.yml -R <you>/capk-worker-node-images -f version=v1.37.2 -f publish=true
```

[`build.sh`](build.sh) drives a pinned [image-builder](https://github.com/kubernetes-sigs/image-builder). `ubuntu-2604-minimal` can be built too, but it is not published because it fails the smoke test.

## SBOM

The [`sbom`](.github/workflows/sbom.yml) workflow attaches an SPDX SBOM of the disk to a published image. So far only v1.37.2 has one.

```bash
gh attestation verify oci://ghcr.io/hayama17/capk-worker-node-images/ubuntu-2404-minimal:v1.37.2 \
  --repo hayama17/capk-worker-node-images --predicate-type https://spdx.dev/Document/v2.3
```

## License

[Apache-2.0](LICENSE). The software inside the images keeps its own licenses.
