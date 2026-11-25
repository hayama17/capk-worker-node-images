# capk-worker-node-images

**Optimized [Cluster API Provider KubeVirt](https://github.com/kubernetes-sigs/cluster-api-provider-kubevirt) (CAPK) worker node images for Hosted Control Plane architectures.**

With a hosted control plane, the API server and etcd run outside the cluster's own nodes, so every VM is a worker. General-purpose node images still carry the control plane. These leave it out, at less than half the size.

[Kamaji](https://kamaji.clastix.io) is the main use case, but nothing in the images is specific to it. They only expect workers that join with kubeadm.

| | Kubernetes | Pull (compressed) | Disk |
|---|---|---:|---:|
| `quay.io/capk/ubuntu-2404-container-disk` | v1.34.1 | 2,167 MB | 4.38 GB |
| **This repository** | v1.37.2 | **673 MB** | **1.76 GB** |

Measured in November 2026. The versions differ because v1.34.1 was the newest one CAPK had published.

```
ghcr.io/hayama17/capk-worker-node-images/ubuntu-2404-minimal:<kubernetes version>
```

[Published versions](https://github.com/hayama17/capk-worker-node-images/pkgs/container/capk-worker-node-images%2Fubuntu-2404-minimal). Pulling needs no login.

`<version>` moves to the newest build of that Kubernetes version. `<version>-<build>` never moves, so use it to pin or roll back. There is no `latest`, because a worker has to match the version of its cluster. The [releases](https://github.com/hayama17/capk-worker-node-images/releases) list what each build contains.

## What makes it small

- **Minimal base.** The Ubuntu minimal cloud image, plus the packages image-builder expects and `qemu-guest-agent`. Saved 928 MB of the pull on v1.34.1.
- **No control plane images.** `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` and `etcd` are never pulled during the build. Only `kube-proxy`, CoreDNS and `pause` are preloaded. Saved another 275 MB on v1.34.1.
- **No build leftovers.** image-builder leaves the downloaded `.deb` files behind, including compilers. They were 205 MB on v1.37.2. snapd is removed too.

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
      imagePullPolicy: Always # pick up rebuilds of the same tag
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

Fork the repository, enable Actions, list the versions you want in [`build.yml`](.github/workflows/build.yml), and run it. It publishes to the GHCR of the fork from `main`, and only builds and tests from other branches.

```bash
gh workflow run build.yml -R <you>/capk-worker-node-images
```

[`build.sh`](build.sh) drives a pinned [image-builder](https://github.com/kubernetes-sigs/image-builder). `ubuntu-2604-minimal` can be built too, but it is not published because it fails the smoke test.

## Verify

Images carry build provenance and an SPDX SBOM of the disk. The build is designed for [SLSA v1.0 Build Level 3](https://slsa.dev/spec/v1.0/levels#build-l3) (self-assessed): it runs in a reusable workflow without inputs on GitHub-hosted runners, and the build steps cannot reach the signing token.

```bash
verify() {
  gh attestation verify oci://ghcr.io/hayama17/capk-worker-node-images/ubuntu-2404-minimal:v1.37.2 \
    --repo hayama17/capk-worker-node-images \
    --signer-workflow hayama17/capk-worker-node-images/.github/workflows/image.yml \
    --source-ref refs/heads/main --deny-self-hosted-runners "$@"
}
verify
verify --predicate-type https://spdx.dev/Document/v2.3
```

## Vulnerabilities

Every build is scanned with grype, and each release carries the result. A build is not published while it contains a vulnerability that can be fixed here:

- an Ubuntu package with a fix available
- containerd, runc, crictl, the CNI plugins or Kubernetes itself, with a fix available
- anything known to be exploited, with a fix available

Severity does not matter for that. The rest waits for upstream, mostly the Ubuntu kernel and the Go dependencies of upstream binaries. Exceptions and their reasons are in [`.grype.yaml`](.grype.yaml).

## License

[Apache-2.0](LICENSE). The software inside the images keeps its own licenses.
