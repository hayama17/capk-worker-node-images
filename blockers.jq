# Findings that a rebuild or a version bump here fixes: these stop the publish, whatever their severity
[.matches[]
  | select(.vulnerability.fix.state == "fixed")
  | .artifact as $a | $a.locations[0].path as $p
  | select($a.type == "deb"
      or ((.vulnerability.knownExploited // []) | length > 0)
      or ([["github.com/containerd/containerd/v2", "^/usr/local/bin/"], ["github.com/opencontainers/runc", "^/usr/local/sbin/runc$"],
           ["sigs.k8s.io/cri-tools", "/crictl$"], ["github.com/containernetworking/plugins", "^/opt/cni/bin/"],
           ["k8s.io/kubernetes", "^/usr/bin/kube"]]
          | any(.[0] == $a.name and (.[1] as $r | $p | test($r)))))
  | "\(.vulnerability.severity) \(.vulnerability.id) \($a.name) \($a.version) \($p)"] | unique[]
